import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'local_server_service.dart';
import 'mdns_config.dart';

/// Discovers Erebrus AI nodes advertising `_erebrusai._tcp` on the LAN.
class NodeDiscoveryService extends ChangeNotifier {
  NodeDiscoveryService._();
  static final NodeDiscoveryService _instance = NodeDiscoveryService._();
  static NodeDiscoveryService get instance => _instance;

  final List<DiscoveredNode> _nodes = [];
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  bool _running = false;
  String? _localNodeId;
  Set<String> _localAddresses = const {};
  String? _lastError;

  List<DiscoveredNode> get nodes => List.unmodifiable(_nodes);
  bool get isRunning => _running;
  String? get lastError => _lastError;

  DiscoveredNode? nodeById(String nodeId) =>
      _nodes.where((node) => node.id == nodeId).firstOrNull;

  NetworkModelTarget? targetFor(String nodeId, String modelId) {
    final node = nodeById(nodeId);
    if (node == null) return null;
    final model = node.models
        .where((candidate) => candidate.id == modelId)
        .firstOrNull;
    return model == null ? null : node.targetFor(model);
  }

  bool get _inTest => Platform.environment.containsKey('FLUTTER_TEST');

  /// Starts continuous mDNS discovery.
  Future<void> start() async {
    if (_running || kIsWeb || _inTest) return;
    _running = true;
    _lastError = null;
    notifyListeners();

    try {
      final identity = await loadMdnsNodeIdentity();
      _localNodeId = identity.id;
      _localAddresses = await _readLocalAddresses();
      _discovery = BonsoirDiscovery(type: kErebrusAiMdnsType);
      await _discovery!.initialize();
      _subscription = _discovery!.eventStream?.listen(
        _onEvent,
        onError: _onDiscoveryError,
      );
      await _discovery!.start();
    } on Object catch (error) {
      debugPrint('[Discovery] start failed: $error');
      await _disposeDiscovery();
      _running = false;
      _lastError = _friendlyDiscoveryError(error);
      notifyListeners();
    }
  }

  /// Stops discovery and clears the node list.
  Future<void> stop() async {
    await _disposeDiscovery();
    _nodes.clear();
    _running = false;
    _lastError = null;
    notifyListeners();
  }

  Future<void> _disposeDiscovery() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _discovery?.stop();
    } on Object catch (error) {
      debugPrint('[Discovery] stop failed: $error');
    }
    _discovery = null;
  }

  void _onDiscoveryError(Object error, StackTrace stackTrace) {
    debugPrint('[Discovery] stream failed: $error');
    unawaited(_handleDiscoveryFailure(error));
  }

  Future<void> _handleDiscoveryFailure(Object error) async {
    await _disposeDiscovery();
    _running = false;
    _lastError = _friendlyDiscoveryError(error);
    notifyListeners();
  }

  void _onEvent(BonsoirDiscoveryEvent event) async {
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      try {
        await _discovery?.serviceResolver.resolveService(event.service);
      } on Object catch (error) {
        debugPrint('[Discovery] resolve failed: $error');
      }
    } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
      _addOrUpdate(event.service);
    } else if (event is BonsoirDiscoveryServiceLostEvent) {
      _remove(event.service);
    }
  }

  void _addOrUpdate(BonsoirService service) {
    final nodeId = service.attributes[kMdnsNodeIdAttribute]?.trim() ?? '';

    final host =
        preferredMdnsHost(service.hostAddresses) ??
        service.hostname?.replaceFirst(RegExp(r'\.$'), '');
    if (host == null || host.isEmpty) {
      debugPrint('[Discovery] resolved ${service.name} without a usable host');
      return;
    }
    if (isOwnMdnsService(
      advertisedNodeId: nodeId,
      localNodeId: _localNodeId ?? '',
      host: host,
      advertisedPort: service.port,
      localPort: LocalServerService.instance.port,
      localServerRunning: LocalServerService.instance.isRunning,
      localAddresses: _localAddresses,
    )) {
      return;
    }
    final node = DiscoveredNode(
      id: nodeId.isEmpty ? '${service.name}@$host:${service.port}' : nodeId,
      name: service.name,
      host: host,
      port: service.port,
      accessToken: service.attributes[kMdnsAccessTokenAttribute]?.trim() ?? '',
      isLoadingModels: true,
    );
    _nodes.removeWhere((candidate) => candidate.id == node.id);
    _nodes.add(node);
    notifyListeners();
    unawaited(_loadModels(node));
  }

  Future<void> _loadModels(DiscoveredNode node) async {
    var models = const <DiscoveredNodeModel>[];
    String? failure;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      try {
        final request = await client.getUrl(node.modelListUri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (node.accessToken.isNotEmpty) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${node.accessToken}',
          );
        }
        final response = await request.close();
        if (response.statusCode == HttpStatus.ok) {
          final payload = jsonDecode(
            await response.transform(utf8.decoder).join(),
          );
          final data = payload is Map ? payload['data'] : null;
          if (data is List) {
            models = data
                .whereType<Map>()
                .map(
                  (item) => DiscoveredNodeModel(
                    id: (item['id'] ?? '').toString(),
                    name: (item['name'] ?? item['id'] ?? '').toString(),
                    parameterB: (item['parameter_b'] as num?)?.toDouble() ?? 0,
                    architecture: (item['architecture'] ?? '').toString(),
                    format: (item['format'] ?? '').toString(),
                    quantization: (item['quantization'] ?? '').toString(),
                  ),
                )
                .where((model) => model.id.isNotEmpty)
                .toList();
          }
        } else {
          failure = 'Model list returned HTTP ${response.statusCode}';
        }
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      debugPrint('[Discovery] model listing failed for ${node.url}: $error');
      failure = 'Node found, but its model list is unreachable';
    }

    final index = _nodes.indexWhere((item) => item.id == node.id);
    if (index < 0) return;
    _nodes[index] = node.copyWith(
      models: models,
      isLoadingModels: false,
      error: failure,
    );
    notifyListeners();
  }

  void _remove(BonsoirService service) {
    final nodeId = service.attributes[kMdnsNodeIdAttribute]?.trim() ?? '';
    _nodes.removeWhere(
      (node) =>
          nodeId.isNotEmpty ? node.id == nodeId : node.name == service.name,
    );
    notifyListeners();
  }

  Future<Set<String>> _readLocalAddresses() async {
    final addresses = <String>{'127.0.0.1', '::1'};
    try {
      for (final interface in await NetworkInterface.list(
        includeLoopback: true,
      )) {
        addresses.addAll(interface.addresses.map((address) => address.address));
      }
    } on Object catch (error) {
      debugPrint('[Discovery] local address lookup failed: $error');
    }
    return addresses;
  }

  String _friendlyDiscoveryError(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('defunctconnection') || lower.contains('-65569')) {
      return 'Bonjour restarted its network connection. Tap Rescan to try again.';
    }
    if (lower.contains('denied') ||
        lower.contains('policy') ||
        lower.contains('-65570')) {
      return 'Local network access is disabled. Enable it in system settings, then rescan.';
    }
    return 'Local network discovery failed. Check Wi-Fi access and tap Rescan.';
  }
}

/// A node discovered on the local network.
class DiscoveredNode {
  const DiscoveredNode({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.accessToken = '',
    this.models = const [],
    this.isLoadingModels = false,
    this.error,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String accessToken;
  final List<DiscoveredNodeModel> models;
  final bool isLoadingModels;
  final String? error;

  String get url => Uri(scheme: 'http', host: host, port: port).toString();

  Uri get modelListUri => Uri(
    scheme: 'http',
    host: host,
    port: port,
    pathSegments: const ['v1', 'models'],
  );

  Uri get chatCompletionsUri => Uri(
    scheme: 'http',
    host: host,
    port: port,
    pathSegments: const ['v1', 'chat', 'completions'],
  );

  NetworkModelTarget targetFor(DiscoveredNodeModel model) => NetworkModelTarget(
    nodeId: id,
    nodeName: name,
    host: host,
    port: port,
    accessToken: accessToken,
    modelId: model.id,
    modelName: model.name,
  );

  DiscoveredNode copyWith({
    List<DiscoveredNodeModel>? models,
    bool? isLoadingModels,
    String? error,
  }) => DiscoveredNode(
    id: id,
    name: name,
    host: host,
    port: port,
    accessToken: accessToken,
    models: models ?? this.models,
    isLoadingModels: isLoadingModels ?? this.isLoadingModels,
    error: error,
  );

  @override
  String toString() => '$name @ $host:$port';
}

/// Everything needed to address one model on a discovered Erebrus peer or a
/// user-configured connection.
class NetworkModelTarget {
  const NetworkModelTarget({
    required this.nodeId,
    required this.nodeName,
    required this.host,
    required this.port,
    required this.accessToken,
    required this.modelId,
    required this.modelName,
    this.apiBase,
    this.requiresAccessToken = true,
    this.extraHeaders = const {},
    this.maxTokensLimit,
    this.acceptsLlamaSampling = true,
    this.isConnection = false,
  });

  final String nodeId;
  final String nodeName;
  final String host;
  final int port;
  final String accessToken;
  final String modelId;
  final String modelName;

  /// OpenAI base such as `https://api.openai.com/v1`. Discovered nodes leave
  /// this null and are addressed as `http://host:port/v1`.
  final Uri? apiBase;
  final bool requiresAccessToken;
  final Map<String, String> extraHeaders;
  final int? maxTokensLimit;
  final bool acceptsLlamaSampling;
  final bool isConnection;

  String get selectionKey => '$nodeId::$modelId';

  Uri get chatCompletionsUri {
    final base = apiBase;
    if (base == null) {
      return Uri(
        scheme: 'http',
        host: host,
        port: port,
        pathSegments: const ['v1', 'chat', 'completions'],
      );
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'chat',
        'completions',
      ],
    );
  }
}

class DiscoveredNodeModel {
  const DiscoveredNodeModel({
    required this.id,
    required this.name,
    this.parameterB = 0,
    this.architecture = '',
    this.format = '',
    this.quantization = '',
  });

  final String id;
  final String name;
  final double parameterB;
  final String architecture;
  final String format;
  final String quantization;

  String get spec => [
    if (parameterB > 0)
      parameterB < 1
          ? '${(parameterB * 1000).round()}M'
          : '${parameterB.toStringAsFixed(parameterB % 1 == 0 ? 0 : 1)}B',
    if (quantization.isNotEmpty) quantization,
    if (format.isNotEmpty) format.toUpperCase(),
    if (architecture.isNotEmpty) architecture,
  ].join(' · ');
}
