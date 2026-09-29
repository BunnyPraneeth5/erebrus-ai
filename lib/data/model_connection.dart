/// How a provider lets clients move models in and out of memory.
enum ModelControl {
  /// No remote load/offload (cloud APIs, vLLM, plain OpenAI-compatible).
  none,

  /// llama-server router mode: `POST /models/load` and `/models/unload`.
  llamaServerRouter,

  /// Erebrus AI node: `POST /v1/models/load` and `/v1/models/unload`.
  erebrus,

  /// Ollama: `/api/ps` for status, `/api/generate` with `keep_alive`.
  ollama,

  /// LM Studio REST API: `/api/v0/models` and `/api/v1/models/load`.
  lmStudio,
}

/// A server type the user can connect to. Every provider speaks the OpenAI
/// chat-completions protocol; they differ in defaults, auth and model control.
enum ConnectionProvider {
  erebrus(
    label: 'Erebrus AI node',
    defaultBaseUrl: 'http://192.168.1.10:11434/v1',
    control: ModelControl.erebrus,
    apiKeyHint: 'Node API key from its Settings → Local server',
    isLocal: true,
  ),
  llamaCpp(
    label: 'llama.cpp',
    defaultBaseUrl: 'http://localhost:8080/v1',
    control: ModelControl.llamaServerRouter,
    isLocal: true,
  ),
  ollama(
    label: 'Ollama',
    defaultBaseUrl: 'http://localhost:11434/v1',
    control: ModelControl.ollama,
    isLocal: true,
  ),
  lmStudio(
    label: 'LM Studio',
    defaultBaseUrl: 'http://localhost:1234/v1',
    control: ModelControl.lmStudio,
    isLocal: true,
  ),
  vllm(
    label: 'vLLM',
    defaultBaseUrl: 'http://localhost:8000/v1',
    control: ModelControl.none,
    isLocal: true,
  ),
  openAi(
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    control: ModelControl.none,
    requiresApiKey: true,
  ),
  anthropic(
    label: 'Anthropic',
    defaultBaseUrl: 'https://api.anthropic.com/v1',
    control: ModelControl.none,
    requiresApiKey: true,
  ),
  openRouter(
    label: 'OpenRouter',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    control: ModelControl.none,
    requiresApiKey: true,
  ),
  custom(
    label: 'Custom (OpenAI-compatible)',
    defaultBaseUrl: 'http://localhost:8000/v1',
    control: ModelControl.none,
    isLocal: true,
  );

  const ConnectionProvider({
    required this.label,
    required this.defaultBaseUrl,
    required this.control,
    this.requiresApiKey = false,
    this.isLocal = false,
    this.apiKeyHint,
  });

  final String label;
  final String defaultBaseUrl;
  final ModelControl control;
  final bool requiresApiKey;
  final bool isLocal;
  final String? apiKeyHint;

  bool get supportsModelControl => control != ModelControl.none;

  /// Local runtimes accept llama.cpp sampling extensions such as
  /// `repeat_penalty`; hosted APIs reject unknown request fields.
  bool get acceptsLlamaSampling => isLocal && this != ConnectionProvider.vllm;

  static ConnectionProvider byName(String? name) =>
      values.where((value) => value.name == name).firstOrNull ??
      ConnectionProvider.custom;
}

/// A user-configured model server. The API key lives in secure storage and
/// is never serialized with this record.
class ModelConnection {
  const ModelConnection({
    required this.id,
    required this.provider,
    required this.name,
    required this.baseUrl,
    this.maxTokensLimit,
    this.modelIds = const [],
    this.enabled = true,
    required this.createdAt,
  });

  /// Chat sessions and selections reference connection models through
  /// `networkNodeId`, prefixed so they never collide with mDNS node ids.
  static const nodeIdPrefix = 'conn:';

  final String id;
  final ConnectionProvider provider;
  final String name;
  final String baseUrl;
  final int? maxTokensLimit;
  final List<String> modelIds;
  final bool enabled;
  final DateTime createdAt;

  String get nodeId => '$nodeIdPrefix$id';

  /// Normalized OpenAI base, e.g. `http://host:8080/v1` (no trailing slash).
  Uri get apiBase {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse(trimmed);
  }

  /// Server root without a trailing `/v1`, where native management APIs live.
  Uri get serverRoot {
    final base = apiBase;
    final segments = [...base.pathSegments];
    if (segments.isNotEmpty && segments.last == 'v1') segments.removeLast();
    return base.replace(pathSegments: segments);
  }

  String get hostLabel {
    final uri = apiBase;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  factory ModelConnection.fromJson(Map<String, dynamic> json) =>
      ModelConnection(
        id: json['id'] as String,
        provider: ConnectionProvider.byName(json['provider'] as String?),
        name: json['name'] as String? ?? '',
        baseUrl: json['base_url'] as String? ?? '',
        maxTokensLimit: (json['max_tokens_limit'] as num?)?.toInt(),
        modelIds: (json['model_ids'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(),
        enabled: json['enabled'] as bool? ?? true,
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider.name,
    'name': name,
    'base_url': baseUrl,
    if (maxTokensLimit != null) 'max_tokens_limit': maxTokensLimit,
    'model_ids': modelIds,
    'enabled': enabled,
    'created_at': createdAt.toIso8601String(),
  };

  ModelConnection copyWith({
    ConnectionProvider? provider,
    String? name,
    String? baseUrl,
    int? Function()? maxTokensLimit,
    List<String>? modelIds,
    bool? enabled,
  }) => ModelConnection(
    id: id,
    provider: provider ?? this.provider,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    maxTokensLimit: maxTokensLimit == null
        ? this.maxTokensLimit
        : maxTokensLimit(),
    modelIds: modelIds ?? this.modelIds,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt,
  );
}

/// Memory state of one model on a connection, as reported by the server.
enum RemoteModelState {
  loaded('LOADED'),
  loading('LOADING'),
  unloaded('NOT LOADED'),

  /// The server tried to load the model and gave up (llama-server router).
  failed('FAILED'),

  /// The provider doesn't expose memory state (cloud APIs, vLLM).
  available('AVAILABLE'),
  unknown('UNKNOWN');

  const RemoteModelState(this.label);

  final String label;

  static RemoteModelState parse(Object? value) {
    final text = switch (value) {
      final Map map => map['value']?.toString(),
      final Object other => other.toString(),
      null => null,
    };
    return switch (text?.toLowerCase()) {
      'loaded' || 'running' => RemoteModelState.loaded,
      'loading' => RemoteModelState.loading,
      'failed' || 'error' => RemoteModelState.failed,
      'unloaded' || 'not-loaded' || 'not_loaded' => RemoteModelState.unloaded,
      _ => RemoteModelState.unknown,
    };
  }
}

/// A model advertised by a connection's server.
class RemoteModelInfo {
  const RemoteModelInfo({
    required this.id,
    this.state = RemoteModelState.available,
    this.sizeBytes,
    this.detail = '',
  });

  final String id;
  final RemoteModelState state;
  final int? sizeBytes;
  final String detail;
}
