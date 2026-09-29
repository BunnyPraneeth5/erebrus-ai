import 'dart:convert';
import 'dart:io';

import 'package:erebrus_ai/services/tools/agent_tools.dart';
import 'package:erebrus_ai/services/tools/web_tools.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory stand-in for the keychain plugin.
  final keychain = <String, String>{};
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keychain.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?)?.cast<String, Object?>();
            final key = args?['key'] as String?;
            switch (call.method) {
              case 'write':
                keychain[key!] = args!['value']! as String;
              case 'read':
                return keychain[key];
              case 'delete':
                keychain.remove(key);
            }
            return null;
          },
        );
  });

  Future<List<InternetAddress>> publicLookup(String host) async => [
    InternetAddress('93.184.216.34'),
  ];

  group('isPublicAddress', () {
    for (final address in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.10',
      '169.254.169.254',
      '100.64.0.1',
      '0.0.0.0',
      '224.0.0.1',
      '::1',
      'fe80::1',
      'fd00::1',
      '::ffff:192.168.0.1',
    ]) {
      test('blocks $address', () {
        expect(isPublicAddress(InternetAddress(address)), isFalse);
      });
    }
    for (final address in ['93.184.216.34', '1.1.1.1', '2606:4700::1111']) {
      test('allows $address', () {
        expect(isPublicAddress(InternetAddress(address)), isTrue);
      });
    }
  });

  test('extracts readable text and drops page chrome', () {
    final (title, text) = extractReadableText('''
      <html><head><title> Moon landing </title><style>p{}</style></head>
      <body><nav>Home | About</nav>
      <main><h1>Apollo 11</h1><p>Landed in <b>1969</b>.</p>
      <script>alert('x')</script><ul><li>Armstrong</li><li>Aldrin</li></ul></main>
      <footer>Copyright</footer></body></html>
    ''');
    expect(title, 'Moon landing');
    expect(text, 'Apollo 11\nLanded in 1969.\nArmstrong\nAldrin');
  });

  group('search providers', () {
    test('SearXNG asks for JSON and maps results', () async {
      late http.Request seen;
      final tools = WebTools(
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Erebrus',
                  'url': 'https://erebrus.io',
                  'content': 'Private AI',
                },
              ],
            }),
            200,
          );
        }),
      );
      await tools.setSearxngUrl('https://search.example.com/');
      final results = await tools.search('erebrus');
      expect(
        seen.url.toString(),
        startsWith('https://search.example.com/search?'),
      );
      expect(seen.url.queryParameters, {'q': 'erebrus', 'format': 'json'});
      expect(results.single.title, 'Erebrus');
      expect(results.single.snippet, 'Private AI');
    });

    test('SearXNG without JSON output explains the fix', () async {
      final tools = WebTools(
        client: MockClient((_) async => http.Response('Forbidden', 403)),
      );
      await tools.setSearxngUrl('https://search.example.com');
      await expectLater(
        tools.search('x'),
        throwsA(
          isA<WebToolException>().having(
            (e) => e.message,
            'message',
            contains('settings.yml'),
          ),
        ),
      );
    });

    test('Brave sends the subscription token and strips markup', () async {
      late http.Request seen;
      final tools = WebTools(
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'web': {
                'results': [
                  {
                    'title': '<strong>Brave</strong> result',
                    'url': 'https://brave.com',
                    'description': 'A <strong>fast</strong> browser',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      await tools.setProvider(SearchProvider.brave);
      await tools.setApiKey(SearchProvider.brave, 'BSA-token');
      final results = await tools.search('brave', count: 3);
      expect(seen.url.host, 'api.search.brave.com');
      expect(seen.url.queryParameters['count'], '3');
      expect(seen.headers['x-subscription-token'], 'BSA-token');
      expect(results.single.title, 'Brave result');
      expect(results.single.snippet, 'A fast browser');
    });

    test('Tavily posts the query with a bearer key', () async {
      late http.Request seen;
      final tools = WebTools(
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'results': [
                {'title': 'T', 'url': 'https://t.example', 'content': 'c'},
              ],
            }),
            200,
          );
        }),
      );
      await tools.setProvider(SearchProvider.tavily);
      await tools.setApiKey(SearchProvider.tavily, 'tvly-abc');
      await tools.search('news', count: 4);
      expect(seen.method, 'POST');
      expect(seen.headers['authorization'], 'Bearer tvly-abc');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['query'], 'news');
      expect(body['max_results'], 4);
    });

    test('rejected keys and missing configuration are reported', () async {
      final tools = WebTools(
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      await tools.setProvider(SearchProvider.tavily);
      expect(tools.configurationProblem, 'Add your Tavily API key');
      await tools.setEnabled(true);
      expect(tools.isReady, isFalse);
      await tools.setApiKey(SearchProvider.tavily, 'bad');
      expect(tools.isReady, isTrue);
      await expectLater(
        tools.search('x'),
        throwsA(
          isA<WebToolException>().having(
            (e) => e.message,
            'message',
            'Tavily rejected the API key',
          ),
        ),
      );
    });
  });

  group('fetchPage', () {
    test('returns readable text from a public page', () async {
      final tools = WebTools(
        lookup: publicLookup,
        client: MockClient(
          (_) async => http.Response(
            '<html><title>Doc</title><body><p>Hello world</p></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      final page = await tools.fetchPage('https://example.com/doc');
      expect(page.title, 'Doc');
      expect(page.text, 'Hello world');
      expect(page.truncated, isFalse);
    });

    test('refuses hosts that resolve to private addresses', () async {
      var requested = false;
      final tools = WebTools(
        lookup: (_) async => [InternetAddress('192.168.1.1')],
        client: MockClient((_) async {
          requested = true;
          return http.Response('router admin', 200);
        }),
      );
      await expectLater(
        tools.fetchPage('http://router.example/'),
        throwsA(isA<WebToolException>()),
      );
      await expectLater(
        tools.fetchPage('http://127.0.0.1:11434/v1/models'),
        throwsA(isA<WebToolException>()),
      );
      expect(requested, isFalse);
    });

    test('re-checks the host on every redirect', () async {
      final tools = WebTools(
        lookup: (host) async => host == 'public.example'
            ? [InternetAddress('93.184.216.34')]
            : [InternetAddress('10.0.0.5')],
        client: MockClient((request) async {
          if (request.url.host == 'public.example') {
            return http.Response(
              '',
              302,
              headers: {'location': 'http://internal.example/secret'},
            );
          }
          return http.Response('secret', 200);
        }),
      );
      await expectLater(
        tools.fetchPage('https://public.example/'),
        throwsA(
          isA<WebToolException>().having(
            (e) => e.message,
            'message',
            contains('private or local'),
          ),
        ),
      );
    });

    test('can be switched off', () async {
      final tools = WebTools(lookup: publicLookup);
      await tools.setAllowFetch(false);
      await expectLater(
        tools.fetchPage('https://example.com'),
        throwsA(isA<WebToolException>()),
      );
    });
  });

  test('tools are offered only when enabled and configured', () async {
    final tools = WebTools(lookup: publicLookup);
    expect(availableAgentTools(tools), isEmpty);
    await tools.setEnabled(true);
    expect(availableAgentTools(tools), isEmpty); // no SearXNG URL yet
    await tools.setSearxngUrl('https://search.example.com');
    expect(availableAgentTools(tools).map((tool) => tool.name), [
      'web_search',
      'fetch_url',
    ]);
    await tools.setAllowFetch(false);
    expect(availableAgentTools(tools).map((tool) => tool.name), ['web_search']);
  });
}
