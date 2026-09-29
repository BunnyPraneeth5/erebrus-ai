import 'dart:convert';

import 'package:erebrus_ai/services/network_inference_service.dart';
import 'package:erebrus_ai/services/node_discovery_service.dart';
import 'package:erebrus_ai/services/tools/agent_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _target = NetworkModelTarget(
  nodeId: 'conn:1',
  nodeName: 'Ollama',
  host: 'localhost',
  port: 11434,
  accessToken: '',
  modelId: 'qwen3:8b',
  modelName: 'qwen3:8b',
  requiresAccessToken: false,
  isConnection: true,
);

String _sse(List<Map<String, Object?>> chunks) => [
  for (final chunk in chunks) 'data: ${jsonEncode(chunk)}\n',
  'data: [DONE]\n',
].join('\n');

Map<String, Object?> _delta(Map<String, Object?> delta, {String? finish}) => {
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': finish},
  ],
};

class _FakeSearch extends AgentTool {
  final calls = <Map<String, Object?>>[];

  @override
  String get name => 'web_search';

  @override
  String get description => 'search';

  @override
  Map<String, Object?> get parameters => const {'type': 'object'};

  @override
  String label(Map<String, Object?> arguments) =>
      'Searching the web for “${arguments['query']}”';

  @override
  Future<ToolOutcome> run(
    Map<String, Object?> arguments,
    AgentRunContext context,
  ) async {
    calls.add(arguments);
    final source = context.addSource('https://nasa.gov/apollo', 'Apollo');
    return ToolOutcome(
      content: '[${source.index}] Apollo 11 landed on July 20, 1969.',
      summary: '1 result',
    );
  }
}

void main() {
  test('runs a streamed tool call and answers with its result', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (bodies.length == 1) {
        // Name and arguments arrive split across deltas, as real servers do.
        return http.Response(
          _sse([
            _delta({'content': 'Let me check. '}),
            _delta({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_a',
                  'type': 'function',
                  'function': {'name': 'web_search', 'arguments': '{"que'},
                },
              ],
            }),
            _delta({
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': 'ry": "moon landing"}'},
                },
              ],
            }, finish: 'tool_calls'),
          ]),
          200,
        );
      }
      return http.Response(
        _sse([
          _delta({'content': 'It was July 20, 1969 [1].'}, finish: 'stop'),
        ]),
        200,
      );
    });
    final search = _FakeSearch();
    final context = AgentRunContext();
    final events = await NetworkInferenceService(client: client)
        .generateWithTools(
          target: _target,
          prompt: 'When was the moon landing?',
          tools: [search],
          context: context,
          history: const [
            NetworkChatTurn(role: 'user', content: 'Hi'),
            NetworkChatTurn(role: 'assistant', content: 'Hello!'),
          ],
        )
        .toList();

    expect(search.calls, [
      {'query': 'moon landing'},
    ]);
    expect(
      events.whereType<AgentTextDelta>().map((e) => e.text).join(),
      'Let me check. It was July 20, 1969 [1].',
    );
    final started = events.whereType<AgentToolStarted>().single;
    expect(started.label, 'Searching the web for “moon landing”');
    expect(
      events.whereType<AgentToolFinished>().single.outcome.summary,
      '1 result',
    );
    expect(context.sources.single.url, 'https://nasa.gov/apollo');

    // First request offers the tool and carries system + history + prompt.
    expect(
      (bodies[0]['tools'] as List).single['function']['name'],
      'web_search',
    );
    final first = bodies[0]['messages'] as List;
    expect(first.first['role'], 'system');
    expect(first.first['content'], contains('untrusted'));
    expect(first.map((m) => m['role']), [
      'system',
      'user',
      'assistant',
      'user',
    ]);

    // Second request replays the call and its result for the model.
    final second = bodies[1]['messages'] as List;
    final call = second[second.length - 2] as Map;
    expect(call['role'], 'assistant');
    expect(call['tool_calls'][0]['id'], 'call_a');
    expect(
      call['tool_calls'][0]['function']['arguments'],
      '{"query": "moon landing"}',
    );
    final result = second.last as Map;
    expect(result['role'], 'tool');
    expect(result['tool_call_id'], 'call_a');
    expect(result['content'], contains('July 20, 1969'));
  });

  test(
    'stops offering tools on the last step so the model must answer',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body.containsKey('tools')) {
          return http.Response(
            _sse([
              _delta({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_$requests',
                    'function': {
                      'name': 'web_search',
                      'arguments': '{"query":"again"}',
                    },
                  },
                ],
              }, finish: 'tool_calls'),
            ]),
            200,
          );
        }
        return http.Response(
          _sse([
            _delta({'content': 'Final answer.'}),
          ]),
          200,
        );
      });
      final search = _FakeSearch();
      final events = await NetworkInferenceService(client: client)
          .generateWithTools(
            target: _target,
            prompt: 'loop forever',
            tools: [search],
            context: AgentRunContext(),
            maxSteps: 3,
          )
          .toList();
      expect(requests, 3);
      expect(search.calls, hasLength(2));
      expect(events.whereType<AgentTextDelta>().single.text, 'Final answer.');
    },
  );

  test(
    'reports an unknown tool back to the model instead of failing',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (bodies.length == 1) {
          return http.Response(
            _sse([
              _delta({
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'name': 'delete_files', 'arguments': '{}'},
                  },
                ],
              }),
            ]),
            200,
          );
        }
        return http.Response(
          _sse([
            _delta({'content': 'Sorry.'}),
          ]),
          200,
        );
      });
      final events = await NetworkInferenceService(client: client)
          .generateWithTools(
            target: _target,
            prompt: 'x',
            tools: [_FakeSearch()],
            context: AgentRunContext(),
          )
          .toList();
      final finished = events.whereType<AgentToolFinished>().single;
      expect(finished.outcome.isError, isTrue);
      final toolMessage = (bodies[1]['messages'] as List).last as Map;
      expect(toolMessage['content'], contains('no tool named "delete_files"'));
    },
  );

  test('retries once when a server drops a reused connection', () async {
    // Seen live with llama-server: the request right after a tool step can
    // hit a connection the server just closed.
    var attempts = 0;
    final persistent = <bool>[];
    final client = MockClient((request) async {
      attempts++;
      persistent.add(request.persistentConnection);
      if (attempts == 1) {
        throw http.ClientException(
          'Connection closed before full header was received',
          request.url,
        );
      }
      return http.Response(
        _sse([
          _delta({'content': 'ok'}),
        ]),
        200,
      );
    });
    final events = await NetworkInferenceService(client: client)
        .generateWithTools(
          target: _target,
          prompt: 'x',
          tools: [_FakeSearch()],
          context: AgentRunContext(),
        )
        .toList();
    expect(attempts, 2);
    expect(persistent, everyElement(isFalse));
    expect(events.whereType<AgentTextDelta>().single.text, 'ok');
  });

  test('explains when a model or server cannot do tool calls', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'message': 'model does not support tools'},
        }),
        400,
      ),
    );
    await expectLater(
      NetworkInferenceService(client: client)
          .generateWithTools(
            target: _target,
            prompt: 'x',
            tools: [_FakeSearch()],
            context: AgentRunContext(),
          )
          .toList(),
      throwsA(
        isA<NetworkInferenceException>().having(
          (e) => e.message,
          'message',
          contains('turn off web search'),
        ),
      ),
    );
  });
}
