import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_config.dart';
import '../platform/platform_capabilities.dart';
import 'runtime_config.dart';

/// Parsed `erebrusai://auth` callback from the Erebrus webapp.
class DesktopAuthCallback {
  const DesktopAuthCallback({
    required this.token,
    required this.userId,
    required this.walletAddress,
    required this.role,
    required this.state,
  });

  final String token;
  final String userId;
  final String walletAddress;
  final String role;
  final String state;

  bool get isValid =>
      token.isNotEmpty &&
      userId.isNotEmpty &&
      walletAddress.isNotEmpty &&
      state.isNotEmpty;
}

/// Browser-based sign-in for macOS / Windows / Linux.
class DesktopWebAuth {
  DesktopWebAuth._();

  static String? _pendingState;

  // The anti-forgery state is also persisted: on phones the OS may kill the
  // app while the browser is in front, which would otherwise lose it and
  // reject a valid callback. It expires so a stale state can't be replayed.
  static const _stateKey = 'web_auth_pending_state';
  static const _stateTimeKey = 'web_auth_pending_state_at';
  static const _stateLifetime = Duration(minutes: 15);

  static String? get pendingState => _pendingState;

  static bool isAuthCallback(String url) {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == kErebrusAuthCallbackScheme &&
        (uri.host == kErebrusAuthCallbackHost || uri.path.startsWith('/auth'));
  }

  static String buildLoginUrl() {
    final state = _newState();
    _pendingState = state;
    unawaited(_persistState(state));
    return Uri.parse(
          '${RuntimeConfig.erebrusWebOrigin}$kErebrusDesktopAuthPath',
        )
        .replace(
          queryParameters: {
            'redirect_uri': kErebrusAuthCallback,
            'state': state,
            'platform': PlatformCapabilities.platformLabel,
            'client_id': kErebrusBundleId,
          },
        )
        .toString();
  }

  /// Parses pasted text: full `erebrusai://auth?…` URL, query string, or raw PASETO.
  static DesktopAuthCallback? parseManualAuthInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.contains('://') ||
        trimmed.contains('token=') ||
        trimmed.contains('paseto=')) {
      var url = trimmed;
      if (!trimmed.contains('://')) {
        url =
            '$kErebrusAuthCallback${trimmed.startsWith('?') ? trimmed : '?$trimmed'}';
      }
      final parsed = parseCallback(url);
      if (parsed != null && parsed.token.isNotEmpty) return parsed;
    }

    if (trimmed.startsWith('v4.')) {
      return DesktopAuthCallback(
        token: trimmed,
        userId: '',
        walletAddress: '',
        role: 'user',
        state: '',
      );
    }

    return null;
  }

  static DesktopAuthCallback? parseCallback(String url) {
    if (!isAuthCallback(url)) return null;
    final uri = Uri.parse(url);
    final params = {...uri.queryParameters, ..._fragmentParams(uri)};

    final error = params['error'] ?? params['error_description'];
    if (error != null && error.isNotEmpty) {
      throw DesktopWebAuthException(error);
    }

    final token = params['token'] ?? params['paseto'] ?? '';
    final userId = params['user_id'] ?? params['userId'] ?? '';
    final wallet =
        params['wallet'] ??
        params['wallet_address'] ??
        params['public_key'] ??
        '';
    final role = params['role'] ?? 'user';
    final state = params['state'] ?? '';

    if (token.isEmpty) return null;

    return DesktopAuthCallback(
      token: token,
      userId: userId,
      walletAddress: wallet,
      role: role,
      state: state,
    );
  }

  static void clearPendingState() {
    _pendingState = null;
    unawaited(_persistState(null));
  }

  static Future<void> validateState(String state) async {
    final expected = _pendingState ?? await _restoreState();
    if (expected == null || expected.isEmpty || state != expected) {
      throw DesktopWebAuthException('Sign-in state mismatch — try again');
    }
  }

  static Future<void> _persistState(String? state) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (state == null) {
        await preferences.remove(_stateKey);
        await preferences.remove(_stateTimeKey);
      } else {
        await preferences.setString(_stateKey, state);
        await preferences.setInt(
          _stateTimeKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      debugPrint('[Auth] web sign-in state persist failed: $e');
    }
  }

  static Future<String?> _restoreState() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final state = preferences.getString(_stateKey);
      final at = preferences.getInt(_stateTimeKey);
      if (state == null || at == null) return null;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(at),
      );
      return age <= _stateLifetime ? state : null;
    } catch (e) {
      debugPrint('[Auth] web sign-in state restore failed: $e');
      return null;
    }
  }

  static Map<String, String> _fragmentParams(Uri uri) {
    if (uri.fragment.isEmpty) return const {};
    return Uri.splitQueryString(uri.fragment);
  }

  static String _newState() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

class DesktopWebAuthException implements Exception {
  DesktopWebAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
