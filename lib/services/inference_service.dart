import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/catalog_entry.dart';
import '../data/installed_model.dart';
import '../data/imported_model.dart';
import 'device_info_service.dart';
import 'inference_contract.dart';
import 'inference_coordinator.dart';
import 'inference_memory_policy.dart';
import 'imported_model_service.dart';
import 'llama_cpp_backend.dart';
import 'model_download_service.dart';
import 'model_package_service.dart';
import 'mlx_backend.dart';
import 'turbo_quant_backend.dart';

/// Coordinates MLX, TurboQuant, and upstream llama.cpp local inference.
///
/// TurboQuant and MLX are tried only on supported platforms. Upstream
/// llama.cpp retains the portable GGUF fallback and runs in its worker isolate;
/// its vendored UTF-8 patch preserves multilingual token boundaries.
class InferenceService extends ChangeNotifier {
  InferenceService._() {
    final platform = DeviceInfoService.detect().platform;
    _mlx = MlxBackend(platform: platform);
    _turboQuant = TurboQuantBackend(platform: platform);
    _llamaCpp = LlamaCppBackend(platform: platform);
    _coordinator = InferenceCoordinator([_mlx, _turboQuant, _llamaCpp]);
  }

  static final InferenceService instance = InferenceService._();

  late final MlxBackend _mlx;
  late final TurboQuantBackend _turboQuant;
  late final LlamaCppBackend _llamaCpp;
  late final InferenceCoordinator _coordinator;
  String? _activeModelId;
  bool _generating = false;
  bool _loading = false;
  double? _currentTokensPerSecond;
  double? _lastTokensPerSecond;
  bool _lastOutputWasTruncated = false;

  String? get activeModelId => _activeModelId;
  bool get hasLoadedModel =>
      _activeModelId != null && _coordinator.activeBackend != null;
  bool get isGenerating => _generating;
  bool get isLoading => _loading;

  /// Whether [modelId] is resident in memory right now.
  bool isLoaded(String modelId) =>
      modelId.isNotEmpty && hasLoadedModel && _activeModelId == modelId;
  double? get currentTokensPerSecond => _currentTokensPerSecond;
  double? get lastTokensPerSecond => _lastTokensPerSecond;
  bool get lastOutputWasTruncated => _lastOutputWasTruncated;

  Stream<String> generate({
    required String modelId,
    required String prompt,
    String systemPrompt = '',
    int maxOutputTokens = 768,
    double temperature = 0.7,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    List<String> stop = const [],
  }) async* {
    if (modelId.isEmpty) {
      throw const InferenceException('Select a downloaded model first.');
    }
    if (_generating) {
      throw const InferenceException(
        'The local model is already generating a response.',
      );
    }

    final profile = DeviceInfoService.detect();
    final installed = ModelPackageService.instance.runnableVariantsForModelId(
      modelId,
    );
    final imported = ImportedModelService.instance.byId(modelId);
    final legacyPath = await ModelDownloadService.instance.modelPath(modelId);
    if (installed.isEmpty && legacyPath == null && imported == null) {
      throw InferenceException(
        'Model "$modelId" is not downloaded. Download it from Models first.',
      );
    }

    final mobile = Platform.isAndroid || Platform.isIOS;
    const memoryPolicy = InferenceMemoryPolicy();
    final primaryBackend =
        installed.any(
          (record) => record.backends.any(
            (backend) => backend.toLowerCase() == BackendKind.mlx.catalogName,
          ),
        )
        ? BackendKind.mlx
        : BackendKind.llamaCpp;
    final contextSize = memoryPolicy
        .plan(device: profile, backend: primaryBackend)
        .contextSize;
    final outputTokens = mobile
        ? maxOutputTokens.clamp(1, contextSize - 256)
        : maxOutputTokens;

    _activeModelId = modelId;
    _generating = true;
    _currentTokensPerSecond = null;
    _lastOutputWasTruncated = false;
    notifyListeners();
    debugPrint(
      '[Inference] starting $modelId (ctx=$contextSize, max=$outputTokens)',
    );

    try {
      final plans = await _plansFor(
        installed: installed,
        imported: imported,
        legacyPath: legacyPath,
        profile: profile,
        memoryPolicy: memoryPolicy,
        modelId: modelId,
      );
      final events = _coordinator.generate(
        plans: plans,
        request: InferenceRequest(
          messages: [
            if (systemPrompt.trim().isNotEmpty)
              InferenceMessage(role: 'system', content: systemPrompt.trim()),
            InferenceMessage(role: 'user', content: prompt),
          ],
          maxOutputTokens: outputTokens,
          sampling: InferenceSampling(
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
          ),
          stopSequences: stop,
        ),
      );

      var tokenCount = 0;
      await for (final event in events) {
        switch (event) {
          case InferenceLoadCompleted(:final backend, :final loadDuration):
            debugPrint(
              '[Inference] ${backend.catalogName} ready in '
              '${loadDuration.inMilliseconds} ms',
            );
            notifyListeners();
          case InferenceToken(:final text):
            tokenCount++;
            if (text.isNotEmpty) yield text;
          case InferenceMetrics(:final decodeTokensPerSecond):
            if (decodeTokensPerSecond != null) {
              _currentTokensPerSecond = decodeTokensPerSecond;
              notifyListeners();
            }
          case InferenceFailure(:final message):
            throw InferenceException(_friendlyError(message));
          case InferenceCompleted(:final reason):
            _lastTokensPerSecond = _currentTokensPerSecond;
            _lastOutputWasTruncated = reason == InferenceFinishReason.length;
            debugPrint('[Inference] generation completed ($tokenCount tokens)');
        }
      }
    } catch (error) {
      if (error is InferenceException) rethrow;
      throw InferenceException(_friendlyError(error.toString()));
    } finally {
      _generating = false;
      notifyListeners();
    }
  }

  Future<List<InferenceExecutionPlan>> _plansFor({
    required List<InstalledModel> installed,
    required ImportedModel? imported,
    required String? legacyPath,
    required DeviceProfile profile,
    required InferenceMemoryPolicy memoryPolicy,
    required String modelId,
  }) async {
    final plans = <InferenceExecutionPlan>[];
    final ordered = [...installed]
      ..sort(
        (left, right) =>
            _backendPriority(left).compareTo(_backendPriority(right)),
      );
    for (final record in ordered) {
      final packagePath = await ModelPackageService.instance.packagePath(
        record.variantId,
      );
      if (packagePath == null) continue;
      final variant = _variantFromInstalled(record, profile.platform);
      for (final backend in _orderedBackends(record, profile.platform)) {
        final memoryPlan = memoryPolicy.plan(device: profile, backend: backend);
        plans.add(
          InferenceExecutionPlan(
            backend: backend,
            loadRequest: InferenceLoadRequest(
              variant: variant,
              packagePath: packagePath,
              contextSize: memoryPlan.contextSize,
              gpuLayerCount: memoryPlan.gpuLayerCount,
            ),
          ),
        );
      }
    }
    if (imported != null) {
      final variant = _variantFromImported(imported, profile.platform);
      final importedBackends = imported.format.toLowerCase() == 'mlx'
          ? const [BackendKind.mlx]
          : _desktopGgufBackends(profile.platform);
      for (final backend in importedBackends) {
        final backendMemoryPlan = memoryPolicy.plan(
          device: profile,
          backend: backend,
        );
        plans.add(
          InferenceExecutionPlan(
            backend: backend,
            loadRequest: InferenceLoadRequest(
              variant: variant,
              packagePath: imported.path,
              contextSize: backendMemoryPlan.contextSize,
              gpuLayerCount: backendMemoryPlan.gpuLayerCount,
            ),
          ),
        );
      }
    }
    if (legacyPath != null &&
        !plans.any(
          (plan) =>
              plan.backend == BackendKind.llamaCpp &&
              plan.loadRequest.packagePath == legacyPath,
        )) {
      final legacyVariant = _legacyVariant(
        modelId,
        legacyPath,
        profile.platform,
      );
      for (final backend in _desktopGgufBackends(profile.platform)) {
        final backendMemoryPlan = memoryPolicy.plan(
          device: profile,
          backend: backend,
        );
        plans.add(
          InferenceExecutionPlan(
            backend: backend,
            loadRequest: InferenceLoadRequest(
              variant: legacyVariant,
              packagePath: legacyPath,
              contextSize: backendMemoryPlan.contextSize,
              gpuLayerCount: backendMemoryPlan.gpuLayerCount,
            ),
          ),
        );
      }
    }
    return plans;
  }

  /// Loads [modelId] into memory without generating, so the first request is
  /// fast. Used by Settings and by the LAN `/v1/models/load` endpoint.
  Future<void> load(String modelId) async {
    if (_generating) {
      throw const InferenceException(
        'Wait for the current response to finish before loading a model.',
      );
    }
    final profile = DeviceInfoService.detect();
    final installed = ModelPackageService.instance.runnableVariantsForModelId(
      modelId,
    );
    final imported = ImportedModelService.instance.byId(modelId);
    final legacyPath = await ModelDownloadService.instance.modelPath(modelId);
    if (installed.isEmpty && legacyPath == null && imported == null) {
      throw InferenceException(
        'Model "$modelId" is not downloaded on this device.',
      );
    }
    final plans = await _plansFor(
      installed: installed,
      imported: imported,
      legacyPath: legacyPath,
      profile: profile,
      memoryPolicy: const InferenceMemoryPolicy(),
      modelId: modelId,
    );
    _loading = true;
    notifyListeners();
    try {
      final failure = await _coordinator.preload(plans);
      if (failure != null) {
        throw InferenceException(_friendlyError(failure));
      }
      _activeModelId = modelId;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> cancel() => _coordinator.cancel();

  Future<void> unload() async {
    await _coordinator.unload();
    _activeModelId = null;
    notifyListeners();
  }

  static String _friendlyError(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('memory') || lower.contains('allocation')) {
      return 'This model does not fit in available memory. Try a smaller or more heavily quantized GGUF model.';
    }
    if (lower.contains('library') || lower.contains('dynamiclibrary')) {
      return 'The llama.cpp runtime is unavailable for this device build. Reinstall the app with the native runtime included.';
    }
    return 'Generation failed: $message';
  }

  static int _backendPriority(InstalledModel model) =>
      model.backends.any((backend) => backend.toLowerCase() == 'mlx') ? 0 : 1;

  static List<BackendKind> _orderedBackends(
    InstalledModel model,
    String platform,
  ) {
    final result = <BackendKind>[];
    if (model.format.toLowerCase() == 'gguf' &&
        _supportsTurboQuantPlatform(platform)) {
      result.add(BackendKind.turboQuant);
    }
    for (final kind in const [BackendKind.mlx, BackendKind.llamaCpp]) {
      if (model.backends.any(
        (backend) => backend.toLowerCase() == kind.catalogName.toLowerCase(),
      )) {
        result.add(kind);
      }
    }
    return result;
  }

  static ModelVariant _variantFromInstalled(
    InstalledModel model,
    String platform,
  ) {
    final backends = [...model.backends];
    if (model.format.toLowerCase() == 'gguf' &&
        _supportsTurboQuantPlatform(platform) &&
        !backends.contains(BackendKind.turboQuant.catalogName)) {
      backends.add(BackendKind.turboQuant.catalogName);
    }
    return ModelVariant(
      id: model.variantId,
      modelId: model.modelId,
      format: model.format,
      quantization: '',
      files: model.files
          .map(
            (file) => Artifact(
              id: file.artifactId,
              role: 'model',
              format: model.format,
              quantization: '',
              filename: file.relativePath,
              repositoryId: '',
              downloadUrl: '',
              backend: model.backends.firstOrNull ?? '',
            ),
          )
          .toList(growable: false),
      platforms: [platform],
      compatibleBackends: backends,
    );
  }

  static ModelVariant _legacyVariant(
    String modelId,
    String path,
    String platform,
  ) => ModelVariant(
    id: modelId,
    modelId: modelId,
    format: 'gguf',
    quantization: '',
    files: [
      Artifact(
        id: '$modelId-model',
        role: 'model',
        format: 'gguf',
        quantization: '',
        filename: path,
        repositoryId: '',
        downloadUrl: '',
        backend: BackendKind.llamaCpp.catalogName,
      ),
    ],
    platforms: [platform],
    compatibleBackends: [
      if (_supportsTurboQuantPlatform(platform))
        BackendKind.turboQuant.catalogName,
      BackendKind.llamaCpp.catalogName,
    ],
  );

  static ModelVariant _variantFromImported(
    ImportedModel model,
    String platform,
  ) => ModelVariant(
    id: model.variantId,
    modelId: model.id,
    format: model.format,
    quantization: model.quantization,
    files: [
      Artifact(
        id: '${model.id}-model',
        role: 'model',
        format: model.format,
        quantization: model.quantization,
        filename: model.path,
        repositoryId: '',
        downloadUrl: '',
        backend: model.backend,
      ),
    ],
    platforms: [platform],
    compatibleBackends: [
      if (model.format.toLowerCase() == 'mlx')
        BackendKind.mlx.catalogName
      else ...[
        if (_supportsTurboQuantPlatform(platform))
          BackendKind.turboQuant.catalogName,
        BackendKind.llamaCpp.catalogName,
      ],
    ],
  );

  static List<BackendKind> _desktopGgufBackends(String platform) => [
    if (_supportsTurboQuantPlatform(platform)) BackendKind.turboQuant,
    BackendKind.llamaCpp,
  ];

  static bool _supportsTurboQuantPlatform(String platform) =>
      platform.startsWith('linux-') || platform.startsWith('windows-');
}

class InferenceException implements Exception {
  const InferenceException(this.message);

  final String message;

  @override
  String toString() => message;
}
