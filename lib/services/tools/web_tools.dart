import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../platform/secure_storage.dart';

/// Where `web_search` sends queries.
enum SearchProvider {
  searxng(
    'SearXNG',
    'Self-hosted metasearch. No API key; queries go to a server you control.',
    requiresKey: false,
  ),
  brave(
    'Brave Search',
    'Brave Search API. Needs a subscription token from api-dashboard.search.brave.com.',
    requiresKey: true,
  ),
  tavily(
    'Tavily',
    'Search API built for AI agents. Needs an API key from app.tavily.com.',
    requiresKey: true,
  );

  const SearchProvider(
    this.label,
    this.description, {
    required this.requiresKey,
  });

  final String label;
  final String description;
  final bool requiresKey;
}

class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    if (snippet.isNotEmpty) 'snippet': snippet,
  };
}

class FetchedPage {
  const FetchedPage({
    required this.url,
    required this.title,
    required this.text,
    required this.truncated,
  });

  final String url;
  final String title;
  final String text;
  final bool truncated;
}

class WebToolException implements Exception {
  const WebToolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Settings and execution for the built-in internet tools (Settings → Tools).
///
/// Web access is off until the user enables it and configures a provider.
/// Keys live in secure storage only.
class WebTools extends ChangeNotifier {
  WebTools({http.Client? client, InternetAddressLookup? lookup})
    : _client = client ?? http.Client(),
      _lookup = lookup ?? InternetAddress.lookup;

  static final WebTools instance = WebTools();

  static const _enabledKey = 'tools_web_enabled';
  static const _providerKey = 'tools_web_provider';
  static const _searxngKey = 'tools_web_searxng_url';
  static const _maxResultsKey = 'tools_web_max_results';
  static const _fetchKey = 'tools_web_allow_fetch';
  static String _secretKey(SearchProvider provider) =>
      'tools_web_key_${provider.name}';

  static const _timeout = Duration(seconds: 15);
  static const _maxPageBytes = 2 * 1024 * 1024;
  static const _redirectStatuses = {301, 302, 303, 307, 308};

  /// Page text handed to the model; longer pages are cut to fit its context.
  static const maxPageChars = 8000;

  final http.Client _client;
  final InternetAddressLookup _lookup;

  bool _enabled = false;
  SearchProvider _provider = SearchProvider.searxng;
  String _searxngUrl = '';
  int _maxResults = 5;
  bool _allowFetch = true;
  final Map<SearchProvider, String> _keys = {};

  bool get enabled => _enabled;
  SearchProvider get provider => _provider;
  String get searxngUrl => _searxngUrl;
  int get maxResults => _maxResults;
  bool get allowFetch => _allowFetch;
  bool hasKey(SearchProvider provider) =>
      (_keys[provider] ?? '').trim().isNotEmpty;

  /// Why search can't run yet, or null when it is ready.
  String? get configurationProblem {
    switch (_provider) {
      case SearchProvider.searxng:
        if (_searxngUrl.trim().isEmpty) return 'Enter your SearXNG server URL';
      case SearchProvider.brave:
      case SearchProvider.tavily:
        if (!hasKey(_provider)) return 'Add your ${_provider.label} API key';
    }
    return null;
  }

  /// Enabled and fully configured: tools can be offered to models.
  bool get isReady => _enabled && configurationProblem == null;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _enabled = preferences.getBool(_enabledKey) ?? false;
      _provider =
          SearchProvider.values
              .where(
                (value) => value.name == preferences.getString(_providerKey),
              )
              .firstOrNull ??
          SearchProvider.searxng;
      _searxngUrl = preferences.getString(_searxngKey) ?? '';
      _maxResults = (preferences.getInt(_maxResultsKey) ?? 5).clamp(1, 10);
      _allowFetch = preferences.getBool(_fetchKey) ?? true;
      for (final provider in SearchProvider.values.where(
        (p) => p.requiresKey,
      )) {
        try {
          final key = await ErebrusSecureStorage.instance.read(
            key: _secretKey(provider),
          );
          if (key != null && key.isNotEmpty) _keys[provider] = key;
        } on Object catch (error) {
          debugPrint('[WebTools] key read failed: $error');
        }
      }
    } on Object catch (error) {
      debugPrint('[WebTools] load failed: $error');
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
  }

  Future<void> setProvider(SearchProvider value) async {
    _provider = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _providerKey,
      value.name,
    );
  }

  Future<void> setSearxngUrl(String value) async {
    _searxngUrl = value.trim().replaceAll(RegExp(r'/+$'), '');
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _searxngKey,
      _searxngUrl,
    );
  }

  Future<void> setMaxResults(int value) async {
    _maxResults = value.clamp(1, 10);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _maxResultsKey,
      _maxResults,
    );
  }

  Future<void> setAllowFetch(bool value) async {
    _allowFetch = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_fetchKey, value);
  }

  /// Stores (or with an empty [value], removes) a provider's API key.
  Future<void> setApiKey(SearchProvider provider, String value) async {
    final key = value.trim();
    if (key.isEmpty) {
      _keys.remove(provider);
      await ErebrusSecureStorage.instance.delete(key: _secretKey(provider));
    } else {
      _keys[provider] = key;
      await ErebrusSecureStorage.instance.write(
        key: _secretKey(provider),
        value: key,
      );
    }
    notifyListeners();
  }

  // ─── Search ──────────────────────────────────────────────────────────────

  Future<List<WebSearchResult>> search(String query, {int? count}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const WebToolException('The search query is empty');
    }
    final problem = configurationProblem;
    if (problem != null) throw WebToolException(problem);
    final limit = (count ?? _maxResults).clamp(1, 10);
    try {
      final results = switch (_provider) {
        SearchProvider.searxng => await _searxng(trimmed),
        SearchProvider.brave => await _brave(trimmed, limit),
        SearchProvider.tavily => await _tavily(trimmed, limit),
      };
      return results.take(limit).toList();
    } on WebToolException {
      rethrow;
    } on TimeoutException {
      throw WebToolException('${_provider.label} did not respond in time');
    } on Object catch (error) {
      throw WebToolException('${_provider.label} search failed: $error');
    }
  }

  Future<List<WebSearchResult>> _searxng(String query) async {
    final base = Uri.parse(
      _searxngUrl.contains('://') ? _searxngUrl : 'https://$_searxngUrl',
    );
    final uri = base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'search',
      ],
      queryParameters: {'q': query, 'format': 'json'},
    );
    final response = await _client
        .get(uri, headers: {'accept': 'application/json'})
        .timeout(_timeout);
    if (response.statusCode == 403) {
      throw const WebToolException(
        'SearXNG refused JSON results. Add "json" under search.formats in its settings.yml.',
      );
    }
    final body = _decodeOk(response, 'SearXNG');
    final results = body is Map ? body['results'] : null;
    return [
      for (final item in (results as List? ?? const []).whereType<Map>())
        if ((item['url'] ?? '').toString().isNotEmpty)
          WebSearchResult(
            title: (item['title'] ?? item['url']).toString(),
            url: item['url'].toString(),
            snippet: (item['content'] ?? '').toString(),
          ),
    ];
  }

  Future<List<WebSearchResult>> _brave(String query, int count) async {
    final uri = Uri.https('api.search.brave.com', '/res/v1/web/search', {
      'q': query,
      'count': '$count',
    });
    final response = await _client
        .get(
          uri,
          headers: {
            'accept': 'application/json',
            'x-subscription-token': _keys[SearchProvider.brave] ?? '',
          },
        )
        .timeout(_timeout);
    final body = _decodeOk(response, 'Brave Search');
    final web = body is Map ? body['web'] : null;
    final results = web is Map ? web['results'] : null;
    return [
      for (final item in (results as List? ?? const []).whereType<Map>())
        if ((item['url'] ?? '').toString().isNotEmpty)
          WebSearchResult(
            title: _stripTags((item['title'] ?? item['url']).toString()),
            url: item['url'].toString(),
            snippet: _stripTags((item['description'] ?? '').toString()),
          ),
    ];
  }

  Future<List<WebSearchResult>> _tavily(String query, int count) async {
    final key = _keys[SearchProvider.tavily] ?? '';
    final response = await _client
        .post(
          Uri.https('api.tavily.com', '/search'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'query': query,
            'max_results': count,
            'search_depth': 'basic',
          }),
        )
        .timeout(_timeout);
    final body = _decodeOk(response, 'Tavily');
    final results = body is Map ? body['results'] : null;
    return [
      for (final item in (results as List? ?? const []).whereType<Map>())
        if ((item['url'] ?? '').toString().isNotEmpty)
          WebSearchResult(
            title: (item['title'] ?? item['url']).toString(),
            url: item['url'].toString(),
            snippet: (item['content'] ?? '').toString(),
          ),
    ];
  }

  Object? _decodeOk(http.Response response, String service) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw WebToolException('$service rejected the API key');
    }
    if (response.statusCode == 429) {
      throw WebToolException('$service rate limit reached — try again later');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebToolException('$service returned HTTP ${response.statusCode}');
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw WebToolException('$service returned a non-JSON response');
    }
  }

  // ─── Fetch ───────────────────────────────────────────────────────────────

  /// Downloads a public web page and returns its readable text.
  ///
  /// Only public http(s) hosts are allowed: loopback, private, link-local
  /// and similar ranges are refused so a model can't be steered into probing
  /// this device or its local network.
  Future<FetchedPage> fetchPage(String rawUrl) async {
    if (!_allowFetch) {
      throw const WebToolException(
        'Opening web pages is turned off in Settings → Tools',
      );
    }
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      throw WebToolException('Not a web address: $rawUrl');
    }
    await _assertPublicHost(uri.host);

    const headers = {
      'accept': 'text/html,text/plain;q=0.9,*/*;q=0.5',
      'user-agent': 'ErebrusAI/1.0 (+https://erebrus.io)',
    };
    var current = uri;
    var redirects = 0;
    http.StreamedResponse response;
    while (true) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      response = await _client.send(request).timeout(_timeout);
      final location = response.headers['location'];
      if (!_redirectStatuses.contains(response.statusCode) ||
          location == null) {
        break;
      }
      await response.stream.drain<void>();
      if (++redirects > 5) {
        throw const WebToolException('The page redirected too many times');
      }
      current = current.resolve(location);
      if (!(current.scheme == 'https' || current.scheme == 'http')) {
        throw const WebToolException(
          'The page redirected to a non-web address',
        );
      }
      // Re-check every hop: a public page may redirect to a private one.
      await _assertPublicHost(current.host);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw WebToolException('The page returned HTTP ${response.statusCode}');
    }
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (type.isNotEmpty &&
        !type.contains('html') &&
        !type.contains('text') &&
        !type.contains('xml') &&
        !type.contains('json')) {
      await response.stream.drain<void>();
      throw WebToolException('Unsupported content type: $type');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxPageBytes) break;
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    final (
      title,
      text,
    ) = type.contains('html') || raw.trimLeft().startsWith('<')
        ? extractReadableText(raw)
        : ('', raw.replaceAll(RegExp(r'\s+'), ' ').trim());
    final truncated = text.length > maxPageChars;
    return FetchedPage(
      url: current.toString(),
      title: title,
      text: truncated ? '${text.substring(0, maxPageChars)}…' : text,
      truncated: truncated,
    );
  }

  Future<void> _assertPublicHost(String host) async {
    final literal = InternetAddress.tryParse(host);
    final addresses = literal != null
        ? [literal]
        : await _lookup(host).timeout(_timeout);
    if (addresses.isEmpty) throw WebToolException('Could not resolve $host');
    for (final address in addresses) {
      if (!isPublicAddress(address)) {
        throw WebToolException(
          'Refusing to open $host: it points to a private or local address',
        );
      }
    }
  }

  static String _stripTags(String value) =>
      value.replaceAll(RegExp(r'<[^>]+>'), '');
}

typedef InternetAddressLookup =
    Future<List<InternetAddress>> Function(String host);

/// False for loopback, private, link-local, CGNAT, multicast, and other
/// non-public ranges (IPv4 and IPv6, including IPv4-mapped IPv6).
@visibleForTesting
bool isPublicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv6) {
    // IPv4-mapped (::ffff:a.b.c.d)
    final mapped =
        bytes.sublist(0, 10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (mapped) {
      return isPublicAddress(InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    if (bytes.every((b) => b == 0)) return false; // ::
    if ((bytes[0] & 0xfe) == 0xfc) return false; // fc00::/7 unique local
    return true;
  }
  final a = bytes[0], b = bytes[1];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 169 && b == 254) return false; // link-local
  if (a == 172 && b >= 16 && b <= 31) return false;
  if (a == 192 && b == 168) return false;
  if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
  if (a == 192 && b == 0 && bytes[2] == 0) return false;
  if (a == 198 && (b == 18 || b == 19)) return false; // benchmarking
  if (a >= 224) return false; // multicast + reserved + broadcast
  return true;
}

/// Title and readable body text of an HTML document: scripts, styles,
/// navigation and other chrome removed, whitespace collapsed.
@visibleForTesting
(String, String) extractReadableText(String source) {
  final document = html_parser.parse(source);
  final title = document.querySelector('title')?.text.trim() ?? '';
  for (final selector in const [
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'nav',
    'footer',
    'header',
    'aside',
    'form',
    'iframe',
  ]) {
    for (final element in document.querySelectorAll(selector)) {
      element.remove();
    }
  }
  final root =
      document.querySelector('main') ??
      document.querySelector('article') ??
      document.body;
  if (root == null) return (title, '');
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is dom.Element) {
      const blocks = {
        'p', 'div', 'section', 'li', 'tr', 'br', 'h1', 'h2', 'h3', 'h4', //
        'h5', 'h6', 'pre', 'blockquote', 'table', 'ul', 'ol',
      };
      final block = blocks.contains(node.localName);
      if (block) buffer.write('\n');
      for (final child in node.nodes) {
        walk(child);
      }
      if (block) buffer.write('\n');
    }
  }

  walk(root);
  final text = buffer
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t ]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  return (title, text);
}
