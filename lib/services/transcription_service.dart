import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:erebrus_speech/erebrus_speech.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../data/transcription_session.dart';
import 'inference_service.dart';
import 'transcription_contract.dart';
import 'transcription_session_repository.dart';
import 'voice_preferences.dart';
import 'whisper_cpp_backend.dart';
import 'whisper_model_manager.dart';

enum TranscriptionUiState {
  ready,
  preparing,
  recording,
  paused,
  finalizing,
  complete,
  failed,
}

enum TranscriptionShareKind { transcript, audio, both }

@visibleForTesting
AudioContext transcriptionPlaybackAudioContext() =>
    AudioContextConfig(route: AudioContextConfigRoute.speaker).build();

@visibleForTesting
String resolveTranscriptionLocale(String locale, {String? deviceLocale}) {
  final requested = locale.trim();
  if (requested.isNotEmpty && requested.toLowerCase() != 'auto') {
    return requested;
  }
  return deviceLocale ?? ui.PlatformDispatcher.instance.locale.toLanguageTag();
}

class TranscriptionService extends ChangeNotifier {
  static final TranscriptionService instance = TranscriptionService();

  TranscriptionService({
    this.speech = const ErebrusSpeech(),
    TranscriptionSessionRepository? repository,
    AudioPlayer? audioPlayer,
    AudioRecorder? recorder,
  }) : _repository = repository ?? TranscriptionSessionRepository.instance,
       _audioPlayer = audioPlayer ?? AudioPlayer(),
       _recorder = recorder ?? AudioRecorder();

  final ErebrusSpeech speech;
  final TranscriptionSessionRepository _repository;
  final AudioPlayer _audioPlayer;
  final AudioRecorder _recorder;
  final List<TranscriptSegment> _segments = [];
  final Stopwatch _recordingClock = Stopwatch();

  StreamSubscription<SpeechTranscriptionEvent>? _subscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Timer? _ticker;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  TranscriptionUiState _state = TranscriptionUiState.ready;
  String _locale = 'auto';
  String _partialText = '';
  String _error = '';
  String? _activeSessionId;
  TranscriptionSession? _current;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;
  double _playbackSpeed = 1;
  bool _playing = false;
  bool _initialized = false;
  bool _usingWhisper = false;
  bool _cancelRequested = false;
  String? _activeAudioPath;
  WhisperCppBackend? _whisperBackend;
  Future<void> _draftCheckpoint = Future.value();

  TranscriptionUiState get state => _state;
  Duration get elapsed => _elapsed;
  String get locale => _locale;
  String get partialText => _partialText;
  String get error => _error;
  String get finalizedText => _segments
      .map((segment) => segment.text.trim())
      .where((text) => text.isNotEmpty)
      .join(' ');
  String get visibleTranscript => [
    finalizedText,
    if (_partialText.trim().isNotEmpty) _partialText.trim(),
  ].where((text) => text.isNotEmpty).join(' ');
  List<TranscriptSegment> get segments => List.unmodifiable(_segments);
  List<TranscriptionSession> get sessions => _repository.sessions;
  TranscriptionSession? get current => _current;
  Duration get playbackPosition => _playbackPosition;
  Duration get playbackDuration => _playbackDuration;
  double get playbackSpeed => _playbackSpeed;
  bool get isPlaying => _playing;
  bool get isCapturing =>
      _state == TranscriptionUiState.recording ||
      _state == TranscriptionUiState.paused;
  bool get isBusy =>
      _state == TranscriptionUiState.preparing ||
      _state == TranscriptionUiState.finalizing;
  bool get hasUnfinishedRecording => isCapturing || isBusy;
  TranscriptionBackendKind get activeBackend => _usingWhisper
      ? TranscriptionBackendKind.whisperCpp
      : TranscriptionBackendKind.speechAnalyzer;

  List<TranscriptionSession> searchSessions(String query) =>
      _repository.search(query);

  Future<int> storageBytes() => _repository.storageBytes();

  Future<Directory> exportAll(
    Directory destination, {
    required bool userConsented,
  }) => _repository.exportTo(destination, userConsented: userConsented);

  Future<void> deleteAll() async {
    await _repository.deleteAll();
    _reset();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      _playbackPosition = position;
      notifyListeners();
    });
    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      _playbackDuration = duration;
      notifyListeners();
    });
    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
      state,
    ) {
      _playing = state == PlayerState.playing;
      notifyListeners();
    });
    await _repository.load();
    if (_repository.sessions.isNotEmpty) _current = _repository.sessions.first;
    notifyListeners();
  }

  Future<SpeechAnalyzerProbe> probe({String locale = 'auto'}) =>
      speech.probe(locale: resolveTranscriptionLocale(locale));

  Future<void> start({String locale = 'auto'}) async {
    if (hasUnfinishedRecording) return;
    await stopPlayback();
    _state = TranscriptionUiState.preparing;
    _error = '';
    _locale = locale;
    _segments.clear();
    _partialText = '';
    _elapsed = Duration.zero;
    _recordingClock
      ..reset()
      ..stop();
    _cancelRequested = false;
    _activeAudioPath = null;
    _whisperBackend = null;
    _current = null;
    notifyListeners();

    try {
      final sessionId = const Uuid().v4();
      final directory = await _repository.createSessionDirectory(sessionId);
      _activeSessionId = sessionId;
      _startedAt = DateTime.now().toUtc();
      await _saveDraft(status: TranscriptionSessionStatus.recording);
      _throwIfCancelled();
      SpeechAnalyzerProbe? speechProbe;
      final resolvedLocale = resolveTranscriptionLocale(locale);
      final engine = VoicePreferences.instance.engine;
      if (engine != DictationEngine.whisper) {
        try {
          speechProbe = await speech.probe(locale: resolvedLocale);
        } on Object {
          speechProbe = null;
        }
      }
      final useSpeechAnalyzer =
          speechProbe?.available == true &&
          speechProbe?.localeSupported == true;
      if (engine == DictationEngine.system && !useSpeechAnalyzer) {
        throw StateError(
          'System speech is unavailable for this language on this device. '
          'Choose Local transcription in Settings → Voice.',
        );
      }
      _usingWhisper = !useSpeechAnalyzer;
      await _saveDraft(status: TranscriptionSessionStatus.recording);
      if (useSpeechAnalyzer) {
        _locale = speechProbe!.locale.isEmpty
            ? resolvedLocale
            : speechProbe.locale;
        await _subscription?.cancel();
        _subscription = speech.events.listen(
          _handleEvent,
          onError: (Object error) =>
              unawaited(_failAndCleanup(error.toString())),
        );
        _activeAudioPath = await speech.start(
          sessionDirectory: directory.path,
          locale: resolvedLocale,
        );
      } else {
        _locale = locale.trim().isEmpty ? 'auto' : locale;
        final modelPath = await WhisperModelManager.instance.installedPath();
        if (modelPath == null) {
          final spec = WhisperModelManager.selectedSpec;
          throw StateError(
            'Download ${spec.displayName} (${spec.sizeLabel}) in Settings → Voice before recording on this device',
          );
        }
        if (!await _recorder.hasPermission()) {
          throw StateError('Microphone permission is required');
        }
        await InferenceService.instance.unload();
        _activeAudioPath = p.join(directory.path, 'audio.wav');
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: _activeAudioPath!,
        );
      }
      _throwIfCancelled();
      _startedAt = DateTime.now().toUtc();
      _recordingClock
        ..reset()
        ..start();
      _state = TranscriptionUiState.recording;
      await _saveDraft(status: TranscriptionSessionStatus.recording);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_state == TranscriptionUiState.recording) {
          _elapsed = _recordingClock.elapsed;
          notifyListeners();
        }
      });
      notifyListeners();
    } on _TranscriptionCancelled {
      await _discardActiveSession();
    } on Object catch (error) {
      await _failAndCleanup(error.toString());
    }
  }

  Future<void> pause() async {
    if (_state != TranscriptionUiState.recording) return;
    try {
      if (_usingWhisper) {
        await _recorder.pause();
      } else {
        await speech.pause();
      }
      _recordingClock.stop();
      _elapsed = _recordingClock.elapsed;
      _state = TranscriptionUiState.paused;
      await _saveDraft(status: TranscriptionSessionStatus.recording);
      notifyListeners();
    } on Object catch (error) {
      await _failAndCleanup(error.toString());
    }
  }

  Future<void> resume() async {
    if (_state != TranscriptionUiState.paused) return;
    try {
      if (_usingWhisper) {
        await _recorder.resume();
      } else {
        await speech.resume();
      }
      _recordingClock.start();
      _state = TranscriptionUiState.recording;
      _error = '';
      notifyListeners();
    } on Object catch (error) {
      await _failAndCleanup(error.toString());
    }
  }

  Future<TranscriptionSession?> stop() async {
    if (_state != TranscriptionUiState.recording &&
        _state != TranscriptionUiState.paused) {
      return _current;
    }
    _state = TranscriptionUiState.finalizing;
    _ticker?.cancel();
    _recordingClock.stop();
    _elapsed = _recordingClock.elapsed;
    notifyListeners();
    try {
      final sessionId = _activeSessionId;
      final createdAt = _startedAt;
      if (sessionId == null || createdAt == null) {
        throw StateError('The transcription session identity was lost');
      }
      await _saveDraft(status: TranscriptionSessionStatus.finalizing);
      late final String raw;
      late final String audioPath;
      var backend = TranscriptionBackendKind.speechAnalyzer;
      var backendVersion = 'SpeechAnalyzer';
      if (_usingWhisper) {
        final recordedPath = await _recorder.stop();
        if (recordedPath == null) {
          throw StateError('The recorder did not return an audio file');
        }
        audioPath = recordedPath;
        await InferenceService.instance.unload();
        final modelPath = await WhisperModelManager.instance.installedPath();
        if (modelPath == null) {
          throw StateError('The verified Whisper model is unavailable');
        }
        final whisperBackend = WhisperCppBackend(modelPath: modelPath);
        _whisperBackend = whisperBackend;
        await whisperBackend.prepare(TranscriptionConfig(locale: _locale));
        await for (final event in whisperBackend.transcribe(
          AudioInput.file(audioPath),
        )) {
          _throwIfCancelled();
          switch (event) {
            case TranscriptionSegmentUpdated(:final segment):
              _segments.add(segment);
              notifyListeners();
            case TranscriptionFailure(:final message):
              throw StateError(message);
            default:
              break;
          }
        }
        final result = await whisperBackend.finish();
        _whisperBackend = null;
        raw = result.text;
        backend = TranscriptionBackendKind.whisperCpp;
        backendVersion = 'whisper.cpp 1.8.3';
      } else {
        final result = await speech.stop();
        _throwIfCancelled();
        await _subscription?.cancel();
        _subscription = null;
        audioPath = result.audioPath;
        raw = result.transcript.trim().isEmpty
            ? finalizedText
            : result.transcript.trim();
      }
      _throwIfCancelled();
      _current = await _repository.finalize(
        sessionId: sessionId,
        createdAt: createdAt,
        duration: _elapsed,
        locale: _locale,
        rawTranscript: raw,
        segments: _segments,
        audioPath: audioPath,
        backend: backend,
        backendVersion: backendVersion,
        audioSampleRate: _usingWhisper ? 16000 : 0,
        audioChannels: _usingWhisper ? 1 : 0,
      );
      _partialText = '';
      _activeSessionId = null;
      _activeAudioPath = null;
      _state = TranscriptionUiState.complete;
      notifyListeners();
      return _current;
    } on _TranscriptionCancelled {
      await _discardActiveSession();
      return null;
    } on Object catch (error) {
      await _failAndCleanup(error.toString());
      return null;
    }
  }

  Future<void> cancel() async {
    if (!hasUnfinishedRecording) return;
    _cancelRequested = true;
    _ticker?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await _whisperBackend?.cancel();
    try {
      if (_usingWhisper) {
        await _recorder.cancel();
      } else {
        await speech.cancel();
      }
    } on Object {
      // The native session may already have completed while cancellation won.
    }
    await _discardActiveSession();
  }

  Future<void> selectSession(TranscriptionSession session) async {
    await stopPlayback();
    _current = session;
    _state = TranscriptionUiState.complete;
    notifyListeners();
  }

  Future<void> editCurrent(String text) async {
    final current = _current;
    if (current == null) return;
    _current = await _repository.saveEdit(current, text);
    notifyListeners();
  }

  Future<void> playCurrent() async {
    final current = _current;
    if (current == null) return;
    final path = await _repository.audioPath(current);
    if (path == null) throw StateError('This session has no saved audio');
    if (_playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.setPlaybackRate(_playbackSpeed);
      await _audioPlayer.play(
        DeviceFileSource(path),
        ctx: transcriptionPlaybackAudioContext(),
      );
    }
  }

  Future<void> seekCurrent(Duration position) async {
    final duration = _playbackDuration.inMilliseconds > 0
        ? _playbackDuration
        : Duration(milliseconds: _current?.durationMilliseconds ?? 0);
    final clamped = Duration(
      milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds),
    );
    await _audioPlayer.seek(clamped);
    _playbackPosition = clamped;
    notifyListeners();
  }

  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed.clamp(0.5, 2.0);
    await _audioPlayer.setPlaybackRate(_playbackSpeed);
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    if (_playing || _audioPlayer.state == PlayerState.paused) {
      await _audioPlayer.stop();
    }
    _playbackPosition = Duration.zero;
    _playbackDuration = Duration.zero;
    _playing = false;
    notifyListeners();
  }

  Future<void> shareCurrent(
    TranscriptionShareKind kind, {
    ui.Rect? sharePositionOrigin,
  }) async {
    final current = _current;
    if (current == null) return;
    final audioPath = await _repository.audioPath(current);
    final includeTranscript = kind != TranscriptionShareKind.audio;
    final includeAudio = kind != TranscriptionShareKind.transcript;
    if (includeAudio && audioPath == null) {
      throw StateError('This session has no saved audio');
    }
    await SharePlus.instance.share(
      ShareParams(
        subject: 'Erebrus transcription',
        text: includeTranscript ? current.effectiveTranscript : null,
        files: includeAudio ? [XFile(audioPath!)] : null,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  Future<void> linkAnalysisChat(String chatId) async {
    final current = _current;
    if (current == null || chatId.isEmpty) return;
    _current = await _repository.addAnalysisChat(current, chatId);
    notifyListeners();
  }

  Future<void> deleteCurrent({bool keepAudio = false}) async {
    final current = _current;
    if (current == null) return;
    await stopPlayback();
    await _repository.delete(current.id, keepAudio: keepAudio);
    _current = _repository.sessions.firstOrNull;
    _state = _current == null
        ? TranscriptionUiState.ready
        : TranscriptionUiState.complete;
    notifyListeners();
  }

  Future<void> newSession() async {
    await stopPlayback();
    _reset();
  }

  void _handleEvent(SpeechTranscriptionEvent event) {
    switch (event.type) {
      case 'partial':
        _partialText = event.text;
        break;
      case 'final':
        final segment = TranscriptSegment(
          id: '${event.startSeconds ?? 0}-${event.endSeconds ?? 0}-${_segments.length}',
          text: event.text,
          start: _seconds(event.startSeconds),
          end: _seconds(event.endSeconds),
          isFinal: true,
        );
        _segments.add(segment);
        _partialText = '';
        _queueDraftCheckpoint();
        break;
      case 'error':
        unawaited(_failAndCleanup(event.message));
        break;
      case 'interrupted':
        if (_state == TranscriptionUiState.recording) {
          _recordingClock.stop();
          _elapsed = _recordingClock.elapsed;
          _state = TranscriptionUiState.paused;
          _error = event.message;
          _queueDraftCheckpoint();
        }
        break;
      default:
        break;
    }
    notifyListeners();
  }

  Future<void> _failAndCleanup(String message) async {
    _ticker?.cancel();
    _recordingClock.stop();
    _elapsed = _recordingClock.elapsed;
    await _subscription?.cancel();
    _subscription = null;
    try {
      if (_usingWhisper) {
        await _whisperBackend?.cancel();
        _whisperBackend = null;
        final stoppedPath = await _recorder.stop();
        _activeAudioPath ??= stoppedPath;
      } else {
        await speech.cancel();
      }
    } on Object {
      // Preserve the original failure; recovery still inspects the draft dir.
    }
    _error = message;
    _state = TranscriptionUiState.failed;
    await _saveDraft(
      status: TranscriptionSessionStatus.failed,
      failureCode: message,
      includeAudio: true,
    );
    notifyListeners();
  }

  Future<void> _saveDraft({
    required TranscriptionSessionStatus status,
    String? failureCode,
    bool includeAudio = false,
  }) async {
    final sessionId = _activeSessionId;
    final createdAt = _startedAt;
    if (sessionId == null || createdAt == null) return;
    final saved = await _repository.saveDraft(
      sessionId: sessionId,
      createdAt: createdAt,
      duration: _elapsed,
      locale: _locale,
      status: status,
      backend: activeBackend,
      backendVersion: _usingWhisper ? 'whisper.cpp 1.8.3' : 'SpeechAnalyzer',
      rawTranscript: finalizedText,
      segments: _segments,
      audioPath: includeAudio ? _activeAudioPath : null,
      failureCode: failureCode,
    );
    if (_activeSessionId == sessionId &&
        _state != TranscriptionUiState.complete) {
      _current = saved;
    }
  }

  void _queueDraftCheckpoint() {
    _draftCheckpoint = _draftCheckpoint
        .then((_) => _saveDraft(status: TranscriptionSessionStatus.recording))
        .onError((error, _) {
          debugPrint('[Transcription] draft checkpoint failed: $error');
        });
  }

  Future<void> _discardActiveSession() async {
    final sessionId = _activeSessionId;
    if (sessionId != null) {
      await _repository.delete(sessionId);
    }
    _reset();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const _TranscriptionCancelled();
  }

  void _reset() {
    _ticker?.cancel();
    _recordingClock
      ..stop()
      ..reset();
    _state = TranscriptionUiState.ready;
    _segments.clear();
    _partialText = '';
    _error = '';
    _activeSessionId = null;
    _activeAudioPath = null;
    _whisperBackend = null;
    _cancelRequested = false;
    _startedAt = null;
    _elapsed = Duration.zero;
    _current = null;
    notifyListeners();
  }

  static Duration _seconds(double? value) => Duration(
    microseconds: ((value ?? 0) * Duration.microsecondsPerSecond).round(),
  );

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playerStateSubscription?.cancel());
    unawaited(_audioPlayer.dispose());
    unawaited(_recorder.dispose());
    super.dispose();
  }
}

class _TranscriptionCancelled implements Exception {
  const _TranscriptionCancelled();
}
