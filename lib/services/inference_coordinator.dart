import 'dart:async';

import 'inference_contract.dart';

class InferenceExecutionPlan {
  const InferenceExecutionPlan({
    required this.backend,
    required this.loadRequest,
  });

  final BackendKind backend;
  final InferenceLoadRequest loadRequest;
}

class InferenceCoordinator {
  InferenceCoordinator(Iterable<InferenceBackend> backends)
    : _backends = {for (final backend in backends) backend.kind: backend};

  final Map<BackendKind, InferenceBackend> _backends;
  InferenceBackend? _activeBackend;
  bool _generating = false;

  BackendKind? get activeBackend => _activeBackend?.kind;
  bool get isGenerating => _generating;

  Stream<InferenceEvent> generate({
    required List<InferenceExecutionPlan> plans,
    required InferenceRequest request,
  }) async* {
    if (_generating) {
      yield const InferenceFailure(
        code: 'generation_active',
        message: 'Another local generation is already active',
        retryable: true,
      );
      return;
    }
    _generating = true;
    InferenceFailure? lastFailure;

    try {
      for (final plan in plans) {
        final backend = _backends[plan.backend];
        if (backend == null || !backend.supports(plan.loadRequest.variant)) {
          continue;
        }

        try {
          if (_activeBackend != null && _activeBackend != backend) {
            await _activeBackend!.unload();
          }
          final loadClock = Stopwatch()..start();
          await backend.load(plan.loadRequest);
          loadClock.stop();
          _activeBackend = backend;
          yield InferenceLoadCompleted(
            backend: backend.kind,
            loadDuration: loadClock.elapsed,
          );
        } catch (error) {
          lastFailure = InferenceFailure(
            code: 'backend_load_failed',
            message: error.toString(),
            retryable: true,
          );
          await backend.unload();
          continue;
        }

        var emittedToken = false;
        var retryNextBackend = false;
        await for (final event in backend.generate(request)) {
          if (event is InferenceToken) emittedToken = true;
          if (event is InferenceFailure) {
            lastFailure = event;
            if (!emittedToken && event.beforeFirstToken && event.retryable) {
              retryNextBackend = true;
              break;
            }
          }
          yield event;
        }

        if (retryNextBackend) {
          await backend.unload();
          _activeBackend = null;
          continue;
        }
        return;
      }

      yield lastFailure ??
          const InferenceFailure(
            code: 'no_runnable_backend',
            message: 'No installed backend can run this model variant',
            retryable: false,
          );
    } finally {
      _generating = false;
    }
  }

  /// Loads the first plan a backend accepts without generating. Returns the
  /// last failure message, or null once a backend holds the model.
  Future<String?> preload(List<InferenceExecutionPlan> plans) async {
    if (_generating) return 'Another local generation is already active';
    String? lastFailure;
    for (final plan in plans) {
      final backend = _backends[plan.backend];
      if (backend == null || !backend.supports(plan.loadRequest.variant)) {
        continue;
      }
      try {
        if (_activeBackend != null && _activeBackend != backend) {
          await _activeBackend!.unload();
          _activeBackend = null;
        }
        await backend.load(plan.loadRequest);
        _activeBackend = backend;
        return null;
      } catch (error) {
        lastFailure = error.toString();
        await backend.unload();
      }
    }
    return lastFailure ?? 'No installed backend can run this model variant';
  }

  Future<void> cancel() => _activeBackend?.cancel() ?? Future.value();

  Future<void> unload() async {
    await _activeBackend?.unload();
    _activeBackend = null;
  }
}
