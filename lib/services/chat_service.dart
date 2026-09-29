import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/catalog_service.dart';
import '../data/mock_data.dart';
import '../data/model_connection.dart';
import '../data/tool_activity.dart';
import 'connection_service.dart';
import 'inference_service.dart';
import 'imported_model_service.dart';
import 'model_download_service.dart';
import 'model_package_service.dart';
import 'network_inference_service.dart';
import 'node_discovery_service.dart';
import 'storage_service.dart';
import 'tools/agent_tools.dart';

/// A real chat session and message store.
///
/// Persists sessions/messages to disk and sends user messages to the local
/// OpenAI-compatible server (`LocalServerService`). If the server or selected
/// model is not ready, the assistant reply explains why instead of faking a
/// real model response.
class ChatService extends ChangeNotifier {
  ChatService._();
  static final ChatService _instance = ChatService._();
  static ChatService get instance => _instance;

  final List<ChatSession> _sessions = [];
  final Map<String, List<ChatMessage>> _messages = {};
  String? _activeSessionId;
  String _pendingDraft = '';
  bool _loaded = false;

  List<ChatSession> get sessions => List.unmodifiable(_sessions);
  String? get activeSessionId => _activeSessionId;
  String get pendingDraft => _pendingDraft;
  ChatSession? get activeSession {
    if (_activeSessionId == null) return null;
    return _sessions.where((s) => s.id == _activeSessionId).firstOrNull;
  }

  List<ChatMessage> messagesFor(String? sessionId) {
    if (sessionId == null) return const [];
    return List.unmodifiable(_messages[sessionId] ?? const []);
  }

  bool get _inTest => Platform.environment.containsKey('FLUTTER_TEST');

  /// Loads persisted sessions and messages from disk.
  Future<void> load() async {
    if (_loaded || kIsWeb || _inTest) {
      _loaded = true;
      notifyListeners();
      return;
    }
    final dir = await StorageService.instance.chatsDir();
    if (!await dir.exists()) {
      _loaded = true;
      notifyListeners();
      return;
    }
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    _sessions.clear();
    _messages.clear();
    for (final file in files) {
      try {
        final text = await file.readAsString();
        final json = jsonDecode(text) as Map<String, dynamic>;
        final session = ChatSession.fromJson(json['session']);
        final msgs = (json['messages'] as List<dynamic>)
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList();
        _sessions.add(session);
        _messages[session.id] = msgs;
      } catch (e) {
        debugPrint('[Chat] corrupt session file ${file.path}: $e');
      }
    }
    _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _activeSessionId = _sessions.isNotEmpty ? _sessions.first.id : null;
    _loaded = true;
    notifyListeners();
  }

  /// Creates a new empty session and makes it active.
  Future<void> newSession() async {
    final session = ChatSession(
      id: const Uuid().v4(),
      title: 'New chat',
      modelId: '',
      networkNodeId: '',
      updatedAt: DateTime.now(),
    );
    _sessions.insert(0, session);
    _messages[session.id] = [];
    _activeSessionId = session.id;
    notifyListeners();
    await _persist(session.id);
  }

  Future<String> prepareDraft(String text) async {
    await newSession();
    _pendingDraft = text;
    notifyListeners();
    return _activeSessionId!;
  }

  String takePendingDraft() {
    final draft = _pendingDraft;
    _pendingDraft = '';
    return draft;
  }

  /// Switches the active session.
  void selectSession(String id) {
    if (!_messages.containsKey(id)) return;
    _activeSessionId = id;
    notifyListeners();
  }

  /// Permanently removes a chat and its persisted message file.
  Future<void> deleteSession(String id) async {
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    if (_activeSessionId == id && InferenceService.instance.isGenerating) {
      await InferenceService.instance.cancel();
    }
    if (_activeSessionId == id &&
        NetworkInferenceService.instance.isGenerating) {
      await NetworkInferenceService.instance.cancel();
    }
    _sessions.removeAt(index);
    _messages.remove(id);
    if (_activeSessionId == id) {
      _activeSessionId = _sessions.firstOrNull?.id;
    }
    notifyListeners();
    if (kIsWeb || _inTest) return;
    final directory = await StorageService.instance.chatsDir();
    final file = File(p.join(directory.path, '$id.json'));
    if (await file.exists()) await file.delete();
  }

  /// Sends a user message in the active session and streams the assistant reply.
  Future<void> send(
    String text, {
    String? modelId,
    String? networkNodeId,
    MockPersona? persona,
    bool webTools = false,
  }) async {
    if (text.trim().isEmpty) return;
    if (activeSession == null) await newSession();
    final session = activeSession!;
    final sid = session.id;
    final resolvedModel = modelId?.isNotEmpty == true
        ? modelId!
        : session.modelId.isNotEmpty
        ? session.modelId
        : '';
    final resolvedNetworkNodeId = networkNodeId ?? session.networkNodeId;

    // Remember the model used for this session.
    if (resolvedModel.isNotEmpty &&
        (session.modelId != resolvedModel ||
            session.networkNodeId != resolvedNetworkNodeId)) {
      final idx = _sessions.indexWhere((s) => s.id == sid);
      if (idx >= 0) {
        _sessions[idx] = session.copyWith(
          modelId: resolvedModel,
          networkNodeId: resolvedNetworkNodeId,
        );
      }
    }

    _messages.putIfAbsent(sid, () => []);
    _messages[sid]!.add(ChatMessage.user(text));
    _updateSessionTitle(sid, text);
    notifyListeners();

    await _persist(sid);

    final assistant = ChatMessage.streaming('');
    _messages[sid]!.add(assistant);
    notifyListeners();

    await _generateAssistant(
      sid: sid,
      assistant: assistant,
      prompt: text,
      modelId: resolvedModel,
      networkNodeId: resolvedNetworkNodeId,
      persona: persona,
      webTools: webTools,
    );
  }

  Future<void> _generateAssistant({
    required String sid,
    required ChatMessage assistant,
    required String prompt,
    required String modelId,
    required String networkNodeId,
    MockPersona? persona,
    bool webTools = false,
  }) async {
    final raw = StringBuffer();
    assistant.activity.clear();
    assistant.sources.clear();
    try {
      final tools = webTools ? availableAgentTools() : const <AgentTool>[];
      final target = networkNodeId.isEmpty
          ? null
          : resolveNetworkTarget(networkNodeId, modelId);
      if (tools.isNotEmpty && target != null && target.isConnection) {
        await _generateWithTools(
          sid: sid,
          assistant: assistant,
          prompt: prompt,
          target: target,
          tools: tools,
          persona: persona,
          raw: raw,
        );
      } else {
        await _generatePlain(
          sid: sid,
          assistant: assistant,
          prompt: prompt,
          modelId: modelId,
          networkNodeId: networkNodeId,
          persona: persona,
          raw: raw,
        );
      }
    } on ModelNotLoadedException catch (e) {
      assistant.text = e.message;
    } catch (e) {
      final failure = networkNodeId.isEmpty
          ? 'Local inference failed: $e'
          : 'Network inference failed: $e';
      // Keep any partial answer from a tool-using turn above the error.
      assistant.text = assistant.text.trim().isEmpty
          ? failure
          : '${assistant.text.trim()}\n\n$failure';
    }
    assistant.streaming = false;
    assistant.meta = networkNodeId.isEmpty
        ? 'LOCAL'
        : 'NETWORK · ${networkSourceName(networkNodeId) ?? 'LAN NODE'}';
    notifyListeners();
    await _persist(sid);
  }

  /// Replaces an assistant response using the user message immediately before
  /// it. This does not duplicate the user prompt in the conversation.
  Future<void> regenerate(
    String assistantMessageId, {
    MockPersona? persona,
    bool webTools = false,
  }) async {
    if (InferenceService.instance.isGenerating ||
        NetworkInferenceService.instance.isGenerating) {
      return;
    }
    final sid = _activeSessionId;
    final session = activeSession;
    final messages = sid == null ? null : _messages[sid];
    if (sid == null || session == null || messages == null) return;

    final assistantIndex = messages.indexWhere(
      (message) => message.id == assistantMessageId && !message.isUser,
    );
    if (assistantIndex <= 0) return;
    final userIndex = messages
        .sublist(0, assistantIndex)
        .lastIndexWhere((message) => message.isUser);
    if (userIndex < 0) return;

    final replacement = ChatMessage.streaming('');
    messages[assistantIndex] = replacement;
    notifyListeners();
    await _persist(sid);
    await _generateAssistant(
      sid: sid,
      assistant: replacement,
      prompt: messages[userIndex].text,
      modelId: session.modelId,
      networkNodeId: session.networkNodeId,
      persona: persona,
      webTools: webTools,
    );
  }

  Future<Stream<String>> _infer(
    String modelId,
    String prompt,
    MockPersona? persona, {
    required String networkNodeId,
    List<NetworkChatTurn> history = const [],
  }) async {
    if (kIsWeb || _inTest) {
      return Stream.fromIterable(['Test mode: no inference.']);
    }

    if (networkNodeId.isNotEmpty) {
      final target = resolveNetworkTarget(networkNodeId, modelId);
      if (target == null) {
        throw NetworkInferenceException(
          networkNodeId.startsWith(ModelConnection.nodeIdPrefix)
              ? 'This connection or model was removed or disabled. Pick another model or check Settings → Connections.'
              : 'The selected node is no longer available. Make sure both devices are on the same Wi-Fi, keep LAN sharing enabled, and rescan Models.',
        );
      }
      return NetworkInferenceService.instance.generate(
        target: target,
        prompt: prompt,
        history: history,
        systemPrompt: persona?.systemPrompt ?? '',
        maxOutputTokens: persona?.maxTokens ?? 768,
        temperature: persona?.temperature ?? 0.7,
        topP: persona?.topP ?? 0.9,
        repeatPenalty: persona?.repeatPenalty ?? 1.1,
        stop: (persona?.stopSequences ?? '')
            .split(RegExp(r'[\n,]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
      );
    }

    if (modelId.isEmpty ||
        (!ModelDownloadService.instance.isDownloaded(modelId) &&
            !ModelPackageService.instance.isModelRunnable(modelId) &&
            !ImportedModelService.instance.contains(modelId))) {
      final catalog = CatalogService.entries;
      final byId = {for (final e in catalog) e.id: e};
      final name = byId[modelId]?.name ?? modelId;
      return Stream.fromIterable([
        'Model "$name" is not downloaded. Download it from the Models tab first.',
      ]);
    }

    // On-device models load only when the user presses Load (chat header);
    // the LAN server path still loads on demand for remote clients.
    if (!InferenceService.instance.isLoaded(modelId)) {
      throw const ModelNotLoadedException();
    }

    try {
      return InferenceService.instance.generate(
        modelId: modelId,
        prompt: prompt,
        systemPrompt: persona?.systemPrompt ?? '',
        maxOutputTokens: persona?.maxTokens ?? 768,
        temperature: persona?.temperature ?? 0.7,
        topP: persona?.topP ?? 0.9,
        repeatPenalty: persona?.repeatPenalty ?? 1.1,
        stop: (persona?.stopSequences ?? '')
            .split(RegExp(r'[\n,]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
      );
    } catch (e) {
      return Stream.fromIterable(['Local inference failed: $e']);
    }
  }

  Future<void> _generatePlain({
    required String sid,
    required ChatMessage assistant,
    required String prompt,
    required String modelId,
    required String networkNodeId,
    required MockPersona? persona,
    required StringBuffer raw,
  }) async {
    final stream = await _infer(
      modelId,
      prompt,
      persona,
      networkNodeId: networkNodeId,
      history: networkNodeId.isEmpty
          ? const []
          : _historyBefore(sid, assistant),
    );
    await for (final chunk in stream) {
      raw.write(chunk);
      assistant.text = sanitizeAssistantText(raw.toString());
      if (networkNodeId.isEmpty) {
        assistant.tokensPerSecond =
            InferenceService.instance.currentTokensPerSecond;
      }
      notifyListeners();
    }
    assistant.text = sanitizeAssistantText(raw.toString());
    if (networkNodeId.isEmpty) {
      assistant.tokensPerSecond =
          InferenceService.instance.lastTokensPerSecond ??
          assistant.tokensPerSecond;
      assistant.truncated = InferenceService.instance.lastOutputWasTruncated;
    }
  }

  /// Runs one tool-using turn against a connection model, streaming text and
  /// recording each tool step and consulted source on [assistant].
  Future<void> _generateWithTools({
    required String sid,
    required ChatMessage assistant,
    required String prompt,
    required NetworkModelTarget target,
    required List<AgentTool> tools,
    required MockPersona? persona,
    required StringBuffer raw,
  }) async {
    final context = AgentRunContext();
    var separate = false;
    await for (final event
        in NetworkInferenceService.instance.generateWithTools(
          target: target,
          prompt: prompt,
          tools: tools,
          context: context,
          systemPrompt: persona?.systemPrompt ?? '',
          history: _historyBefore(sid, assistant),
          maxOutputTokens: persona?.maxTokens ?? 768,
          temperature: persona?.temperature ?? 0.7,
          topP: persona?.topP ?? 0.9,
          repeatPenalty: persona?.repeatPenalty ?? 1.1,
          stop: _stopSequences(persona),
        )) {
      switch (event) {
        case AgentTextDelta(:final text):
          // Text after a tool step starts a new paragraph.
          if (separate && raw.toString().trim().isNotEmpty) raw.write('\n\n');
          separate = false;
          raw.write(text);
          assistant.text = sanitizeAssistantText(raw.toString());
        case AgentToolStarted(:final id, :final name, :final label):
          assistant.activity.add(
            ToolActivity(id: id, name: name, label: label),
          );
          separate = true;
        case AgentToolFinished(:final id, :final outcome):
          final step = assistant.activity
              .where((activity) => activity.id == id)
              .lastOrNull;
          if (step != null) {
            step
              ..status = outcome.isError
                  ? ToolActivityStatus.failed
                  : ToolActivityStatus.done
              ..summary = outcome.summary
              ..label = _pastTense(step.label);
          }
          assistant.sources
            ..clear()
            ..addAll(context.sources);
      }
      notifyListeners();
    }
    assistant.text = sanitizeAssistantText(raw.toString());
  }

  static String _pastTense(String label) => label
      .replaceFirst('Searching', 'Searched')
      .replaceFirst('Reading', 'Read');

  static List<String> _stopSequences(MockPersona? persona) =>
      (persona?.stopSequences ?? '')
          .split(RegExp(r'[\n,]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();

  /// Prior completed turns (excluding the prompt being answered) for servers
  /// that accept multi-turn context. Capped to keep requests small.
  List<NetworkChatTurn> _historyBefore(String sid, ChatMessage assistant) {
    final messages = _messages[sid] ?? const <ChatMessage>[];
    final assistantIndex = messages.indexOf(assistant);
    if (assistantIndex <= 0) return const [];
    // The user prompt sits right before the assistant placeholder.
    final prior = messages.sublist(0, assistantIndex - 1);
    final turns = [
      for (final message in prior)
        if (!message.streaming && message.text.trim().isNotEmpty)
          NetworkChatTurn(
            role: message.isUser ? 'user' : 'assistant',
            content: message.text,
          ),
    ];
    const maxTurns = 20;
    return turns.length > maxTurns
        ? turns.sublist(turns.length - maxTurns)
        : turns;
  }

  void _updateSessionTitle(String sid, String text) {
    final idx = _sessions.indexWhere((s) => s.id == sid);
    if (idx == -1) return;
    final session = _sessions[idx];
    if (session.title == 'New chat') {
      final firstLine = text.split('\n').first.trim();
      final title = firstLine.length > 40
          ? '${firstLine.substring(0, 37)}...'
          : firstLine;
      _sessions[idx] = session.copyWith(title: title);
    }
    _sessions[idx] = _sessions[idx].copyWith(updatedAt: DateTime.now());
  }

  Future<void> _persist(String sid) async {
    if (kIsWeb || _inTest) return;
    final session = _sessions.where((s) => s.id == sid).firstOrNull;
    if (session == null) return;
    final dir = await StorageService.instance.chatsDir();
    final file = File(p.join(dir.path, '$sid.json'));
    final payload = {
      'session': session.toJson(),
      'messages': _messages[sid]?.map((m) => m.toJson()).toList() ?? [],
    };
    await file.writeAsString(jsonEncode(payload));
  }
}

class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.modelId,
    this.networkNodeId = '',
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String modelId;
  final String networkNodeId;
  final DateTime updatedAt;

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
    id: json['id'] as String,
    title: json['title'] as String,
    modelId: json['model_id'] as String? ?? '',
    networkNodeId: json['network_node_id'] as String? ?? '',
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model_id': modelId,
    if (networkNodeId.isNotEmpty) 'network_node_id': networkNodeId,
    'updated_at': updatedAt.toIso8601String(),
  };

  ChatSession copyWith({
    String? title,
    String? modelId,
    String? networkNodeId,
    DateTime? updatedAt,
  }) => ChatSession(
    id: id,
    title: title ?? this.title,
    modelId: modelId ?? this.modelId,
    networkNodeId: networkNodeId ?? this.networkNodeId,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    this.streaming = false,
    this.meta,
    this.tokensPerSecond,
    this.truncated = false,
    List<ToolActivity>? activity,
    List<SourceRef>? sources,
  }) : activity = activity ?? [],
       sources = sources ?? [];

  final String id;
  final bool isUser;
  String text;
  bool streaming;
  String? meta;
  double? tokensPerSecond;
  bool truncated;

  /// Tool steps taken while answering (web searches, page reads).
  final List<ToolActivity> activity;

  /// Web pages cited by the answer, numbered to match its [n] references.
  final List<SourceRef> sources;

  ChatMessage.user(String text)
    : this(id: const Uuid().v4(), isUser: true, text: text);

  ChatMessage.streaming(String text)
    : this(id: const Uuid().v4(), isUser: false, text: text, streaming: true);

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    isUser: json['is_user'] as bool,
    text: (json['is_user'] as bool? ?? false)
        ? json['text'] as String
        : sanitizeAssistantText(json['text'] as String),
    streaming: json['streaming'] as bool? ?? false,
    meta: json['meta'] as String?,
    tokensPerSecond: (json['tokens_per_second'] as num?)?.toDouble(),
    truncated: json['truncated'] as bool? ?? false,
    activity: [
      for (final item in json['activity'] as List? ?? const [])
        if (item is Map) ToolActivity.fromJson(item.cast<String, dynamic>()),
    ],
    sources: [
      for (final item in json['sources'] as List? ?? const [])
        if (item is Map) SourceRef.fromJson(item.cast<String, dynamic>()),
    ],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'is_user': isUser,
    'text': text,
    'streaming': streaming,
    'meta': meta,
    if (tokensPerSecond != null) 'tokens_per_second': tokensPerSecond,
    if (truncated) 'truncated': true,
    if (activity.isNotEmpty)
      'activity': activity.map((step) => step.toJson()).toList(),
    if (sources.isNotEmpty)
      'sources': sources.map((source) => source.toJson()).toList(),
  };
}

/// Removes private model reasoning from both live and persisted output.
/// While a leading think block is incomplete, nothing from it is exposed.
String sanitizeAssistantText(String text) {
  var result = text;
  final leadingOpen = RegExp(
    r'^\s*<think>',
    caseSensitive: false,
  ).firstMatch(result);
  if (leadingOpen != null) {
    final close = result.toLowerCase().indexOf('</think>', leadingOpen.end);
    if (close < 0) return '';
    result = result.substring(close + '</think>'.length);
  }

  result = result.replaceAll(
    RegExp(r'<think>.*?</think>', caseSensitive: false, dotAll: true),
    '',
  );
  result = result.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');
  return result.trimLeft();
}

/// Raised when chatting with an on-device model that has not been loaded.
class ModelNotLoadedException implements Exception {
  const ModelNotLoadedException();

  String get message =>
      'This model is not loaded. Press Load next to the model name to start '
      'chatting, and Eject to free its memory when you are done.';

  @override
  String toString() => message;
}
