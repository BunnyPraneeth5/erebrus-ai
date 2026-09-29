import 'dart:convert';
import 'dart:io';

import 'package:erebrus_ai/app.dart';
import 'package:erebrus_ai/auth/wallet_auth_controller.dart';
import 'package:erebrus_ai/data/catalog_service.dart';
import 'package:erebrus_ai/data/model_catalog.dart';
import 'package:erebrus_ai/data/model_connection.dart';
import 'package:erebrus_ai/org/org_state.dart';
import 'package:erebrus_ai/services/connection_service.dart';
import 'package:erebrus_ai/services/tools/web_tools.dart';
import 'package:erebrus_ai/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A local server that plays both an OpenAI-compatible model server (which
/// calls `web_search` once, then answers with a citation) and SearXNG.
Future<HttpServer> _startFakeServer(
  List<Map<String, dynamic>> chatBodies,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    if (request.uri.path == '/search') {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'results': [
            {
              'title': 'Apollo 11 - NASA',
              'url': 'https://www.nasa.gov/apollo-11',
              'content': 'Apollo 11 landed on the Moon on July 20, 1969.',
            },
          ],
        }),
      );
    } else if (request.uri.path == '/v1/models') {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'data': [
            {'id': 'tool-model'},
          ],
        }),
      );
    } else if (request.uri.path == '/v1/chat/completions') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      chatBodies.add(body);
      final messages = body['messages'] as List;
      final answered = (messages.last as Map)['role'] == 'tool';
      response.headers.set('content-type', 'text/event-stream');
      final chunks = answered
          ? [
              {'content': 'Apollo 11 landed on July 20, 1969 [1].'},
            ]
          : [
              {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'web_search',
                      'arguments': '{"query":"apollo 11 landing date"}',
                    },
                  },
                ],
              },
            ];
      for (final delta in chunks) {
        response.write(
          'data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': delta},
            ],
          })}\n\n',
        );
      }
      response.write('data: [DONE]\n\n');
    } else {
      response.statusCode = 404;
    }
    await response.close();
  });
  return server;
}

void main() {
  setUpAll(() => CatalogService.setEntries(modelCatalog));

  // Real async I/O lets plugin calls (audio, recorder, paths) reach platform
  // channels that have no native side in tests; answer them with "success"
  // (a temp dir for path lookups). Flutter's own channels pass through.
  setUp(() {
    const codec = StandardMethodCodec();
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .allMessagesHandler = (channel, handler, message) async {
      if (handler != null) return handler(message);
      if (channel.startsWith('flutter/')) return null;
      try {
        final call = codec.decodeMethodCall(message);
        if (call.method.contains('Directory')) {
          return codec.encodeSuccessEnvelope(Directory.systemTemp.path);
        }
      } on Object {
        // Not a method call (e.g. an event stream); plain success is fine.
      }
      return codec.encodeSuccessEnvelope(null);
    };
  });
  tearDown(
    () =>
        TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .allMessagesHandler =
            null,
  );

  testWidgets('web search runs through the chat UI end to end', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'default_model_id': 'smollm2-135m-instruct',
      'default_model_variant_id': 'smollm2-135m-instruct-gguf-q8_0',
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Real sockets, but only to the local fake server: anything else (the
    // app's background gateway/catalog calls) fails at once, keeping the
    // test hermetic and free of network timeouts.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _LoopbackOnlyHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final chatBodies = <Map<String, dynamic>>[];
    final server = (await tester.runAsync(() => _startFakeServer(chatBodies)))!;
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';

    final auth = WalletAuthController();
    await tester.pumpWidget(
      ErebrusApp(
        auth: auth,
        orgState: OrgState(auth: auth),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.runAsync(() async {
      final connection = await ConnectionService.instance.save(
        provider: ConnectionProvider.custom,
        name: 'Tool server',
        baseUrl: '$base/v1',
        modelIds: const ['tool-model'],
      );
      await WebTools.instance.setEnabled(true);
      await WebTools.instance.setProvider(SearchProvider.searxng);
      await WebTools.instance.setSearxngUrl(base);
      AppScope.of(
        tester.element(find.text('CHAT')),
      ).selectConnectionModel(connection, 'tool-model');
    });
    await tester.pump(const Duration(milliseconds: 200));

    // Turn web search on for this chat with the composer's globe.
    await tester.tap(find.byTooltip('Search the web'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('Web search on for this chat'), findsOneWidget);
    expect(find.textContaining('WEB SEARCH VIA SEARXNG'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      'When did Apollo 11 land?',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);

    // Let real network I/O run until the answer arrives.
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      if (find.textContaining('July 20, 1969 [1]').evaluate().isNotEmpty &&
          find.text('nasa.gov').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.textContaining('July 20, 1969 [1]'), findsOneWidget);
    expect(
      find.textContaining('Searched the web for “apollo 11 landing date”'),
      findsOneWidget,
    );
    expect(find.text('nasa.gov'), findsOneWidget); // numbered source chip
    expect(chatBodies, hasLength(2));
    expect(chatBodies.first['tools'], isNotNull);
    final replayed = chatBodies.last['messages'] as List;
    expect((replayed.last as Map)['content'], contains('July 20, 1969'));
    expect(tester.takeException(), isNull);

    // Let tooltip and animation timers finish before teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}

class _LoopbackOnlyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Pooled keep-alive connections hold a 15 s idle timer, which fake-time
    // tests report as pending; close idle connections almost at once.
    final client = super.createHttpClient(context)
      ..idleTimeout = const Duration(milliseconds: 1);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != InternetAddress.loopbackIPv4.address) {
        return Future.error(SocketException('Blocked in test: ${uri.host}'));
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }
}
