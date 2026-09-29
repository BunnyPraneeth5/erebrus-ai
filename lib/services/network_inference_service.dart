import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'node_discovery_service.dart';
import 'tools/agent_tools.dart';
import 'tools/web_tools.dart';

class NetworkInferenceException implements Exception {
  const NetworkInferenceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One prior turn sent with a network request so remote models see context.
class NetworkChatTurn {
  const NetworkChatTurn({required this.role, required this.content});

  final String role;
  final String content;
}

/// Streams OpenAI-compatible completions from another Erebrus node on LAN or
/// from a user-configured connection (llama.cpp, Ollama, OpenAI, …).
class NetworkInferenceService extends ChangeNotifier {
  NetworkInferenceService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static final NetworkInferenceService _instance = NetworkInferenceService();
  static NetworkInferenceService get instance => _instance;

  http.Client _client;
  final bool _ownsClient;
  bool _isGenerating = false;

  bool get isGenerating => _isGenerating;

  Stream<String> generate({
    required NetworkModelTarget target,
    required String prompt,
    String systemPrompt = '',
    List<NetworkChatTurn> history = const [],
    int maxOutputTokens = 768,
    double temperature = 0.7,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    List<String> stop = const [],
  }) async* {
    _begin(target);
    try {
      final body = _requestBody(
        target: target,
        messages: [
          if (systemPrompt.trim().isNotEmpty)
            {'role': 'system', 'content': systemPrompt},
          for (final turn in history)
            {'role': turn.role, 'content': turn.content},
          {'role': 'user', 'content': prompt},
        ],
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        repeatPenalty: repeatPenalty,
        stop: stop,
      );
      await for (final choice in _streamChoices(target, body)) {
        final delta = choice['delta'];
        final message = choice['message'];
        final content = delta is Map
            ? delta['content']?.toString()
            : message is Map
            ? message['content']?.toString()
            : null;
        if (content != null && content.isNotEmpty) yield content;
      }
    } finally {
      _end();
    }
  }

  /// Runs a tool-using turn: the model may call [tools] (up to [maxSteps]
  /// rounds); each call runs here and its result is sent back until the
  /// model answers in text. Emits text as it streams plus tool progress.
  Stream<AgentEvent> generateWithTools({
    required NetworkModelTarget target,
    required String prompt,
    required List<AgentTool> tools,
    required AgentRunContext context,
    String systemPrompt = '',
    List<NetworkChatTurn> history = const [],
    int maxSteps = 5,
    int maxOutputTokens = 768,
    double temperature = 0.7,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    List<String> stop = const [],
  }) async* {
    _begin(target);
    try {
      final byName = {for (final tool in tools) tool.name: tool};
      final messages = <Map<String, Object?>>[
        {
          'role': 'system',
          'content': [
            if (systemPrompt.trim().isNotEmpty) systemPrompt.trim(),
            agentToolInstructions(DateTime.now()),
          ].join('\n\n'),
        },
        for (final turn in history)
          {'role': turn.role, 'content': turn.content},
        {'role': 'user', 'content': prompt},
      ];

      for (var step = 0; step < maxSteps; step++) {
        // The last round withholds tools so the model has to answer.
        final offerTools = step < maxSteps - 1;
        final body = _requestBody(
          target: target,
          messages: messages,
          maxOutputTokens: maxOutputTokens,
          temperature: temperature,
          topP: topP,
          repeatPenalty: repeatPenalty,
          stop: stop,
          tools: offerTools ? tools : const [],
        );
        final text = StringBuffer();
        final calls = <int, _PendingToolCall>{};
        await for (final choice in _streamChoices(target, body)) {
          final delta = choice['delta'] ?? choice['message'];
          if (delta is! Map) continue;
          final content = delta['content']?.toString();
          if (content != null && content.isNotEmpty) {
            text.write(content);
            yield AgentTextDelta(content);
          }
          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final raw in toolCalls.whereType<Map>()) {
              final index = (raw['index'] as num?)?.toInt() ?? calls.length;
              final pending = calls.putIfAbsent(index, _PendingToolCall.new);
              if (raw['id'] is String) pending.id = raw['id'] as String;
              final function = raw['function'];
              if (function is Map) {
                if (function['name'] is String) {
                  pending.name += function['name'] as String;
                }
                final arguments = function['arguments'];
                if (arguments is String) {
                  pending.arguments.write(arguments);
                } else if (arguments is Map) {
                  pending.arguments.write(jsonEncode(arguments));
                }
              }
            }
          }
        }

        final requested = calls.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        if (requested.isEmpty) return;

        messages.add({
          'role': 'assistant',
          'content': text.isEmpty ? null : text.toString(),
          'tool_calls': [
            for (final entry in requested)
              {
                'id': entry.value.idFor(entry.key, step),
                'type': 'function',
                'function': {
                  'name': entry.value.name,
                  'arguments': entry.value.arguments.isEmpty
                      ? '{}'
                      : entry.value.arguments.toString(),
                },
              },
          ],
        });

        for (final entry in requested) {
          final call = entry.value;
          final id = call.idFor(entry.key, step);
          final tool = byName[call.name];
          Map<String, Object?> arguments = const {};
          ToolOutcome outcome;
          try {
            arguments = decodeToolArguments(call.arguments.toString());
          } on FormatException {
            arguments = const {};
          }
          yield AgentToolStarted(
            id: id,
            name: call.name,
            label: tool?.label(arguments) ?? 'Calling ${call.name}',
          );
          if (tool == null) {
            outcome = ToolOutcome(
              content: 'Error: there is no tool named "${call.name}".',
              summary: 'Unknown tool',
              isError: true,
            );
          } else {
            try {
              outcome = await tool.run(arguments, context);
            } on Object catch (error) {
              final message = error is WebToolException
                  ? error.message
                  : error.toString();
              outcome = ToolOutcome(
                content: 'Error: $message',
                summary: message,
                isError: true,
              );
            }
          }
          yield AgentToolFinished(id: id, outcome: outcome);
          messages.add({
            'role': 'tool',
            'tool_call_id': id,
            'name': call.name,
            'content': outcome.content,
          });
        }
      }
    } finally {
      _end();
    }
  }

  void _begin(NetworkModelTarget target) {
    if (_isGenerating) {
      throw const NetworkInferenceException(
        'Another network response is already being generated.',
      );
    }
    if (target.requiresAccessToken && target.accessToken.isEmpty) {
      throw const NetworkInferenceException(
        'This node was discovered without a LAN access token. Update Erebrus AI on the serving device, restart LAN sharing, then rescan.',
      );
    }
    _isGenerating = true;
    notifyListeners();
  }

  void _end() {
    _isGenerating = false;
    notifyListeners();
  }

  Map<String, Object?> _requestBody({
    required NetworkModelTarget target,
    required List<Map<String, Object?>> messages,
    required int maxOutputTokens,
    required double temperature,
    required double topP,
    required double repeatPenalty,
    required List<String> stop,
    List<AgentTool> tools = const [],
  }) {
    final limit = target.maxTokensLimit;
    return {
      'model': target.modelId,
      'stream': true,
      'messages': messages,
      'max_tokens': limit == null
          ? maxOutputTokens
          : maxOutputTokens.clamp(1, limit),
      'temperature': temperature,
      'top_p': topP,
      if (target.acceptsLlamaSampling) 'repeat_penalty': repeatPenalty,
      if (stop.isNotEmpty) 'stop': stop,
      if (tools.isNotEmpty) ...{
        'tools': [for (final tool in tools) tool.toSchema()],
        'tool_choice': 'auto',
      },
    };
  }

  /// Sends a streaming chat request on a fresh connection. Servers such as
  /// llama-server close the connection after a streamed response; reusing a
  /// pooled keep-alive connection for the agent loop's next request then
  /// fails with "Connection closed before full header". If that still
  /// happens, the server never saw the request, so one retry is safe.
  Future<http.StreamedResponse> _sendWithRetry(
    NetworkModelTarget target,
    Map<String, Object?> body,
  ) async {
    http.BaseRequest build() {
      final request = http.Request('POST', target.chatCompletionsUri)
        ..persistentConnection = false
        ..headers['accept'] = 'text/event-stream'
        ..headers['content-type'] = 'application/json'
        ..headers.addAll(target.extraHeaders)
        ..body = jsonEncode(body);
      if (target.accessToken.isNotEmpty) {
        request.headers['authorization'] = 'Bearer ${target.accessToken}';
      }
      return request;
    }

    try {
      return await _client.send(build());
    } on http.ClientException catch (error) {
      if (!error.message.contains('Connection closed before full header')) {
        rethrow;
      }
      return _client.send(build());
    }
  }

  /// Streams the first `choices` entry of each SSE chunk, translating
  /// transport and server failures into [NetworkInferenceException]s.
  Stream<Map> _streamChoices(
    NetworkModelTarget target,
    Map<String, Object?> body,
  ) async* {
    try {
      final response = await _sendWithRetry(target, body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await response.stream.bytesToString();
        final serverMsg = _errorMessage(text);
        if (target.isConnection &&
            (response.statusCode == 401 || response.statusCode == 403)) {
          throw NetworkInferenceException(
            '${target.nodeName} rejected the API key. Update it in Settings → Connections.',
          );
        }
        if (response.statusCode == 401 ||
            serverMsg?.toLowerCase().contains('invalid api key') == true) {
          throw const NetworkInferenceException(
            'The host node token expired or the host was restarted. Please go to Models and tap Rescan to refresh.',
          );
        }
        if (body.containsKey('tools') &&
            serverMsg != null &&
            serverMsg.toLowerCase().contains('tool')) {
          throw NetworkInferenceException(
            '${target.nodeName} could not use tools with this model: $serverMsg. '
            'Pick a tool-capable model or turn off web search for this chat.',
          );
        }
        throw NetworkInferenceException(
          serverMsg ?? 'The node returned HTTP ${response.statusCode}.',
        );
      }

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final decoded = jsonDecode(data);
        if (decoded is! Map) continue;
        final error = decoded['error'];
        if (error is Map) {
          throw NetworkInferenceException(
            error['message']?.toString() ?? 'Network inference failed.',
          );
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          continue;
        }
        yield choices.first as Map;
      }
    } on NetworkInferenceException {
      rethrow;
    } on Object catch (error) {
      final errorStr = error.toString();
      if (errorStr.contains('Connection closed before full header') ||
          errorStr.contains('Connection reset') ||
          errorStr.contains('Connection refused') ||
          errorStr.contains('Software caused connection abort') ||
          errorStr.contains('SocketException')) {
        throw NetworkInferenceException(
          target.isConnection
              ? 'Could not reach ${target.nodeName} at ${target.chatCompletionsUri.origin}. Check that the server is running and the base URL in Settings → Connections is right.'
              : 'Connection to ${target.nodeName} was lost or interrupted. Please ensure the Erebrus AI app is open on the host device and tap Rescan in Models.',
        );
      }
      throw NetworkInferenceException(
        'Could not reach ${target.nodeName}: $error',
      );
    }
  }

  Future<void> cancel() async {
    if (!_isGenerating) return;
    _client.close();
    if (_ownsClient) _client = http.Client();
    _isGenerating = false;
    notifyListeners();
  }

  static String? _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        return (decoded['error'] as Map)['message']?.toString();
      }
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // The HTTP status below remains more useful than an HTML/plain response.
    }
    return null;
  }
}

/// Progress of a tool-using network turn.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentTextDelta extends AgentEvent {
  const AgentTextDelta(this.text);

  final String text;
}

class AgentToolStarted extends AgentEvent {
  const AgentToolStarted({
    required this.id,
    required this.name,
    required this.label,
  });

  final String id;
  final String name;
  final String label;
}

class AgentToolFinished extends AgentEvent {
  const AgentToolFinished({required this.id, required this.outcome});

  final String id;
  final ToolOutcome outcome;
}

/// A tool call assembled from streamed deltas (name and arguments arrive in
/// fragments keyed by `index`).
class _PendingToolCall {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();

  String idFor(int index, int step) => id ?? 'call_${step}_$index';
}
