import 'dart:convert';

import 'package:erebrus_ai/data/model_connection.dart';
import 'package:erebrus_ai/services/connection_service.dart';
import 'package:erebrus_ai/services/network_inference_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ModelConnection', () {
    test('derives the API base and management root from the base URL', () {
      final connection = ModelConnection(
        id: 'a',
        provider: ConnectionProvider.ollama,
        name: 'Ollama',
        baseUrl: 'http://10.0.0.5:11434/v1/',
        createdAt: DateTime(2026),
      );
      expect(connection.apiBase.toString(), 'http://10.0.0.5:11434/v1');
      expect(connection.serverRoot.toString(), 'http://10.0.0.5:11434');
      expect(connection.hostLabel, '10.0.0.5:11434');
      expect(connection.nodeId, 'conn:a');
    });

    test('round-trips JSON without an API key field', () {
      final connection = ModelConnection(
        id: 'b',
        provider: ConnectionProvider.openAi,
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        maxTokensLimit: 4096,
        modelIds: const ['gpt-5-mini'],
        createdAt: DateTime(2026),
      );
      final json = connection.toJson();
      expect(json.keys, isNot(contains('api_key')));
      final decoded = ModelConnection.fromJson(json);
      expect(decoded.provider, ConnectionProvider.openAi);
      expect(decoded.maxTokensLimit, 4096);
      expect(decoded.modelIds, ['gpt-5-mini']);
    });

    test('parses llama-server, LM Studio and Erebrus model states', () {
      expect(
        RemoteModelState.parse({'value': 'loaded'}),
        RemoteModelState.loaded,
      );
      expect(RemoteModelState.parse('not-loaded'), RemoteModelState.unloaded);
      expect(RemoteModelState.parse('loading'), RemoteModelState.loading);
      expect(RemoteModelState.parse(null), RemoteModelState.unknown);
    });
  });

  test('normalizes base URLs and manual model lists', () {
    expect(
      ConnectionService.normalizeBaseUrl(' localhost:8080/v1/ '),
      'http://localhost:8080/v1',
    );
    expect(ConnectionService.parseModelIds('a, b\n\nc\na'), ['a', 'b', 'c']);
  });

  test('lists OpenAI-compatible models with a bearer key', () async {
    late http.Request captured;
    final service = ConnectionService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-b', 'owned_by': 'openai'},
              {'id': 'gpt-a', 'owned_by': 'openai'},
            ],
          }),
          200,
        );
      }),
    );
    final models = await service.fetchAvailableModels(
      provider: ConnectionProvider.openAi,
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk-test',
    );
    expect(captured.url.toString(), 'https://api.openai.com/v1/models');
    expect(captured.headers['authorization'], 'Bearer sk-test');
    expect(models.map((model) => model.id), ['gpt-a', 'gpt-b']);
    expect(models.first.state, RemoteModelState.available);
  });

  test('uses Anthropic key headers for model listing', () async {
    late http.Request captured;
    final service = ConnectionService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-sonnet-5'},
            ],
          }),
          200,
        );
      }),
    );
    await service.fetchAvailableModels(
      provider: ConnectionProvider.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      apiKey: 'sk-ant',
    );
    expect(captured.headers['x-api-key'], 'sk-ant');
    expect(captured.headers['anthropic-version'], isNotNull);
    expect(captured.headers.containsKey('authorization'), isFalse);
  });

  test('marks running Ollama models as loaded', () async {
    final service = ConnectionService(
      client: MockClient((request) async {
        if (request.url.path == '/api/tags') {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'model': 'qwen3:8b',
                  'size': 5200000000,
                  'details': {
                    'parameter_size': '8.2B',
                    'quantization_level': 'Q4_K_M',
                  },
                },
                {'model': 'llama3.2:3b'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/ps') {
          return http.Response(
            jsonEncode({
              'models': [
                {'model': 'qwen3:8b'},
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );
    final models = await service.fetchAvailableModels(
      provider: ConnectionProvider.ollama,
      baseUrl: 'http://localhost:11434/v1',
    );
    final qwen = models.firstWhere((model) => model.id == 'qwen3:8b');
    expect(qwen.state, RemoteModelState.loaded);
    expect(qwen.detail, '8.2B · Q4_K_M');
    expect(
      models.firstWhere((model) => model.id == 'llama3.2:3b').state,
      RemoteModelState.unloaded,
    );
  });

  test('loads and offloads Ollama models via keep_alive', () async {
    final posts = <Map<String, dynamic>>[];
    final service = ConnectionService(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/api/generate');
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'done': true}), 200);
        }
        return http.Response(jsonEncode({'models': []}), 200);
      }),
    );
    final connection = await service.save(
      provider: ConnectionProvider.ollama,
      name: 'Ollama',
      baseUrl: 'http://localhost:11434/v1',
      modelIds: const ['qwen3:8b'],
    );
    await service.loadModel(connection, 'qwen3:8b');
    await service.unloadModel(connection, 'qwen3:8b');
    expect(posts[0], {'model': 'qwen3:8b', 'stream': false, 'keep_alive': -1});
    expect(posts[1]['keep_alive'], 0);
  });

  test('explains llama-server router mode when load is missing', () async {
    final service = ConnectionService(
      client: MockClient((request) async {
        if (request.method == 'POST') return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gemma'},
            ],
          }),
          200,
        );
      }),
    );
    final connection = await service.save(
      provider: ConnectionProvider.llamaCpp,
      name: 'llama.cpp',
      baseUrl: 'http://localhost:8080/v1',
      modelIds: const ['gemma'],
    );
    await expectLater(
      service.loadModel(connection, 'gemma'),
      throwsA(
        isA<ConnectionException>().having(
          (error) => error.message,
          'message',
          contains('router mode'),
        ),
      ),
    );
    expect(service.errorFor(connection.id), contains('router mode'));
  });

  /// Mirrors a real llama-server in router mode (verified against b11160):
  /// `/props` reports the router role, load returns before the model is
  /// ready, and repeating a load/unload is a 400 "already/not running".
  http.Client llamaRouter({required List<String> states, String? postError}) {
    var listed = 0;
    return MockClient((request) async {
      if (request.url.path == '/props') {
        return http.Response(jsonEncode({'role': 'router'}), 200);
      }
      if (request.method == 'POST') {
        if (postError != null) {
          return http.Response(
            jsonEncode({
              'error': {'code': 400, 'message': postError},
            }),
            400,
          );
        }
        return http.Response(jsonEncode({'success': true}), 200);
      }
      final state = states[listed < states.length ? listed : states.length - 1];
      listed++;
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'smol',
              'status': {'value': state},
            },
          ],
        }),
        200,
      );
    });
  }

  test('waits for an asynchronous llama.cpp router load to finish', () async {
    final service = ConnectionService(
      client: llamaRouter(
        states: ['unloaded', 'unloaded', 'loading', 'loading', 'loaded'],
      ),
    );
    final connection = await service.save(
      provider: ConnectionProvider.llamaCpp,
      name: 'router',
      baseUrl: 'http://localhost:8080/v1',
      modelIds: const ['smol'],
    );
    await service.refresh(connection);
    expect(service.supportsModelControl(connection), isTrue);
    await service.loadModel(connection, 'smol');
    expect(service.modelsFor(connection).single.state, RemoteModelState.loaded);
    expect(service.isModelBusy(connection.id, 'smol'), isFalse);
  });

  test('treats loading an already-running model as success', () async {
    final service = ConnectionService(
      client: llamaRouter(
        states: ['loaded'],
        postError: 'model is already running',
      ),
    );
    final connection = await service.save(
      provider: ConnectionProvider.llamaCpp,
      name: 'router',
      baseUrl: 'http://localhost:8080/v1',
      modelIds: const ['smol'],
    );
    await service.loadModel(connection, 'smol');
    expect(service.errorFor(connection.id), isNull);
    expect(service.modelsFor(connection).single.state, RemoteModelState.loaded);
  });

  test(
    'concurrent refreshes share one request and both see fresh state',
    () async {
      var requests = 0;
      final service = ConnectionService(
        client: MockClient((request) async {
          requests++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'm'},
              ],
            }),
            200,
          );
        }),
      );
      final connection = await service.save(
        provider: ConnectionProvider.vllm,
        name: 'v',
        baseUrl: 'http://localhost:8000/v1',
        modelIds: const ['m'],
      );
      // save() already started a refresh; this call must join it, not return
      // early with stale state.
      await service.refresh(connection);
      expect(
        service.modelsFor(connection).single.state,
        RemoteModelState.available,
      );
      expect(requests, 1);
    },
  );

  test('controls Erebrus nodes through /v1/models/load', () async {
    final paths = <String>[];
    final service = ConnectionService(
      client: MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.method == 'POST') {
          return http.Response(jsonEncode({'success': true}), 200);
        }
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'bonsai',
                'status': {'value': 'loaded'},
              },
            ],
          }),
          200,
        );
      }),
    );
    final connection = await service.save(
      provider: ConnectionProvider.erebrus,
      name: 'Studio',
      baseUrl: 'http://192.168.1.4:11434/v1',
      modelIds: const ['bonsai'],
    );
    await service.loadModel(connection, 'bonsai');
    expect(paths, contains('POST /v1/models/load'));
    expect(
      service.modelsFor(service.byId(connection.id)!).single.state,
      RemoteModelState.loaded,
    );
  });

  test('resolves chat targets only for selected models', () async {
    final service = ConnectionService(
      client: MockClient((_) async => http.Response('{"data":[]}', 200)),
    );
    final connection = await service.save(
      provider: ConnectionProvider.openRouter,
      name: 'Router',
      baseUrl: 'https://openrouter.ai/api/v1',
      maxTokensLimit: 2048,
      modelIds: const ['meta/llama'],
    );
    final target = service.targetFor(connection.nodeId, 'meta/llama')!;
    expect(
      target.chatCompletionsUri.toString(),
      'https://openrouter.ai/api/v1/chat/completions',
    );
    expect(target.acceptsLlamaSampling, isFalse);
    expect(target.maxTokensLimit, 2048);
    expect(target.isConnection, isTrue);
    expect(service.targetFor(connection.nodeId, 'other'), isNull);

    await service.setEnabled(connection.id, false);
    expect(service.targetFor(connection.nodeId, 'meta/llama'), isNull);
  });

  test(
    'connection requests carry history and respect provider limits',
    () async {
      late Map<String, dynamic> payload;
      final inference = NetworkInferenceService(
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );
      final service = ConnectionService(
        client: MockClient((_) async => http.Response('{"data":[]}', 200)),
      );
      final connection = await service.save(
        provider: ConnectionProvider.vllm,
        name: 'vLLM',
        baseUrl: 'http://gpu-box:8000/v1',
        maxTokensLimit: 256,
        modelIds: const ['qwen'],
      );
      await inference
          .generate(
            target: service.targetFor(connection.nodeId, 'qwen')!,
            prompt: 'And now?',
            history: const [
              NetworkChatTurn(role: 'user', content: 'Hi'),
              NetworkChatTurn(role: 'assistant', content: 'Hello'),
            ],
            maxOutputTokens: 1024,
          )
          .join();
      final messages = payload['messages'] as List;
      expect(messages.map((message) => message['content']), [
        'Hi',
        'Hello',
        'And now?',
      ]);
      expect(payload['max_tokens'], 256);
      expect(payload.containsKey('repeat_penalty'), isFalse);
    },
  );
}
