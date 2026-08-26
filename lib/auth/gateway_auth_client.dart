import 'dart:convert';
import 'dart:io';

import 'auth_config.dart';
import 'entitlement_state.dart';
import 'runtime_config.dart';
import 'user_org_invite.dart';
import 'user_profile.dart';

/// Default Erebrus gateway for local / dev testing.
const kDefaultGatewayUrl = 'https://gateway.erebrus.io';

/// Wallet auth + account data against the Erebrus gateway (v2).
class GatewayAuthClient {
  GatewayAuthClient({String? gatewayUrl, this.onUnauthorized})
    : _base = _normalizeBase(gatewayUrl ?? RuntimeConfig.gatewayUrl);

  final String _base;
  Future<void> Function(String bearerToken)? onUnauthorized;

  /// Start wallet login — `GET /api/v2/auth`.
  Future<AuthChallenge> fetchFlowId({
    required String walletAddress,
    String chain = kSolanaChain,
  }) async {
    final uri = Uri.parse('$_base/api/v2/auth').replace(
      queryParameters: {'wallet_address': walletAddress, 'chain': chain},
    );
    final map = await _getJson(uri);
    return AuthChallenge(
      flowId: (map['flow_id'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
    );
  }

  /// Complete wallet login — `POST /api/v2/auth`.
  Future<AuthSession> authenticate({
    required String flowId,
    required String signature,
    required String publicKey,
  }) async {
    final map = await _postJson(Uri.parse('$_base/api/v2/auth'), {
      'flow_id': flowId,
      'signature': signature,
      'public_key': publicKey,
    });
    return AuthSession(
      token: (map['token'] ?? '').toString(),
      userId: (map['user_id'] ?? '').toString(),
      role: (map['role'] ?? 'user').toString(),
      walletAddress: publicKey,
    );
  }

  /// `GET /api/v2/subscriptions` — requires bearer token.
  Future<EntitlementState> fetchSubscription(String bearerToken) async {
    final map = await _getJson(
      Uri.parse('$_base/api/v2/subscriptions'),
      bearerToken: bearerToken,
    );
    return EntitlementState.fromJson(map);
  }

  /// `POST /api/v2/subscriptions/trial` — one-time free trial.
  Future<EntitlementState> startTrial(String bearerToken) async {
    final map = await _postJson(
      Uri.parse('$_base/api/v2/subscriptions/trial'),
      const {},
      bearerToken: bearerToken,
    );
    return EntitlementState.fromJson({
      'entitled': true,
      'status': map['status'],
      'plan_id': map['plan_id'],
      'source': map['source'] ?? 'trial',
      'current_period_end': map['current_period_end'],
    });
  }

  /// `GET /api/v2/account/profile`.
  Future<UserProfile> fetchProfile(String bearerToken) async {
    final map = await _getJson(
      Uri.parse('$_base/api/v2/account/profile'),
      bearerToken: bearerToken,
    );
    return UserProfile.fromJson(map);
  }

  /// `GET /api/v2/account/org-invites`.
  Future<List<UserOrgInvite>> fetchAccountOrgInvites(String bearerToken) async {
    final decoded = await _getJson(
      Uri.parse('$_base/api/v2/account/org-invites'),
      bearerToken: bearerToken,
    );
    final list = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['invites'] as List?) : null) ?? const [];
    return list
        .map((e) => UserOrgInvite.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// `POST /api/v2/account/org-invites/{id}/accept`.
  Future<void> acceptAccountOrgInvite(
    String inviteId,
    String bearerToken,
  ) async {
    await _postJson(
      Uri.parse('$_base/api/v2/account/org-invites/$inviteId/accept'),
      const {},
      bearerToken: bearerToken,
    );
  }

  /// `POST /api/v2/account/org-invites/{id}/decline`.
  Future<void> declineAccountOrgInvite(
    String inviteId,
    String bearerToken,
  ) async {
    await _postJson(
      Uri.parse('$_base/api/v2/account/org-invites/$inviteId/decline'),
      const {},
      bearerToken: bearerToken,
    );
  }

  /// `POST /api/v2/orgs`.
  Future<Map<String, dynamic>> createOrg({
    required String name,
    required String slug,
    required String bearerToken,
  }) async {
    return await _postJson(Uri.parse('$_base/api/v2/orgs'), {
      'name': name,
      'slug': slug,
    }, bearerToken: bearerToken);
  }

  /// `POST /api/v2/referrals/redeem` — apply a referral / invite code after
  /// signup. Binds the caller's referrer (one per account, ever); once the
  /// caller has an active org membership, XP is awarded to both parties on the
  /// gateway. Returns the updated referral summary. Requires a bearer token.
  Future<ReferralSummary> redeemReferralCode({
    required String code,
    required String bearerToken,
  }) async {
    final map = await _postJson(
      Uri.parse('$_base/api/v2/referrals/redeem'),
      {'code': code.trim().toUpperCase()},
      bearerToken: bearerToken,
    );
    return ReferralSummary.fromJson(map);
  }

  /// `GET /api/v2/referrals/me` — the caller's referral code, referrer, and
  /// recent referees.
  Future<ReferralSummary> fetchReferralSummary(String bearerToken) async {
    final map = await _getJson(
      Uri.parse('$_base/api/v2/referrals/me'),
      bearerToken: bearerToken,
    );
    return ReferralSummary.fromJson(Map<String, dynamic>.from(map as Map));
  }

  /// `GET /api/v2/rank/me` — the caller's XP standing. Lifetime XP is
  /// `xp_earned`; the account profile does not carry XP.
  Future<RankStanding> fetchRank(String bearerToken) async {
    final map = await _getJson(
      Uri.parse('$_base/api/v2/rank/me'),
      bearerToken: bearerToken,
    );
    return RankStanding.fromJson(Map<String, dynamic>.from(map as Map));
  }

  Future<void> emailLoginStart(String email) async {
    await _postJson(Uri.parse('$_base/api/v2/auth/email/login/start'), {
      'email': email.trim().toLowerCase(),
      'app': 'Erebrus AI',
    });
  }

  Future<AuthSession> emailLoginVerify({
    required String email,
    required String code,
  }) async {
    final map = await _postJson(
      Uri.parse('$_base/api/v2/auth/email/login/verify'),
      {
        'email': email.trim().toLowerCase(),
        'code': code.replaceAll(RegExp(r'\D'), ''),
      },
    );
    return _identitySession(map);
  }

  Future<AuthSession> googleLogin(String idToken) async {
    final map = await _postJson(Uri.parse('$_base/api/v2/auth/google'), {
      'id_token': idToken,
    });
    return _identitySession(map);
  }

  Future<AuthSession> appleLogin({
    required String idToken,
    required String authorizationCode,
    required String nonce,
    required String state,
  }) async {
    final map = await _postJson(Uri.parse('$_base/api/v2/auth/apple'), {
      'id_token': idToken,
      'authorization_code': authorizationCode,
      'nonce': nonce,
      'state': state,
    });
    return _identitySession(map);
  }

  AuthSession _identitySession(Map<String, dynamic> map) => AuthSession(
    token: (map['token'] ?? '').toString(),
    userId: (map['user_id'] ?? '').toString(),
    role: (map['role'] ?? 'user').toString(),
    walletAddress:
        (map['wallet_address'] ?? map['wallet'] ?? map['public_key'] ?? '')
            .toString(),
  );

  /// `GET /api/v2/auth/methods` — which login methods the gateway has configured.
  Future<AuthMethods> fetchAuthMethods() async {
    try {
      final map = await _getJson(Uri.parse('$_base/api/v2/auth/methods'));
      return AuthMethods(
        email: map['email'] == true,
        google: map['google'] == true,
        apple: map['apple'] == true,
        wallet: map['wallet'] == true,
      );
    } catch (_) {
      return AuthMethods.unknown;
    }
  }

  Future<dynamic> _getJson(Uri uri, {String? bearerToken}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (bearerToken != null && bearerToken.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final error = _apiError(res.statusCode, text);
        if (res.statusCode == HttpStatus.unauthorized &&
            bearerToken != null &&
            bearerToken.isNotEmpty) {
          await onUnauthorized?.call(bearerToken);
        }
        throw AuthException(
          error.message,
          statusCode: res.statusCode,
          code: error.code,
        );
      }
      return jsonDecode(text);
    } on SocketException catch (e) {
      throw AuthException('Cannot reach gateway ($_base): ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (bearerToken != null && bearerToken.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
      }
      final encoded = jsonEncode(body);
      req.contentLength = utf8.encode(encoded).length;
      req.write(encoded);
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final error = _apiError(res.statusCode, text);
        if (res.statusCode == HttpStatus.unauthorized &&
            bearerToken != null &&
            bearerToken.isNotEmpty) {
          await onUnauthorized?.call(bearerToken);
        }
        throw AuthException(
          error.message,
          statusCode: res.statusCode,
          code: error.code,
        );
      }
      if (text.isEmpty) return const {};
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return const {};
    } on SocketException catch (e) {
      throw AuthException('Cannot reach gateway ($_base): ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  static _ApiError _apiError(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final rawError = j['error'];
        final msg = rawError is Map
            ? rawError['message'] ?? j['message'] ?? j['detail']
            : rawError ?? j['message'] ?? j['detail'];
        final code = rawError is Map
            ? rawError['code'] ?? j['code'] ?? j['error_code']
            : j['code'] ?? j['error_code'];
        if (msg != null) {
          return _ApiError(msg.toString(), code?.toString());
        }
        return _ApiError('Gateway error ($status)', code?.toString());
      }
    } catch (_) {}
    return _ApiError('Gateway error ($status)', null);
  }

  static String _normalizeBase(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return kDefaultGatewayUrl;
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    return withScheme.replaceAll(RegExp(r'/+$'), '');
  }
}

class AuthChallenge {
  const AuthChallenge({required this.flowId, required this.message});
  final String flowId;
  final String message;
}

class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.walletAddress,
  });
  final String token;
  final String userId;
  final String role;
  final String walletAddress;
}

/// The caller's referral standing (`GET /api/v2/referrals/me` and the response
/// of `POST /api/v2/referrals/redeem`). XP is not part of this payload — read
/// lifetime XP from [RankStanding.xpEarned] instead.
class ReferralSummary {
  const ReferralSummary({
    this.code = '',
    this.referredCount = 0,
    this.referralBound = false,
    this.referredBy,
    this.recent = const [],
  });

  /// The caller's own shareable referral code.
  final String code;

  /// How many users this caller has referred.
  final int referredCount;

  /// True once a referrer has been bound to this account (one-shot, immutable).
  final bool referralBound;

  /// Truncated wallet of whoever referred the caller, when bound.
  final String? referredBy;

  /// Most recent referees (wallets truncated by the gateway).
  final List<ReferralReferee> recent;

  factory ReferralSummary.fromJson(Map<String, dynamic> j) {
    final recentRaw = j['recent'];
    return ReferralSummary(
      code: (j['code'] ?? '').toString(),
      referredCount: j['referred_count'] is int ? j['referred_count'] as int : 0,
      referralBound: j['referral_bound'] == true,
      referredBy: (j['referred_by'] as String?)?.trim().isNotEmpty == true
          ? j['referred_by'] as String
          : null,
      recent: recentRaw is List
          ? recentRaw
                .whereType<Map>()
                .map((e) => ReferralReferee.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }
}

/// One recent referee inside a [ReferralSummary].
class ReferralReferee {
  const ReferralReferee({
    this.wallet = '',
    this.qualified = false,
    this.joinedAt,
  });

  final String wallet;
  final bool qualified;
  final DateTime? joinedAt;

  factory ReferralReferee.fromJson(Map<String, dynamic> j) => ReferralReferee(
    wallet: (j['wallet'] ?? '').toString(),
    qualified: j['qualified'] == true,
    joinedAt: DateTime.tryParse((j['joined_at'] ?? '').toString())?.toUtc(),
  );
}

/// The caller's XP standing (`GET /api/v2/rank/me`). Lifetime XP is [xpEarned].
class RankStanding {
  const RankStanding({
    this.xpEarned = 0,
    this.xpClaimed = 0,
    this.xpClaimable = 0,
    this.tier = 0,
    this.tierName,
    this.nextTierAt,
  });

  final int xpEarned;
  final int xpClaimed;
  final int xpClaimable;
  final int tier;
  final String? tierName;
  final int? nextTierAt;

  static const zero = RankStanding();

  factory RankStanding.fromJson(Map<String, dynamic> j) => RankStanding(
    xpEarned: _asInt(j['xp_earned']),
    xpClaimed: _asInt(j['xp_claimed']),
    xpClaimable: _asInt(j['xp_claimable']),
    tier: _asInt(j['tier']),
    tierName: j['tier_name']?.toString(),
    nextTierAt: j['next_tier_at'] == null ? null : _asInt(j['next_tier_at']),
  );

  static int _asInt(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0);
}

class AuthException implements Exception {
  AuthException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;
  String? get errorCode => code;

  @override
  String toString() => message;
}

class _ApiError {
  const _ApiError(this.message, this.code);
  final String message;
  final String? code;
}

/// Which login methods the gateway has configured.
class AuthMethods {
  const AuthMethods({
    required this.email,
    required this.google,
    required this.apple,
    required this.wallet,
  });

  final bool email;
  final bool google;
  final bool apple;
  final bool wallet;

  static const unknown = AuthMethods(
    email: true,
    google: true,
    apple: true,
    wallet: true,
  );
}
