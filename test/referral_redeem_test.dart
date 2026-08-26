import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:erebrus_ai/auth/auth_session_store.dart';
import 'package:erebrus_ai/auth/entitlement_state.dart';
import 'package:erebrus_ai/auth/gateway_auth_client.dart';
import 'package:erebrus_ai/auth/user_org_invite.dart';
import 'package:erebrus_ai/auth/user_profile.dart';
import 'package:erebrus_ai/auth/wallet_auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GatewayAuthClient.redeemReferralCode', () {
    test('posts the upper-cased code to /referrals/redeem and parses the '
        'referral summary', () async {
      final captured = <Map<String, dynamic>>[];
      final server = await _captureServer(captured, {
        'code': 'ABC12345',
        'referred_count': 0,
        'referral_bound': true,
        'referred_by': 'wallet…addr',
        'recent': [],
      });
      addTearDown(() => server.close(force: true));
      final client = GatewayAuthClient(
        gatewayUrl: 'http://${server.address.host}:${server.port}',
      );

      final summary = await client.redeemReferralCode(
        code: '  abc12345  ',
        bearerToken: 'tok',
      );

      expect(summary.code, 'ABC12345');
      expect(summary.referralBound, isTrue);
      expect(summary.referredBy, 'wallet…addr');
      expect(summary.referredCount, 0);
      expect(summary.recent, isEmpty);
      expect(captured.single['path'], '/api/v2/referrals/redeem');
      expect(captured.single['body'], {'code': 'ABC12345'});
      expect(captured.single['auth'], 'Bearer tok');
    });

    test('surfaces the flat gateway error string', () async {
      final server = await _serverReturning(HttpStatus.notFound, {
        'error': 'invite code not found',
      });
      addTearDown(() => server.close(force: true));
      final client = GatewayAuthClient(
        gatewayUrl: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(
        client.redeemReferralCode(code: 'nope', bearerToken: 'tok'),
        throwsA(
          isA<AuthException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'invite code not found'),
        ),
      );
    });
  });

  group('GatewayAuthClient.fetchRank', () {
    test('reads lifetime XP from xp_earned', () async {
      final server = await _serverReturning(HttpStatus.ok, {
        'xp_earned': 120,
        'xp_claimed': 20,
        'xp_claimable': 100,
        'tier': 2,
        'tier_name': 'Bronze',
        'next_tier_at': 250,
      });
      addTearDown(() => server.close(force: true));
      final client = GatewayAuthClient(
        gatewayUrl: 'http://${server.address.host}:${server.port}',
      );

      final rank = await client.fetchRank('tok');

      expect(rank.xpEarned, 120);
      expect(rank.xpClaimable, 100);
      expect(rank.tier, 2);
      expect(rank.tierName, 'Bronze');
      expect(rank.nextTierAt, 250);
    });
  });

  group('WalletAuthController.redeemReferralCode', () {
    test('rejects an empty code without hitting the gateway', () async {
      final client = _RecordingAuthClient();
      final controller = WalletAuthController(
        authClient: client,
        store: _MemorySessionStore(_storedSession),
      );
      await controller.loadPersistedSession();

      final ok = await controller.redeemReferralCode('   ');

      expect(ok, isFalse);
      expect(controller.referralError, 'Enter a referral code');
      expect(client.redeemedCodes, isEmpty);
    });

    test('applies a code, records the summary, and refreshes rank (not '
        'profile) for XP', () async {
      final client = _RecordingAuthClient();
      final controller = WalletAuthController(
        authClient: client,
        store: _MemorySessionStore(_storedSession),
      );
      await controller.loadPersistedSession();
      client.rankFetches = 0; // ignore restore-time fetch
      client.profileFetches = 0;

      final ok = await controller.redeemReferralCode('  ABC12345  ');

      expect(ok, isTrue);
      expect(controller.referralError, isNull);
      expect(controller.referralMessage, 'Invite code applied');
      expect(controller.referralSummary?.referralBound, isTrue);
      expect(client.redeemedCodes, ['ABC12345']);
      expect(client.rankFetches, 1, reason: 'XP comes from rank/me');
      expect(client.profileFetches, 0, reason: 'profile carries no XP');
      expect(controller.rank?.xpEarned, 120);
      expect(controller.isRedeemingReferral, isFalse);
    });
  });
}

Future<HttpServer> _captureServer(
  List<Map<String, dynamic>> captured,
  Map<String, Object> body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.first.then((request) async {
      final text = await utf8.decodeStream(request);
      captured.add({
        'path': request.uri.path,
        'body': jsonDecode(text),
        'auth': request.headers.value(HttpHeaders.authorizationHeader),
      });
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }),
  );
  return server;
}

Future<HttpServer> _serverReturning(
  int status,
  Map<String, Object> body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.first.then((request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }),
  );
  return server;
}

const _storedSession = StoredAuthSession(
  token: 'session-token',
  walletAddress: 'wallet',
  userId: 'user',
  role: 'user',
  authMethod: 'email',
);

class _RecordingAuthClient extends GatewayAuthClient {
  final redeemedCodes = <String>[];
  int profileFetches = 0;
  int rankFetches = 0;

  @override
  Future<EntitlementState> fetchSubscription(String bearerToken) async =>
      EntitlementState.none;

  @override
  Future<UserProfile> fetchProfile(String bearerToken) async {
    profileFetches++;
    return const UserProfile(id: 'user');
  }

  @override
  Future<List<UserOrgInvite>> fetchAccountOrgInvites(
    String bearerToken,
  ) async => const [];

  @override
  Future<RankStanding> fetchRank(String bearerToken) async {
    rankFetches++;
    return const RankStanding(xpEarned: 120, tier: 2);
  }

  @override
  Future<ReferralSummary> redeemReferralCode({
    required String code,
    required String bearerToken,
  }) async {
    redeemedCodes.add(code);
    return const ReferralSummary(code: 'ABC12345', referralBound: true);
  }
}

class _MemorySessionStore extends AuthSessionStore {
  _MemorySessionStore(this.session);

  StoredAuthSession? session;

  @override
  Future<StoredAuthSession?> read() async => session;

  @override
  Future<void> clear() async => session = null;

  @override
  Future<void> write({
    required String token,
    required String walletAddress,
    required String userId,
    required String role,
    required String authMethod,
    String? mwaAuthToken,
  }) async {
    session = StoredAuthSession(
      token: token,
      walletAddress: walletAddress,
      userId: userId,
      role: role,
      authMethod: authMethod,
      mwaAuthToken: mwaAuthToken,
    );
  }
}
