import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/model_connection.dart';
import '../platform/secure_storage.dart';
import 'node_discovery_service.dart';

class ConnectionException implements Exception {
  const ConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// User-configured model servers (Settings → Connections).
///
/// Metadata is kept in shared preferences; API keys only in secure storage.
/// Model lists and memory state are fetched live from each server, and
/// providers that support it can load or offload models remotely.
class ConnectionService extends ChangeNotifier {
  ConnectionService({http.Client? client}) : _client = client ?? http.Client();

  static final ConnectionService instance = ConnectionService();

  static const _storageKey = 'model_connections_v1';
  static String _apiKeyStorageKey(String id) => 'connection_api_key_$id';
  static const _timeout = Duration(seconds: 8);
  static const _loadTimeout = Duration(minutes: 5);
  static const _settlePollInterval = Duration(milliseconds: 750);

  final http.Client _client;
  final List<ModelConnection> _connections = [];
  final Map<String, String> _apiKeys = {};
  final Map<String, Map<String, RemoteModelInfo>> _models = {};
  final Map<String, String> _errors = {};
  final Set<String> _refreshing = {};
  final Map<String, Future<void>> _inFlightRefresh = {};
  final Set<String> _busyModels = {};

  /// Whether each llama.cpp connection runs in router mode (null: unknown).
  final Map<String, bool> _llamaRouter = {};
  bool _loaded = false;

  List<ModelConnection> get connections => List.unmodifiable(_connections);
  List<ModelConnection> get enabledConnections =>
      _connections.where((connection) => connection.enabled).toList();
  bool get isLoaded => _loaded;

  ModelConnection? byId(String id) =>
      _connections.where((connection) => connection.id == id).firstOrNull;

  ModelConnection? byNodeId(String nodeId) =>
      nodeId.startsWith(ModelConnection.nodeIdPrefix)
      ? byId(nodeId.substring(ModelConnection.nodeIdPrefix.length))
      : null;

  bool hasApiKey(String id) => (_apiKeys[id] ?? '').isNotEmpty;

  /// Whether Load/Offload can work for this connection right now. A
  /// llama.cpp server outside router mode keeps its single model loaded.
  bool supportsModelControl(ModelConnection connection) =>
      connection.provider.supportsModelControl &&
      _llamaRouter[connection.id] != false;
  String? errorFor(String id) => _errors[id];
  bool isRefreshing(String id) => _refreshing.contains(id);
  bool isModelBusy(String id, String modelId) =>
      _busyModels.contains('$id::$modelId');

  /// Live info for the connection's selected models (in the user's order).
  List<RemoteModelInfo> modelsFor(ModelConnection connection) => [
    for (final modelId in connection.modelIds)
      _models[connection.id]?[modelId] ??
          RemoteModelInfo(
            id: modelId,
            state: supportsModelControl(connection)
                ? RemoteModelState.unknown
                : RemoteModelState.available,
          ),
  ];

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      _connections
        ..clear()
        ..addAll(
          raw == null
              ? const []
              : (jsonDecode(raw) as List).whereType<Map>().map(
                  (item) =>
                      ModelConnection.fromJson(item.cast<String, dynamic>()),
                ),
        );
      for (final connection in _connections) {
        try {
          final key = await ErebrusSecureStorage.instance.read(
            key: _apiKeyStorageKey(connection.id),
          );
          if (key != null && key.isNotEmpty) _apiKeys[connection.id] = key;
        } on Object catch (error) {
          debugPrint('[Connections] key read failed: $error');
        }
      }
    } on Object catch (error) {
      debugPrint('[Connections] load failed: $error');
    } finally {
      _loaded = true;
      notifyListeners();
    }
    for (final connection in enabledConnections) {
      unawaited(refresh(connection));
    }
  }

  Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _storageKey,
      jsonEncode(
        _connections.map((connection) => connection.toJson()).toList(),
      ),
    );
  }

  /// Creates or replaces a connection. Pass [apiKey] as null to keep the
  /// stored key, or an empty string to remove it.
  Future<ModelConnection> save({
    String? id,
    required ConnectionProvider provider,
    required String name,
    required String baseUrl,
    int? maxTokensLimit,
    required List<String> modelIds,
    String? apiKey,
  }) async {
    final normalizedUrl = normalizeBaseUrl(baseUrl);
    final existing = id == null ? null : byId(id);
    final connection = existing == null
        ? ModelConnection(
            id: const Uuid().v4(),
            provider: provider,
            name: name.trim().isEmpty ? provider.label : name.trim(),
            baseUrl: normalizedUrl,
            maxTokensLimit: maxTokensLimit,
            modelIds: _dedupe(modelIds),
            createdAt: DateTime.now(),
          )
        : existing.copyWith(
            provider: provider,
            name: name.trim().isEmpty ? provider.label : name.trim(),
            baseUrl: normalizedUrl,
            maxTokensLimit: () => maxTokensLimit,
            modelIds: _dedupe(modelIds),
          );
    final index = _connections.indexWhere((item) => item.id == connection.id);
    if (index >= 0) {
      _connections[index] = connection;
    } else {
      _connections.add(connection);
    }
    if (apiKey != null) await _writeApiKey(connection.id, apiKey.trim());
    notifyListeners();
    await _persist();
    unawaited(refresh(connection));
    return connection;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = _connections.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _connections[index] = _connections[index].copyWith(enabled: enabled);
    notifyListeners();
    await _persist();
    if (enabled) unawaited(refresh(_connections[index]));
  }

  Future<void> remove(String id) async {
    _connections.removeWhere((connection) => connection.id == id);
    _models.remove(id);
    _errors.remove(id);
    _llamaRouter.remove(id);
    await _writeApiKey(id, '');
    notifyListeners();
    await _persist();
  }

  Future<void> _writeApiKey(String id, String value) async {
    if (value.isEmpty) {
      _apiKeys.remove(id);
      try {
        await ErebrusSecureStorage.instance.delete(key: _apiKeyStorageKey(id));
      } on Object catch (error) {
        debugPrint('[Connections] key delete failed: $error');
      }
      return;
    }
    _apiKeys[id] = value;
    await ErebrusSecureStorage.instance.write(
      key: _apiKeyStorageKey(id),
      value: value,
    );
  }

  static String normalizeBaseUrl(String value) {
    var url = value.trim();
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'http://$url';
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  static List<String> _dedupe(List<String> ids) {
    final seen = <String>{};
    return [
      for (final id in ids.map((value) => value.trim()))
        if (id.isNotEmpty && seen.add(id)) id,
    ];
  }

  /// Parses a manual model list (one per line or comma-separated).
  static List<String> parseModelIds(String text) =>
      _dedupe(text.split(RegExp(r'[\n,]')));

  // ─── Chat targets ─────────────────────────────────────────────────────────

  NetworkModelTarget? targetFor(String nodeId, String modelId) {
    final connection = byNodeId(nodeId);
    if (connection == null || !connection.enabled) return null;
    if (!connection.modelIds.contains(modelId)) return null;
    final base = connection.apiBase;
    return NetworkModelTarget(
      nodeId: connection.nodeId,
      nodeName: connection.name,
      host: base.host,
      port: base.hasPort ? base.port : (base.scheme == 'https' ? 443 : 80),
      accessToken: _apiKeys[connection.id] ?? '',
      modelId: modelId,
      modelName: modelId,
      apiBase: base,
      requiresAccessToken: connection.provider.requiresApiKey,
      extraHeaders: _providerHeaders(connection.provider),
      maxTokensLimit: connection.maxTokensLimit,
      acceptsLlamaSampling: connection.provider.acceptsLlamaSampling,
      isConnection: true,
    );
  }

  static Map<String, String> _providerHeaders(ConnectionProvider provider) =>
      switch (provider) {
        ConnectionProvider.openRouter => const {
          'HTTP-Referer': 'https://erebrus.io',
          'X-Title': 'Erebrus AI',
        },
        _ => const {},
      };

  Map<String, String> _headers(
    ConnectionProvider provider,
    String apiKey, {
    bool json = false,
  }) => {
    'accept': 'application/json',
    if (json) 'content-type': 'application/json',
    if (apiKey.isNotEmpty)
      ...switch (provider) {
        ConnectionProvider.anthropic => {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        _ => {'authorization': 'Bearer $apiKey'},
      },
    ..._providerHeaders(provider),
  };

  // ─── Model discovery ──────────────────────────────────────────────────────

  /// Lists every model the server offers. Used by the connection form before
  /// the connection is saved, so it takes raw settings rather than an id.
  Future<List<RemoteModelInfo>> fetchAvailableModels({
    required ConnectionProvider provider,
    required String baseUrl,
    String apiKey = '',
  }) async {
    final probe = ModelConnection(
      id: 'probe',
      provider: provider,
      name: provider.label,
      baseUrl: normalizeBaseUrl(baseUrl),
      createdAt: DateTime.now(),
    );
    if (probe.baseUrl.isEmpty) {
      throw const ConnectionException('Enter the server base URL first.');
    }
    return _listModels(probe, apiKey);
  }

  /// Refreshes live model state for a saved connection.
  Future<void> refresh(ModelConnection connection) {
    // Join a refresh that is already running rather than returning early:
    // callers await this to read fresh state.
    // The callback must not return the removed future: whenComplete would
    // then wait on the very future it is completing.
    return _inFlightRefresh[connection.id] ??= _refresh(
      connection,
    ).whenComplete(() {
      _inFlightRefresh.remove(connection.id);
    });
  }

  Future<void> _refresh(ModelConnection connection) async {
    _refreshing.add(connection.id);
    notifyListeners();
    try {
      final models = await _listModels(
        connection,
        _apiKeys[connection.id] ?? '',
      );
      _models[connection.id] = {for (final model in models) model.id: model};
      _errors.remove(connection.id);
    } on Object catch (error) {
      _errors[connection.id] = _friendly(error, connection);
    } finally {
      _refreshing.remove(connection.id);
      notifyListeners();
    }
  }

  Future<void> refreshAll() => Future.wait(enabledConnections.map(refresh));

  Future<List<RemoteModelInfo>> _listModels(
    ModelConnection connection,
    String apiKey,
  ) async {
    final provider = connection.provider;
    switch (provider.control) {
      case ModelControl.ollama:
        return _listOllama(connection, apiKey);
      case ModelControl.lmStudio:
        try {
          return await _listLmStudio(connection, apiKey);
        } on Object {
          return _listOpenAi(connection, apiKey);
        }
      case ModelControl.llamaServerRouter:
        // `/props` reports `"role": "router"` when llama-server manages
        // several models (--models-dir / --models-preset). Only then can
        // models be loaded and offloaded; a single-model server always has
        // its one model loaded.
        final router = await _isLlamaRouter(connection, apiKey);
        _llamaRouter[connection.id] = router;
        return _listOpenAi(
          connection,
          apiKey,
          defaultState: router
              ? RemoteModelState.unknown
              : RemoteModelState.loaded,
        );
      case ModelControl.erebrus:
        return _listOpenAi(
          connection,
          apiKey,
          defaultState: RemoteModelState.unknown,
        );
      case ModelControl.none:
        return _listOpenAi(connection, apiKey);
    }
  }

  Future<List<RemoteModelInfo>> _listOpenAi(
    ModelConnection connection,
    String apiKey, {
    Uri? uri,
    RemoteModelState defaultState = RemoteModelState.available,
  }) async {
    final payload = await _getJson(
      uri ?? _join(connection.apiBase, ['models']),
      _headers(connection.provider, apiKey),
    );
    final data = payload is Map ? payload['data'] ?? payload['models'] : null;
    if (data is! List) {
      throw const ConnectionException(
        'The server responded, but not with an OpenAI-compatible model list.',
      );
    }
    return [
      for (final item in data.whereType<Map>())
        if ((item['id'] ?? item['name'] ?? '').toString().isNotEmpty)
          RemoteModelInfo(
            id: (item['id'] ?? item['name']).toString(),
            state: item.containsKey('status')
                ? RemoteModelState.parse(item['status'])
                : item['loaded'] is bool
                ? (item['loaded'] as bool
                      ? RemoteModelState.loaded
                      : RemoteModelState.unloaded)
                : defaultState,
            detail: [
              if ((item['quantization'] ?? '').toString().isNotEmpty)
                item['quantization'].toString(),
              if ((item['owned_by'] ?? '').toString().isNotEmpty &&
                  connection.provider.control == ModelControl.none)
                item['owned_by'].toString(),
            ].join(' · '),
          ),
    ]..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
  }

  Future<List<RemoteModelInfo>> _listOllama(
    ModelConnection connection,
    String apiKey,
  ) async {
    final headers = _headers(connection.provider, apiKey);
    final tags = await _getJson(
      _join(connection.serverRoot, ['api', 'tags']),
      headers,
    );
    final running = <String>{};
    try {
      final ps = await _getJson(
        _join(connection.serverRoot, ['api', 'ps']),
        headers,
      );
      for (final item in (ps is Map ? ps['models'] : null) as List? ?? []) {
        if (item is Map) {
          running.add((item['model'] ?? item['name'] ?? '').toString());
        }
      }
    } on Object catch (error) {
      debugPrint('[Connections] ollama ps failed: $error');
    }
    final models = (tags is Map ? tags['models'] : null) as List? ?? [];
    return [
      for (final item in models.whereType<Map>())
        RemoteModelInfo(
          id: (item['model'] ?? item['name']).toString(),
          state: running.contains((item['model'] ?? item['name']).toString())
              ? RemoteModelState.loaded
              : RemoteModelState.unloaded,
          sizeBytes: (item['size'] as num?)?.toInt(),
          detail: [
            if (item['details'] is Map) ...[
              ((item['details'] as Map)['parameter_size'] ?? '').toString(),
              ((item['details'] as Map)['quantization_level'] ?? '').toString(),
            ],
          ].where((value) => value.isNotEmpty).join(' · '),
        ),
    ]..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
  }

  Future<List<RemoteModelInfo>> _listLmStudio(
    ModelConnection connection,
    String apiKey,
  ) async {
    final payload = await _getJson(
      _join(connection.serverRoot, ['api', 'v0', 'models']),
      _headers(connection.provider, apiKey),
    );
    final data = (payload is Map ? payload['data'] : null) as List? ?? [];
    return [
      for (final item in data.whereType<Map>())
        if (item['type'] != 'embeddings')
          RemoteModelInfo(
            id: item['id'].toString(),
            state: RemoteModelState.parse(item['state']),
            detail: [
              (item['quantization'] ?? '').toString(),
              (item['arch'] ?? '').toString(),
            ].where((value) => value.isNotEmpty).join(' · '),
          ),
    ]..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
  }

  Future<bool> _isLlamaRouter(ModelConnection connection, String apiKey) async {
    try {
      final props = await _getJson(
        _join(connection.serverRoot, ['props']),
        _headers(connection.provider, apiKey),
      );
      return props is Map && props['role'] == 'router';
    } on Object {
      return false;
    }
  }

  // ─── Load / offload ───────────────────────────────────────────────────────

  Future<void> loadModel(ModelConnection connection, String modelId) =>
      _control(connection, modelId, load: true);

  Future<void> unloadModel(ModelConnection connection, String modelId) =>
      _control(connection, modelId, load: false);

  Future<void> _control(
    ModelConnection connection,
    String modelId, {
    required bool load,
  }) async {
    final busyKey = '${connection.id}::$modelId';
    if (!_busyModels.add(busyKey)) return;
    final modelMap = _models.putIfAbsent(connection.id, () => {});
    final previous = modelMap[modelId];
    modelMap[modelId] = RemoteModelInfo(
      id: modelId,
      state: load ? RemoteModelState.loading : RemoteModelState.unloaded,
      sizeBytes: previous?.sizeBytes,
      detail: previous?.detail ?? '',
    );
    notifyListeners();
    final apiKey = _apiKeys[connection.id] ?? '';
    final headers = _headers(connection.provider, apiKey, json: true);
    try {
      switch (connection.provider.control) {
        case ModelControl.none:
          throw ConnectionException(
            '${connection.provider.label} manages model memory itself.',
          );
        case ModelControl.erebrus:
          await _postJson(
            _join(connection.apiBase, ['models', load ? 'load' : 'unload']),
            headers,
            {'model': modelId},
            load: load,
          );
        case ModelControl.llamaServerRouter:
          final router =
              _llamaRouter[connection.id] ??
              await _isLlamaRouter(connection, apiKey);
          if (!router) {
            throw const ConnectionException(
              'This llama-server is not in router mode, so it serves a single '
              'always-loaded model. Start it with --models-dir (or '
              '--models-preset) to load and offload models remotely.',
            );
          }
          try {
            await _postJson(
              _join(connection.serverRoot, [
                'models',
                load ? 'load' : 'unload',
              ]),
              headers,
              {'model': modelId},
              load: load,
              notFoundHint: load
                  ? 'The server has no model named “$modelId” in its models folder.'
                  : null,
            );
          } on ConnectionException catch (e) {
            // The router answers 400 "model is already running" / "model is
            // not running" when the model is already in the requested state.
            final message = e.message.toLowerCase();
            final alreadyThere = load
                ? message.contains('already running')
                : message.contains('not running');
            if (!alreadyThere) rethrow;
          }
        case ModelControl.ollama:
          await _postJson(
            _join(connection.serverRoot, ['api', 'generate']),
            headers,
            {'model': modelId, 'stream': false, 'keep_alive': load ? -1 : 0},
            load: load,
          );
        case ModelControl.lmStudio:
          await _postJson(
            _join(connection.serverRoot, [
              'api',
              'v1',
              'models',
              load ? 'load' : 'unload',
            ]),
            headers,
            load ? {'model': modelId} : {'instance_id': modelId},
            load: load,
            notFoundHint:
                'This LM Studio version has no model-management API. Update '
                'LM Studio, or use `lms load` on that machine.',
          );
      }
      _errors.remove(connection.id);
    } on Object catch (error) {
      modelMap[modelId] =
          previous ??
          RemoteModelInfo(id: modelId, state: RemoteModelState.unknown);
      _errors[connection.id] = _friendly(error, connection);
      rethrow;
    } finally {
      _busyModels.remove(busyKey);
      notifyListeners();
    }
    await _settle(connection, modelId, load: load);
  }

  /// Some servers (llama-server's router) return from load/unload at once and
  /// finish in the background, reporting `loading` meanwhile. Poll until the
  /// model reaches the requested state so the UI never sticks on LOADING.
  Future<void> _settle(
    ModelConnection connection,
    String modelId, {
    required bool load,
  }) async {
    final deadline = DateTime.now().add(_loadTimeout);
    final busyKey = '${connection.id}::$modelId';
    _busyModels.add(busyKey);
    try {
      while (true) {
        await refresh(connection);
        final state = _models[connection.id]?[modelId]?.state;
        final settled = load
            ? state != RemoteModelState.loading &&
                  state != RemoteModelState.unloaded
            : state != RemoteModelState.loading &&
                  state != RemoteModelState.loaded;
        if (settled || _errors.containsKey(connection.id)) break;
        if (DateTime.now().isAfter(deadline)) {
          _errors[connection.id] =
              '${load ? 'Loading' : 'Offloading'} $modelId is taking longer than expected. Check the server log.';
          break;
        }
        await Future<void>.delayed(_settlePollInterval);
      }
      if (load &&
          _models[connection.id]?[modelId]?.state == RemoteModelState.failed) {
        _errors[connection.id] =
            'The server could not load $modelId. Check that it fits in memory and see the server log.';
      }
    } finally {
      _busyModels.remove(busyKey);
      notifyListeners();
    }
  }

  // ─── HTTP helpers ─────────────────────────────────────────────────────────

  static Uri _join(Uri base, List<String> segments) => base.replace(
    pathSegments: [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      ...segments,
    ],
  );

  Future<Object?> _getJson(Uri uri, Map<String, String> headers) async {
    final response = await _client.get(uri, headers: headers).timeout(_timeout);
    return _decode(response);
  }

  Future<Object?> _postJson(
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?> body, {
    required bool load,
    String? notFoundHint,
  }) async {
    final response = await _client
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(load ? _loadTimeout : _timeout);
    if ((response.statusCode == 404 || response.statusCode == 405) &&
        notFoundHint != null) {
      throw ConnectionException(notFoundHint);
    }
    return _decode(response);
  }

  static Object? _decode(http.Response response) {
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final message = switch (decoded) {
      {'error': final Map error} => error['message']?.toString(),
      {'error': final String error} => error,
      {'message': final String message} => message,
      _ => null,
    };
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ConnectionException(
        message ??
            'The server rejected the API key (HTTP ${response.statusCode}).',
      );
    }
    throw ConnectionException(
      message ?? 'The server returned HTTP ${response.statusCode}.',
    );
  }

  static String _friendly(Object error, ModelConnection connection) {
    if (error is ConnectionException) return error.message;
    if (error is TimeoutException) {
      return 'No response from ${connection.hostLabel}. Is the server running?';
    }
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('ClientException')) {
      return 'Could not reach ${connection.hostLabel}. Check the address and that the server is running.';
    }
    return text;
  }
}

/// Resolves a chat selection (`networkNodeId` + model id) to a request target,
/// whether it names a user connection or an mDNS-discovered Erebrus node.
NetworkModelTarget? resolveNetworkTarget(String nodeId, String modelId) =>
    nodeId.startsWith(ModelConnection.nodeIdPrefix)
    ? ConnectionService.instance.targetFor(nodeId, modelId)
    : NodeDiscoveryService.instance.targetFor(nodeId, modelId);

/// Human-readable name for a chat's network source.
String? networkSourceName(String nodeId) =>
    nodeId.startsWith(ModelConnection.nodeIdPrefix)
    ? ConnectionService.instance.byNodeId(nodeId)?.name
    : NodeDiscoveryService.instance.nodeById(nodeId)?.name;
