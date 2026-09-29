import 'package:erebrus_ai/app.dart';
import 'package:erebrus_ai/auth/auth_session_store.dart';
import 'package:erebrus_ai/auth/entitlement_state.dart';
import 'package:erebrus_ai/auth/gateway_auth_client.dart';
import 'package:erebrus_ai/auth/user_org_invite.dart';
import 'package:erebrus_ai/auth/user_profile.dart';
import 'package:erebrus_ai/auth/wallet_auth_controller.dart';
import 'package:erebrus_ai/data/catalog_service.dart';
import 'package:erebrus_ai/data/model_catalog.dart';
import 'package:erebrus_ai/org/org_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Completing sign-in closes the sign-in page and anything stacked on it
/// (email sheet, wallet modal) exactly once. Popping twice used to remove
/// the home route and leave a black screen on Android.
void main() {
  setUpAll(() => CatalogService.setEntries(modelCatalog));

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'default_model_id': 'smollm2-135m-instruct',
      'default_model_variant_id': 'smollm2-135m-instruct-gguf-q8_0',
    }),
  );

  testWidgets('successful sign-in returns to the shell without over-popping', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final auth = WalletAuthController(
      authClient: _FakeAuthClient(),
      store: _MemorySessionStore(),
    );
    await tester.pumpWidget(
      ErebrusApp(
        auth: auth,
        orgState: OrgState(auth: auth),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('SETTINGS'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('SIGN IN / REGISTER'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Erebrus AI'), findsOneWidget);

    // A sheet above the sign-in page, like the email code sheet.
    showModalBottomSheet<void>(
      context: tester.element(find.text('Welcome to Erebrus AI')),
      builder: (_) => const SizedBox(height: 200, child: Text('code sheet')),
    );
    await tester.pumpAndSettle();
    expect(find.text('code sheet'), findsOneWidget);

    final verify = auth.verifyEmailLoginCode(
      email: 'user@example.com',
      code: '123456',
    );
    await tester.pumpAndSettle();
    await verify;
    await tester.pumpAndSettle();

    expect(auth.isAuthenticated, isTrue);
    expect(find.text('code sheet'), findsNothing);
    expect(find.text('Welcome to Erebrus AI'), findsNothing);
    // The shell (home route) is still mounted and is the only route.
    expect(find.text('SETTINGS'), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.text('SETTINGS'))).canPop(),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}

class _FakeAuthClient extends GatewayAuthClient {
  @override
  Future<AuthSession> emailLoginVerify({
    required String email,
    required String code,
  }) async => const AuthSession(
    token: 'session-token',
    userId: 'user-1',
    role: 'user',
    walletAddress: '',
  );

  @override
  Future<EntitlementState> fetchSubscription(String bearerToken) async =>
      EntitlementState.none;

  @override
  Future<UserProfile> fetchProfile(String bearerToken) async =>
      const UserProfile(id: 'user-1', email: 'user@example.com');

  @override
  Future<List<UserOrgInvite>> fetchAccountOrgInvites(
    String bearerToken,
  ) async => const [];

  @override
  Future<RankStanding> fetchRank(String bearerToken) async => RankStanding.zero;

  @override
  Future<AuthMethods> fetchAuthMethods() async => AuthMethods.unknown;
}

class _MemorySessionStore extends AuthSessionStore {
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
