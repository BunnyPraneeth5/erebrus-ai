import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_service.dart';
import 'power_service.dart';

class WhisperModelSpec {
  const WhisperModelSpec({
    required this.id,
    required this.filename,
    required this.downloadUrl,
    required this.revision,
    required this.sizeBytes,
    required this.sha256,
    required this.minimumRamGB,
    this.displayName = 'Whisper Tiny',
    this.summary = 'Fastest · multilingual',
    this.englishOnly = false,
  });

  final String id;
  final String displayName;
  final String summary;
  final bool englishOnly;
  final String filename;
  final String downloadUrl;
  final String revision;
  final int sizeBytes;
  final String sha256;
  final double minimumRamGB;

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.round()} MB';
  }
}

const _whisperRevision = '5359861c739e955e79d9a303bcbc70fb988958b1';
const _whisperBaseUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/$_whisperRevision';

class WhisperModelManager extends ChangeNotifier {
  /// Every verified speech-recognition model the app can install. Sizes and
  /// SHA-256 digests are the Hugging Face LFS metadata at [_whisperRevision].
  static const specs = [tiny, base, baseEnglish, small, largeV3TurboQ5];

  static final Map<String, WhisperModelManager> _managers = {};
  static final ValueNotifier<String> selectedSpecId = ValueNotifier(tiny.id);
  static const _selectionKey = 'whisper_model_id';

  /// The manager for the speech model the user selected in Voice settings.
  static WhisperModelManager get instance => forSpec(selectedSpec);

  static WhisperModelSpec get selectedSpec => specById(selectedSpecId.value);

  static WhisperModelSpec specById(String id) =>
      specs.where((spec) => spec.id == id).firstOrNull ?? tiny;

  static WhisperModelManager forSpec(WhisperModelSpec spec) =>
      _managers.putIfAbsent(spec.id, () => WhisperModelManager(spec: spec));

  static Future<void> loadSelection() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      selectedSpecId.value = specById(
        preferences.getString(_selectionKey) ?? tiny.id,
      ).id;
    } on Object catch (error) {
      debugPrint('[Whisper] selection load failed: $error');
    }
  }

  static Future<void> select(String id) async {
    selectedSpecId.value = specById(id).id;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_selectionKey, selectedSpecId.value);
  }

  WhisperModelManager({
    Future<Directory> Function()? directoryProvider,
    HttpClient Function()? httpClientProvider,
    this.spec = tiny,
  }) : _directoryProvider =
           directoryProvider ?? StorageService.instance.asrModelsDir,
       _httpClientProvider = httpClientProvider ?? HttpClient.new;

  static const tiny = WhisperModelSpec(
    id: 'whisper-tiny-multilingual',
    filename: 'ggml-tiny.bin',
    downloadUrl: '$_whisperBaseUrl/ggml-tiny.bin',
    revision: _whisperRevision,
    sizeBytes: 77691713,
    sha256: 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
    minimumRamGB: 0.5,
  );

  static const base = WhisperModelSpec(
    id: 'whisper-base-multilingual',
    filename: 'ggml-base.bin',
    downloadUrl: '$_whisperBaseUrl/ggml-base.bin',
    revision: _whisperRevision,
    sizeBytes: 147951465,
    sha256: '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
    minimumRamGB: 1,
    displayName: 'Whisper Base',
    summary: 'Balanced · multilingual',
  );

  static const baseEnglish = WhisperModelSpec(
    id: 'whisper-base-en',
    filename: 'ggml-base.en.bin',
    downloadUrl: '$_whisperBaseUrl/ggml-base.en.bin',
    revision: _whisperRevision,
    sizeBytes: 147964211,
    sha256: 'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002',
    minimumRamGB: 1,
    displayName: 'Whisper Base (English)',
    summary: 'Balanced · English only',
    englishOnly: true,
  );

  static const small = WhisperModelSpec(
    id: 'whisper-small-multilingual',
    filename: 'ggml-small.bin',
    downloadUrl: '$_whisperBaseUrl/ggml-small.bin',
    revision: _whisperRevision,
    sizeBytes: 487601967,
    sha256: '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
    minimumRamGB: 2,
    displayName: 'Whisper Small',
    summary: 'More accurate · multilingual',
  );

  static const largeV3TurboQ5 = WhisperModelSpec(
    id: 'whisper-large-v3-turbo-q5',
    filename: 'ggml-large-v3-turbo-q5_0.bin',
    downloadUrl: '$_whisperBaseUrl/ggml-large-v3-turbo-q5_0.bin',
    revision: _whisperRevision,
    sizeBytes: 574041195,
    sha256: '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
    minimumRamGB: 3,
    displayName: 'Whisper Large v3 Turbo',
    summary: 'Most accurate · Q5 quantized · multilingual',
  );

  final Future<Directory> Function() _directoryProvider;
  final HttpClient Function() _httpClientProvider;
  final WhisperModelSpec spec;
  bool _downloading = false;
  int _receivedBytes = 0;
  String _failure = '';
  Future<String?>? _verification;
  String? _activeRevision;
  bool _canRollback = false;
  HttpClient? _activeClient;
  bool _cancelRequested = false;

  bool get downloading => _downloading;
  int get receivedBytes => _receivedBytes;
  double get progress => _receivedBytes / spec.sizeBytes;
  String get failure => _failure;
  String? get activeRevision => _activeRevision;
  bool get updateAvailable =>
      _activeRevision != null && _activeRevision != spec.revision;
  bool get canRollback => _canRollback;

  Future<String?> installedPath() => _verification ??= _verifyInstalledPath();

  Future<String?> _verifyInstalledPath() async {
    final directory = await _directoryProvider();
    final file = File(p.join(directory.path, spec.filename));
    final manifest = await _readManifest(directory);
    final active = _slot(manifest, 'active');
    final previous = _slot(manifest, 'previous');
    final expectedSize = active?['size_bytes'] as int? ?? spec.sizeBytes;
    final expectedSha = active?['sha256'] as String? ?? spec.sha256;
    if (!await file.exists() || await file.length() != expectedSize) {
      return null;
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expectedSha) return null;
    _activeRevision =
        active?['revision'] as String? ??
        (expectedSha == spec.sha256 ? spec.revision : null);
    final previousFile = File('${file.path}.previous');
    _canRollback =
        previous != null &&
        await _matches(
          previousFile,
          previous['size_bytes'] as int? ?? -1,
          previous['sha256'] as String? ?? '',
        );
    return file.path;
  }

  Future<String> install() async {
    if (_downloading) throw StateError('Whisper model download is in progress');
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, spec.filename));
    if (await _matches(destination, spec.sizeBytes, spec.sha256)) {
      _verification = null;
      final verified = await _verifyInstalledPath();
      if (verified != null && _activeRevision == spec.revision) {
        _verification = Future<String?>.value(verified);
        return verified;
      }
    }
    _downloading = true;
    _receivedBytes = 0;
    _failure = '';
    _cancelRequested = false;
    notifyListeners();
    await PowerService.instance.startDownload(spec.displayName);

    final staging = File('${destination.path}.part');
    final previous = File('${destination.path}.previous');
    final client = _httpClientProvider();
    _activeClient = client;
    IOSink? sink;
    try {
      if (await staging.exists()) await staging.delete();
      final request = await client.getUrl(Uri.parse(spec.downloadUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Whisper model download returned HTTP ${response.statusCode}',
        );
      }
      sink = staging.openWrite();
      await for (final chunk in response) {
        if (_cancelRequested) throw const WhisperDownloadCancelled();
        sink.add(chunk);
        _receivedBytes = _receivedBytes + chunk.length;
        notifyListeners();
      }
      if (_cancelRequested) throw const WhisperDownloadCancelled();
      await sink.close();
      sink = null;
      final size = await staging.length();
      if (size != spec.sizeBytes) {
        throw StateError('Whisper model size mismatch: $size');
      }
      final digest = await sha256.bind(staging.openRead()).first;
      if (digest.toString() != spec.sha256) {
        throw StateError('Whisper model checksum verification failed');
      }
      final oldManifest = await _readManifest(directory);
      Map<String, Object?>? oldActive = _slot(oldManifest, 'active');
      var rollbackSlot = _slot(oldManifest, 'previous');
      if (await destination.exists()) {
        final activeValid =
            oldActive != null &&
            await _matches(
              destination,
              oldActive['size_bytes'] as int? ?? -1,
              oldActive['sha256'] as String? ?? '',
            );
        oldActive ??= {
          'revision': 'legacy',
          'size_bytes': await destination.length(),
          'sha256': (await sha256.bind(destination.openRead()).first)
              .toString(),
        };
        if (activeValid || oldManifest == null) {
          if (await previous.exists()) await previous.delete();
          await destination.rename(previous.path);
          rollbackSlot = oldActive;
        } else {
          // Never publish or retain a checksum-invalid active slot.
          await destination.delete();
        }
      }
      await staging.rename(destination.path);
      await _writeManifest(
        directory,
        active: _specJson(spec),
        previous: rollbackSlot,
      );
      _activeRevision = spec.revision;
      _canRollback = rollbackSlot != null;
      _verification = Future<String?>.value(destination.path);
      return destination.path;
    } on Object catch (error) {
      if (_cancelRequested) {
        _failure = '';
        if (await staging.exists()) await staging.delete();
        throw const WhisperDownloadCancelled();
      }
      _failure = error.toString();
      if (await staging.exists()) await staging.delete();
      rethrow;
    } finally {
      await sink?.close();
      client.close(force: true);
      _activeClient = null;
      _downloading = false;
      await PowerService.instance.stopDownload();
      notifyListeners();
    }
  }

  /// Removes this model and its rollback slot from disk.
  Future<void> delete() async {
    if (_downloading) cancelDownload();
    final directory = await _directoryProvider();
    for (final name in [
      spec.filename,
      '${spec.filename}.previous',
      '${spec.filename}.part',
      '${spec.filename}.slots.json',
    ]) {
      final file = File(p.join(directory.path, name));
      if (await file.exists()) await file.delete();
    }
    _verification = null;
    _activeRevision = null;
    _canRollback = false;
    notifyListeners();
  }

  void cancelDownload() {
    if (!_downloading) return;
    _cancelRequested = true;
    _activeClient?.close(force: true);
  }

  Future<bool> rollback() async {
    final directory = await _directoryProvider();
    final destination = File(p.join(directory.path, spec.filename));
    final previous = File('${destination.path}.previous');
    final manifest = await _readManifest(directory);
    final activeSlot = _slot(manifest, 'active');
    final previousSlot = _slot(manifest, 'previous');
    if (activeSlot == null ||
        previousSlot == null ||
        !await _matches(
          previous,
          previousSlot['size_bytes'] as int? ?? -1,
          previousSlot['sha256'] as String? ?? '',
        )) {
      return false;
    }
    final temporary = File('${destination.path}.rollback-part');
    if (await temporary.exists()) await temporary.delete();
    await destination.rename(temporary.path);
    try {
      await previous.rename(destination.path);
      await temporary.rename(previous.path);
      await _writeManifest(
        directory,
        active: previousSlot,
        previous: activeSlot,
      );
      _activeRevision = previousSlot['revision'] as String?;
      _canRollback = true;
      _verification = Future<String?>.value(destination.path);
      notifyListeners();
      return true;
    } on Object {
      if (!await destination.exists() && await temporary.exists()) {
        await temporary.rename(destination.path);
      }
      rethrow;
    }
  }

  Future<bool> _matches(File file, int size, String digest) async {
    if (size < 0 ||
        digest.isEmpty ||
        !await file.exists() ||
        await file.length() != size) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() == digest;
  }

  Future<Map<String, Object?>?> _readManifest(Directory directory) async {
    final file = File(p.join(directory.path, '${spec.filename}.slots.json'));
    if (!await file.exists()) return null;
    try {
      return (jsonDecode(await file.readAsString()) as Map<Object?, Object?>)
          .cast<String, Object?>();
    } on Object {
      return null;
    }
  }

  Future<void> _writeManifest(
    Directory directory, {
    required Map<String, Object?> active,
    required Map<String, Object?>? previous,
  }) async {
    final destination = File(
      p.join(directory.path, '${spec.filename}.slots.json'),
    );
    final staging = File('${destination.path}.part');
    await staging.writeAsString(
      jsonEncode({'schema_version': 1, 'active': active, 'previous': previous}),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await staging.rename(destination.path);
  }

  static Map<String, Object?>? _slot(
    Map<String, Object?>? manifest,
    String name,
  ) => switch (manifest?[name]) {
    final Map<Object?, Object?> value => value.cast<String, Object?>(),
    _ => null,
  };

  static Map<String, Object?> _specJson(WhisperModelSpec spec) => {
    'revision': spec.revision,
    'size_bytes': spec.sizeBytes,
    'sha256': spec.sha256,
  };
}

class WhisperDownloadCancelled implements Exception {
  const WhisperDownloadCancelled();

  @override
  String toString() => 'Whisper model download cancelled';
}
