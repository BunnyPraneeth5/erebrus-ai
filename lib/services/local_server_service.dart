import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';

import '../data/catalog_service.dart';
import '../platform/secure_storage.dart';
import 'inference_service.dart';
import 'imported_model_service.dart';
import 'mdns_config.dart';
import 'model_download_service.dart';
import 'model_package_service.dart';

bool isPublicLocalServerMetadataRequest(String method, String path) =>
    method == 'GET' && path == 'health';

const int kMaxLocalServerPayloadBytes = 10 * 1024 * 1024;

class LocalServerPayloadTooLarge implements Exception {
  const LocalServerPayloadTooLarge();
}

Future<String> readBoundedLocalServerBody(
  Request request, {
  int maxBytes = kMaxLocalServerPayloadBytes,
}) async {
  if (request.contentLength != null && request.contentLength! > maxBytes) {
    throw const LocalServerPayloadTooLarge();
  }

  final body = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in request.read()) {
    received += chunk.length;
    if (received > maxBytes) throw const LocalServerPayloadTooLarge();
    body.add(chunk);
  }
  return utf8.decode(body.takeBytes());
}

Future<String> loadOrCreateLocalServerApiKey({
  required Future<String?> Function() secureRead,
  required Future<void> Function(String value) secureWrite,
  required Future<String?> Function() fallbackRead,
  required Future<void> Function(String value) fallbackWrite,
  required Future<void> Function() fallbackDelete,
  required String Function() generate,
}) async {
  var secureAvailable = true;
  String? key;
  try {
    key = await secureRead();
  } catch (_) {
    secureAvailable = false;
  }
  if (key != null && key.isNotEmpty) return key;

  final fallbackKey = await fallbackRead();
  if (fallbackKey != null && fallbackKey.isNotEmpty) {
    if (secureAvailable) {
      try {
        await secureWrite(fallbackKey);
        await fallbackDelete();
      } catch (_) {
        // Keep the fallback until secure storage becomes available.
      }
    }
    return fallbackKey;
  }

  key = generate();
  if (secureAvailable) {
    try {
      await secureWrite(key);
      return key;
    } catch (_) {
      // Persist below so the key never exists only in process memory.
    }
  }
  await fallbackWrite(key);
  return key;
}

/// A real OpenAI-compatible HTTP server that runs on the device.
///
/// This is the concrete replacement for the mocked "serving on LAN" state.
/// It exposes `/v1/models` and `/v1/chat/completions` and advertises the
/// node over mDNS (`_erebrusai._tcp`) so other devices can discover it.
///
/// GGUF inference is delegated to the same in-process llama.cpp runtime used by
/// the local chat UI.
class LocalServerService extends ChangeNotifier {
  LocalServerService._();
  static final LocalServerService _instance = LocalServerService._();
  static LocalServerService get instance => _instance;

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  String? _apiKey;
  String? _lanAccessToken;
  String? _baseUrl;
  MdnsNodeIdentity? _identity;
  int _port = 11434;

  /// Whether the server is currently accepting connections.
  bool get isRunning => _server != null;

  /// The port the server is listening on, or the default if not running.
  int get port => _port;

  /// The API key clients must send in the `Authorization` header.
  Future<String> get apiKey async {
    if (_apiKey != null) return _apiKey!;
    const storageKey = 'erebrus_local_api_key';
    final key = await loadOrCreateLocalServerApiKey(
      secureRead: () => ErebrusSecureStorage.instance.read(key: storageKey),
      secureWrite: (value) =>
          ErebrusSecureStorage.instance.write(key: storageKey, value: value),
      fallbackRead: () async =>
          (await SharedPreferences.getInstance()).getString(storageKey),
      fallbackWrite: (value) async {
        final stored = await (await SharedPreferences.getInstance()).setString(
          storageKey,
          value,
        );
        if (!stored) throw StateError('Could not persist local server API key');
      },
      fallbackDelete: () async {
        await (await SharedPreferences.getInstance()).remove(storageKey);
      },
      generate: () =>
          'ere_sk_${const Uuid().v4().replaceAll('-', '').substring(0, 24)}',
    );
    _apiKey = key;
    return key;
  }

  /// Best-effort URL for this node, e.g. `http://192.168.1.42:11434`.
  String? get baseUrl => _baseUrl;

  /// Models whose metadata is intentionally visible to peers while serving.
  Set<String> get sharedModelIds => isRunning ? _servableModelIds : const {};

  Set<String> get _servableModelIds => {
    ...ModelDownloadService.instance.completed,
    ...ModelPackageService.instance.installed
        .where((record) => record.runnable)
        .map((record) => record.modelId),
    ...ImportedModelService.instance.models.map((record) => record.id),
  };

  /// Starts the HTTP server and begins mDNS advertising.
  Future<void> start({int port = 11434}) async {
    if (_server != null) return;
    _port = port;

    await apiKey;
    // This capability is intentionally short-lived. Peers discover it through
    // the same local-only mDNS advertisement as the server, while manually
    // paired clients can continue using the persistent API key.
    _lanAccessToken =
        'ere_lan_${const Uuid().v4().replaceAll('-', '').substring(0, 24)}';
    _identity = await loadMdnsNodeIdentity();
    try {
      _server = await shelf_io.serve(
        _handler,
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
      _baseUrl = await _guessUrl(port);
      await _startBroadcast(port);
      notifyListeners();
      debugPrint('[Server] listening on $baseUrl');
    } catch (e) {
      debugPrint('[Server] could not start: $e');
      _server = null;
      _baseUrl = null;
      _lanAccessToken = null;
      rethrow;
    }
  }

  /// Stops the server and mDNS broadcast.
  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.close();
    _server = null;
    _baseUrl = null;
    _lanAccessToken = null;
    notifyListeners();
  }

  Handler get _handler {
    final pipeline = const Pipeline()
        .addMiddleware(_corsMiddleware)
        .addMiddleware(_rateLimitMiddleware)
        .addMiddleware(_authMiddleware)
        .addHandler(_router);
    return pipeline;
  }

  Future<Response> _router(Request request) async {
    final path = request.url.path;
    final method = request.method;

    if (method == 'GET' && path == 'health') {
      final package = await PackageInfo.fromPlatform();
      return _jsonResponse({
        'status': 'ok',
        'name': 'Erebrus AI',
        'version': package.version,
        'inference_ready': true,
        'loaded_model': InferenceService.instance.hasLoadedModel
            ? InferenceService.instance.activeModelId
            : null,
        'model_control': true,
      });
    }

    if (method == 'GET' && path == 'v1/models') {
      final ids = _servableModelIds;
      final byId = {for (final e in CatalogService.entries) e.id: e};
      final models = ids.map((id) {
        final imported = ImportedModelService.instance.byId(id);
        final catalog = byId[id];
        return {
          'id': id,
          'object': 'model',
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'owned_by': imported == null ? 'erebrus-ai' : 'local-user',
          'name': imported?.name ?? catalog?.name ?? id,
          'parameter_b': imported?.parameterB ?? catalog?.parameterB ?? 0,
          'architecture': imported?.architecture ?? catalog?.family ?? '',
          'format':
              imported?.format ?? catalog?.preferredVariant?.format ?? 'gguf',
          'quantization': imported?.quantization ?? catalog?.quant ?? '',
          'status': {'value': _modelState(id)},
          'loaded': _modelState(id) == 'loaded',
        };
      }).toList();
      return _jsonResponse({'object': 'list', 'data': models});
    }

    if (method == 'POST' &&
        (path == 'v1/models/load' || path == 'v1/models/unload')) {
      return _handleModelControl(request, load: path == 'v1/models/load');
    }

    if (method == 'POST' && path == 'v1/chat/completions') {
      return _handleChatCompletion(request);
    }

    return Response.notFound(json.encode({'error': 'Not found'}));
  }

  static String _modelState(String id) {
    final inference = InferenceService.instance;
    if (inference.activeModelId != id) return 'unloaded';
    if (inference.isLoading) return 'loading';
    return inference.hasLoadedModel ? 'loaded' : 'unloaded';
  }

  /// `POST /v1/models/load` and `/v1/models/unload` with `{"model": id}`,
  /// matching llama-server's router-mode contract so any client can manage
  /// which model this node keeps in memory.
  Future<Response> _handleModelControl(
    Request request, {
    required bool load,
  }) async {
    late final String body;
    try {
      body = await readBoundedLocalServerBody(request, maxBytes: 16 * 1024);
    } on LocalServerPayloadTooLarge {
      return _payloadTooLargeResponse();
    }
    Object? payload;
    try {
      payload = body.trim().isEmpty ? const {} : json.decode(body);
    } on FormatException {
      payload = null;
    }
    final modelId = payload is Map ? payload['model']?.toString() ?? '' : '';
    final inference = InferenceService.instance;
    if (inference.isGenerating) {
      return _jsonResponse({
        'error': {
          'message': 'This node is generating a response. Try again shortly.',
          'type': 'busy',
        },
      }, status: 409);
    }
    try {
      if (load) {
        if (!_servableModelIds.contains(modelId)) {
          return _jsonResponse({
            'error': {
              'message': 'Model $modelId is not available on this node.',
              'type': 'model_not_found',
            },
          }, status: 404);
        }
        await inference.load(modelId);
      } else if (modelId.isEmpty || inference.activeModelId == modelId) {
        await inference.unload();
      }
      return _jsonResponse({
        'success': true,
        'model': modelId,
        'status': {
          'value': modelId.isEmpty ? 'unloaded' : _modelState(modelId),
        },
      });
    } catch (e) {
      final msg = e is InferenceException ? e.message : e.toString();
      return _jsonResponse({
        'error': {'message': msg, 'type': 'inference_error'},
      }, status: 500);
    }
  }

  Future<Response> _handleChatCompletion(Request request) async {
    late final String body;
    try {
      body = await readBoundedLocalServerBody(request);
    } on LocalServerPayloadTooLarge {
      return _payloadTooLargeResponse();
    }
    final payload = json.decode(body) as Map<String, dynamic>? ?? {};
    final modelId = payload['model'] as String? ?? '';
    final stream = payload['stream'] as bool? ?? true;
    final systemPrompt = _lastMessage(payload, role: 'system');
    final maxOutputTokens = (payload['max_tokens'] as num?)?.toInt() ?? 768;
    final temperature = (payload['temperature'] as num?)?.toDouble() ?? 0.7;
    final topP = (payload['top_p'] as num?)?.toDouble() ?? 0.9;
    final repeatPenalty =
        (payload['repeat_penalty'] as num?)?.toDouble() ?? 1.1;
    final stop = switch (payload['stop']) {
      final String value => [value],
      final List values => values.map((value) => value.toString()).toList(),
      _ => const <String>[],
    };

    if (!ModelDownloadService.instance.isDownloaded(modelId) &&
        !ModelPackageService.instance.isModelRunnable(modelId) &&
        !ImportedModelService.instance.contains(modelId)) {
      return Response(
        503,
        body: json.encode({
          'error': {
            'message': 'Model $modelId is not downloaded on this node.',
            'type': 'model_not_loaded',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    if (stream) {
      final id = 'chatcmpl-${const Uuid().v4()}';
      final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final prompt = _lastMessage(payload, role: 'user');
      final events = _streamCompletion(
        modelId: modelId,
        prompt: prompt,
        systemPrompt: systemPrompt,
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        repeatPenalty: repeatPenalty,
        stop: stop,
        id: id,
        created: created,
      );

      return Response.ok(
        events,
        headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
        },
      );
    }

    try {
      final text = await InferenceService.instance
          .generate(
            modelId: modelId,
            prompt: _lastMessage(payload, role: 'user'),
            systemPrompt: systemPrompt,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            stop: stop,
          )
          .join();
      return _jsonResponse({
        'id': 'chatcmpl-${const Uuid().v4()}',
        'object': 'chat.completion',
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'model': modelId,
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 0,
          'completion_tokens': 0,
          'total_tokens': 0,
        },
      });
    } catch (e) {
      final msg = e is InferenceException ? e.message : e.toString();
      return _jsonResponse({
        'error': {'message': msg, 'type': 'inference_error'},
      }, status: 500);
    }
  }

  Stream<List<int>> _streamCompletion({
    required String modelId,
    required String prompt,
    required String systemPrompt,
    required int maxOutputTokens,
    required double temperature,
    required double topP,
    required double repeatPenalty,
    required List<String> stop,
    required String id,
    required int created,
  }) async* {
    // Send an immediate SSE comment ping so HTTP response headers (200 OK)
    // are flushed immediately to the client while the model loads.
    yield utf8.encode(': connected\n\n');

    try {
      await for (final token in InferenceService.instance.generate(
        modelId: modelId,
        prompt: prompt,
        systemPrompt: systemPrompt,
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        repeatPenalty: repeatPenalty,
        stop: stop,
      )) {
        yield utf8.encode(
          _sseData({
            'id': id,
            'object': 'chat.completion.chunk',
            'created': created,
            'model': modelId,
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': token},
                'finish_reason': null,
              },
            ],
          }),
        );
      }
      yield utf8.encode(
        _sseData({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': modelId,
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
        }),
      );
    } catch (e) {
      final msg = e is InferenceException ? e.message : e.toString();
      yield utf8.encode(
        _sseData({
          'error': {'message': msg, 'type': 'inference_error'},
        }),
      );
    }
    yield utf8.encode('data: [DONE]\n\n');
  }

  static String _lastMessage(
    Map<String, dynamic> payload, {
    required String role,
  }) {
    final messages = payload['messages'];
    if (messages is! List) return '';
    for (final raw in messages.reversed) {
      if (raw is Map && raw['role'] == role) {
        return raw['content']?.toString() ?? '';
      }
    }
    return '';
  }

  Future<void> _startBroadcast(int port) async {
    try {
      final identity = _identity ?? await loadMdnsNodeIdentity();
      final service = BonsoirService(
        name: identity.displayName,
        type: kErebrusAiMdnsType,
        port: port,
        attributes: {
          kMdnsNodeIdAttribute: identity.id,
          kMdnsProtocolAttribute: kMdnsProtocolVersion,
          kMdnsAccessTokenAttribute: ?_lanAccessToken,
          'models': '${_servableModelIds.length}',
        },
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.initialize();
      await _broadcast!.start();
    } catch (e) {
      debugPrint('[mDNS] broadcast failed: $e');
    }
  }

  Future<String> _guessUrl(int port) async {
    String host = '127.0.0.1';
    try {
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254')) {
            host = addr.address;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('[Server] could not guess LAN IP: $e');
    }
    return 'http://$host:$port';
  }

  static Response _jsonResponse(Object body, {int status = 200}) => Response(
    status,
    body: json.encode(body),
    headers: {'content-type': 'application/json'},
  );

  static String _sseData(Object data) => 'data: ${json.encode(data)}\n\n';

  static Middleware get _corsMiddleware =>
      (Handler inner) => (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok(null, headers: _corsHeaders(request));
        }
        final response = await inner(request);
        return response.change(headers: _corsHeaders(request));
      };

  static final Map<String, List<int>> _requestTimes = {};
  static const int _kMaxRequestsPerMinute = 60;
  static const int _kWindowMs = 60000;
  static Middleware get _rateLimitMiddleware =>
      (Handler inner) => (Request request) async {
        if (request.contentLength != null &&
            request.contentLength! > kMaxLocalServerPayloadBytes) {
          return _payloadTooLargeResponse();
        }

        final forwarded = request.headers['x-forwarded-for'];
        final clientKey = forwarded?.split(',').first.trim() ?? 'peer';
        final now = DateTime.now().millisecondsSinceEpoch;

        final times = _requestTimes.putIfAbsent(clientKey, () => []);
        times.removeWhere((t) => now - t > _kWindowMs);

        if (times.length >= _kMaxRequestsPerMinute) {
          return Response(
            429,
            body: json.encode({
              'error': {
                'message':
                    'Rate limit exceeded. Maximum $_kMaxRequestsPerMinute requests per minute.',
                'type': 'rate_limit_error',
              },
            }),
            headers: {'content-type': 'application/json', 'retry-after': '60'},
          );
        }

        times.add(now);
        return inner(request);
      };

  static Response _payloadTooLargeResponse() => Response(
    413,
    body: json.encode({
      'error': {
        'message': 'Payload too large (maximum 10MB)',
        'type': 'payload_too_large',
      },
    }),
    headers: {'content-type': 'application/json'},
  );

  static Middleware get _authMiddleware =>
      (Handler inner) => (Request request) async {
        if (isPublicLocalServerMetadataRequest(
          request.method,
          request.url.path,
        )) {
          return inner(request);
        }
        final auth = request.headers['authorization'] ?? '';
        final token = auth.startsWith('Bearer ')
            ? auth.substring(7).trim()
            : '';
        final apiKey = _instance._apiKey ?? '';
        final lanAccessToken = _instance._lanAccessToken;
        if ((apiKey.isEmpty && lanAccessToken == null) ||
            (token != apiKey && token != lanAccessToken)) {
          return Response.unauthorized(
            json.encode({
              'error': {
                'message': 'Invalid API key',
                'type': 'authentication_error',
              },
            }),
          );
        }
        return inner(request);
      };

  static Map<String, String> _corsHeaders(Request request) => {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
  };
}
