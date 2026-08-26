import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/platform_capabilities.dart';
import 'auth_config.dart';
import 'auth_session_store.dart';
import 'deep_link_handler.dart';
import 'desktop_web_auth.dart';
import 'entitlement_state.dart';
import 'gateway_auth_client.dart';
import 'runtime_config.dart';
import 'social_login.dart';
import 'solana_mobile_wallet.dart';
import 'user_org_invite.dart';
import 'user_profile.dart';

const kSessionExpiredMessage = 'Your session expired. Please sign in again.';

/// Wallet login via MWA on Solana Mobile, Reown elsewhere, and gateway v2 auth.
class WalletAuthController extends ChangeNotifier {
  WalletAuthController({GatewayAuthClient? authClient, AuthSessionStore? store})
    : _authClient = authClient ?? GatewayAuthClient(),
      _store = store ?? AuthSessionStore() {
    _authClient.onUnauthorized = handleBearerUnauthorized;
  }

  final GatewayAuthClient _authClient;
  final AuthSessionStore _store;

  ReownAppKitModal? appKitModal;

  String walletAddress = '';
  String userId = '';
  String role = '';
  String authMethod = '';
  bool isAuthenticating = false;
  bool reownReady = false;
  bool sessionReady = false;
  String? authError;
  EntitlementState entitlement = EntitlementState.none;
  bool isLoadingEntitlement = false;
  String? entitlementError;
  bool awaitingWebCallback = false;

  UserProfile? userProfile;
  bool isLoadingProfile = false;
  String? profileError;

  List<UserOrgInvite> accountOrgInvites = [];
  bool isLoadingAccountOrgInvites = false;
  String? accountOrgInvitesError;

  bool isRedeemingReferral = false;
  String? referralError;
  String? referralMessage;
  ReferralSummary? referralSummary;

  RankStanding? rank;
  bool isLoadingRank = false;
  String? rankError;

  AuthMethods authMethods = AuthMethods.unknown;
  bool appleDeviceReady = false;

  String? _token;
  String? _mwaAuthToken;
  Future<void>? _revalidation;
  int sessionExpiredRevision = 0;

  bool isSolanaMobileDevice = false;

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  bool get isEntitled => entitlement.entitled || role == 'admin';
  bool get usesReown => PlatformCapabilities.usesReown;
  bool get usesWebLogin => PlatformCapabilities.usesWebLogin;
  String? get bearerToken => _token;

  bool get emailLoginAvailable => authMethods.email;
  bool get googleLoginAvailable => authMethods.google && googleSignInSupported;
  bool get appleLoginAvailable => authMethods.apple && appleDeviceReady;

  /// Initializes platform detection and restores any persisted session.
  Future<void> initialize() async {
    await detectDevice();
    await loadPersistedSession();
    unawaited(loadAuthMethods());
  }

  /// Detects Seeker/Saga hardware so auth can skip Reown on Solana Mobile.
  Future<void> detectDevice() async {
    final detected = await detectSolanaMobileDevice();
    isSolanaMobileDevice = detected;
    PlatformCapabilities.isSolanaMobileDevice = detected;
    notifyListeners();
  }

  /// Restores token + profile from secure storage before the UI loads.
  Future<void> loadPersistedSession() async {
    sessionReady = false;
    authError = null;
    notifyListeners();
    try {
      final stored = await _store.read();
      if (stored != null) {
        _token = stored.token;
        _mwaAuthToken = stored.mwaAuthToken;
        walletAddress = stored.walletAddress;
        userId = stored.userId;
        role = stored.role;
        authMethod = stored.authMethod;
        await revalidateSession();
        await refreshProfile();
        await refreshAccountOrgInvites();
        await refreshRank();
        if (isAuthenticated) {
          debugPrint('[Auth] restored session for ${stored.walletAddress}');
        }
      } else {
        entitlement = EntitlementState.none;
      }
    } catch (e) {
      debugPrint('[Auth] restore failed: $e');
    } finally {
      sessionReady = true;
      notifyListeners();
    }
  }

  Future<void> loadAuthMethods() async {
    try {
      authMethods = await _authClient.fetchAuthMethods();
      appleDeviceReady = await appleSignInSupported();
    } catch (e) {
      debugPrint('[Auth] loadAuthMethods failed: $e');
    }
    notifyListeners();
  }

  /// Initializes Reown AppKit once a [BuildContext] is available.
  Future<void> initReown(BuildContext context) async {
    if (!usesReown) {
      reownReady = false;
      notifyListeners();
      return;
    }
    if (!RuntimeConfig.hasReownProjectId) {
      authError = kReownProjectIdMissingMessage;
      reownReady = false;
      notifyListeners();
      debugPrint('[Reown] init skipped — REOWN_PROJECT_ID not in build env');
      return;
    }
    if (appKitModal?.modalContext == context) {
      reownReady = true;
      notifyListeners();
      return;
    }

    // The sign-in page is disposable. Reuse the underlying AppKit session but
    // recreate its modal when a newly opened page provides a fresh context.
    final existingAppKit = appKitModal?.appKit;
    if (appKitModal != null) {
      await appKitModal!.dispose();
      appKitModal = null;
    }
    if (!context.mounted) return;

    ReownAppKitModalNetworks.removeSupportedNetworks('eip155');
    ReownAppKitModalNetworks.removeTestNetworks();

    final solanaChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
      namespace: 'solana',
    );
    final solanaNamespaces = solanaChains.isEmpty
        ? null
        : {
            'solana': RequiredNamespace(
              chains: solanaChains.map((c) => c.chainId).toList(),
              methods: const ['solana_signMessage', 'solana_signTransaction'],
              events: const [],
            ),
          };

    final origin = RuntimeConfig.erebrusWalletOrigin;
    appKitModal = ReownAppKitModal(
      context: context,
      appKit: existingAppKit,
      projectId: RuntimeConfig.reownProjectId,
      logLevel: LogLevel.error,
      metadata: PairingMetadata(
        name: 'Erebrus AI',
        description: 'Private, local AI runner and workspace sharing',
        url: erebrusSiteUrlFromOrigin(origin),
        icons: [erebrusSiteIconFromOrigin(origin)],
        redirect: const Redirect(
          native: kErebrusNativeRedirect,
          universal: kErebrusUniversalRedirect,
          linkMode: false,
        ),
      ),
      optionalNamespaces: solanaNamespaces,
      featuresConfig: FeaturesConfig(
        showMainWallets: true,
        socials: const [
          AppKitSocialOption.Google,
          AppKitSocialOption.Apple,
          AppKitSocialOption.Email,
          AppKitSocialOption.X,
        ],
      ),
      disconnectOnDispose: false,
    );

    try {
      final projectHint = RuntimeConfig.reownProjectId.length > 8
          ? '${RuntimeConfig.reownProjectId.substring(0, 8)}…'
          : RuntimeConfig.reownProjectId;
      final packageInfo = await PackageInfo.fromPlatform();
      final relayOrigin = packageInfo.packageName;
      debugPrint(
        '[Reown] initializing AppKit (project $projectHint, relay origin $relayOrigin)',
      );
      await appKitModal!.init();
      appKitModal!.onModalConnect.subscribe(_onModalConnect);
      appKitModal!.onModalDisconnect.subscribe(_onModalDisconnect);
      appKitModal!.onModalError.subscribe(_onModalError);

      DeepLinkHandler.bind(this);
      DeepLinkHandler.checkInitialLink();
      reownReady = true;
      debugPrint('[Reown] ready — wallets + social login available');

      if (appKitModal!.isConnected && !isAuthenticated) {
        await _authenticateConnectedWallet();
      }
    } catch (e) {
      debugPrint('[Reown] init failed: $e');
      authError = 'Wallet connect failed to start: $e';
      reownReady = false;
    }
    notifyListeners();
  }

  /// Initializes desktop browser auth (deep-link listener only).
  void initDesktopAuth() {
    if (!usesWebLogin) return;
    DeepLinkHandler.bind(this);
    DeepLinkHandler.checkInitialLink();
    debugPrint(
      '[Auth] desktop web-login ready — origin ${RuntimeConfig.erebrusWebOrigin}',
    );
  }

  /// Opens MWA on Solana Mobile, browser on desktop, Reown modal on other mobile.
  Future<void> openSignIn() async {
    authError = null;
    notifyListeners();
    if (isSolanaMobileDevice) {
      await signInWithSolanaMobile();
    } else if (usesWebLogin) {
      await openWebSignIn();
    } else {
      await openWalletModal();
    }
  }

  /// Opens erebrus.io in the system browser; PASETO returns via `erebrusai://auth`.
  Future<void> openWebSignIn() async {
    if (isAuthenticating || awaitingWebCallback) return;

    authError = null;
    awaitingWebCallback = true;
    notifyListeners();
    try {
      final url = DesktopWebAuth.buildLoginUrl();
      final uri = Uri.parse(url);
      debugPrint('[Auth] opening web login: ${redactedAuthUrlForLog(url)}');
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        awaitingWebCallback = false;
        authError = 'Could not open the browser — check your default browser';
      }
    } catch (e) {
      awaitingWebCallback = false;
      authError = e.toString();
    }
    notifyListeners();
  }

  /// Completes sign-in from pasted PASETO / callback URL (Postman-style fallback).
  Future<void> signInWithPastedCredential(String input) async {
    isAuthenticating = true;
    awaitingWebCallback = false;
    authError = null;
    notifyListeners();
    try {
      final callback = DesktopWebAuth.parseManualAuthInput(input);
      if (callback == null || callback.token.isEmpty) {
        authError =
            'Could not read a sign-in token — paste the PASETO or full callback URL';
        isAuthenticating = false;
        notifyListeners();
        return;
      }

      var userId = callback.userId;
      var wallet = callback.walletAddress;
      final role = callback.role.isNotEmpty ? callback.role : 'user';

      await _authClient.fetchSubscription(callback.token);
      if (userId.isEmpty) userId = 'imported';
      if (wallet.isEmpty) wallet = 'imported';

      await _persistSession(
        AuthSession(
          token: callback.token,
          userId: userId,
          role: role,
          walletAddress: wallet,
        ),
        method: 'manual_paste',
      );
      DesktopWebAuth.clearPendingState();
      await refreshEntitlement();
      await refreshProfile();
      await refreshAccountOrgInvites();
      await refreshRank();
      debugPrint('[Auth] manual paste login OK');
    } on AuthException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  /// Reads clipboard and attempts [signInWithPastedCredential].
  Future<void> signInFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      authError = 'Clipboard is empty — copy the PASETO from the browser first';
      notifyListeners();
      return;
    }
    await signInWithPastedCredential(text);
  }

  /// Completes sign-in from `erebrusai://auth?token=…` (called by [DeepLinkHandler]).
  Future<void> handleWebAuthCallback(String url) async {
    awaitingWebCallback = false;
    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      final callback = DesktopWebAuth.parseCallback(url);
      if (callback == null || !callback.isValid) {
        authError = 'Sign-in callback was incomplete — try again';
        isAuthenticating = false;
        notifyListeners();
        return;
      }
      DesktopWebAuth.validateState(callback.state);

      await _persistSession(
        AuthSession(
          token: callback.token,
          userId: callback.userId,
          role: callback.role,
          walletAddress: callback.walletAddress,
        ),
        method: 'web',
      );
      DesktopWebAuth.clearPendingState();
      await refreshEntitlement();
      await refreshProfile();
      await refreshAccountOrgInvites();
      await refreshRank();
      debugPrint('[Auth] web login OK for ${callback.walletAddress}');
    } on DesktopWebAuthException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> openWalletModal() async {
    authError = null;
    notifyListeners();
    if (appKitModal == null || !reownReady) {
      authError = 'Wallet connect is still starting — try again in a moment';
      notifyListeners();
      return;
    }
    await appKitModal!.openModalView();
  }

  void cancelAuthentication() {
    isAuthenticating = false;
    awaitingWebCallback = false;
    try {
      if (appKitModal?.isOpen == true) appKitModal?.closeModal();
    } catch (_) {}
    authError = 'Sign-in cancelled';
    notifyListeners();
  }

  Future<void> signInWithGoogle() async {
    if (isAuthenticating || !googleLoginAvailable) return;
    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      final idToken = await googleIdToken();
      if (idToken == null) return;
      final session = await _authClient.googleLogin(idToken);
      await _finishIdentitySignIn(session, 'google');
    } on AuthException catch (e) {
      authError = e.message;
    } on SocialLoginException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> signInWithApple() async {
    if (isAuthenticating || !appleLoginAvailable) return;
    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      final credential = await appleCredential();
      if (credential == null) return;
      final session = await _authClient.appleLogin(
        idToken: credential.identityToken,
        authorizationCode: credential.authorizationCode,
        nonce: credential.nonce,
        state: credential.state,
      );
      await _finishIdentitySignIn(session, 'apple');
    } on AuthException catch (e) {
      authError = e.message;
    } on SocialLoginException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<bool> requestEmailLoginCode(String email) async {
    authError = null;
    notifyListeners();
    try {
      await _authClient.emailLoginStart(email);
      return true;
    } on AuthException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    }
    notifyListeners();
    return false;
  }

  Future<void> verifyEmailLoginCode({
    required String email,
    required String code,
  }) async {
    final normalized = code.replaceAll(RegExp(r'\D'), '');
    if (normalized.length < 4) {
      authError = 'Enter the full code from your email';
      notifyListeners();
      return;
    }
    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      final session = await _authClient.emailLoginVerify(
        email: email,
        code: normalized,
      );
      if (session.token.isEmpty) {
        authError = 'Sign-in succeeded but no session token was returned';
        return;
      }
      await _finishIdentitySignIn(session, 'email');
    } on AuthException catch (e) {
      authError = e.message;
    } on TimeoutException {
      authError = 'Sign-in timed out — check your connection and try again';
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> _finishIdentitySignIn(AuthSession session, String method) async {
    if (session.token.isEmpty) {
      throw AuthException('Sign-in did not return a session token');
    }
    await _persistSession(session, method: method);
    await refreshEntitlement();
    await refreshProfile();
    await refreshAccountOrgInvites();
    await refreshRank();
  }

  /// Mobile Wallet Adapter path — opens the native wallet selector on Seeker/Saga.
  Future<void> signInWithSolanaMobile() async {
    if (!isSolanaMobileDevice) {
      authError = 'Solana Mobile sign-in is only available on Seeker and Saga';
      notifyListeners();
      return;
    }
    if (isAuthenticating) return;

    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      var flowId = '';
      final result = await mwaSignIn(
        storedAuthToken: _mwaAuthToken,
        challengeBuilder: (address, publicKey) async {
          final challenge = await _authClient.fetchFlowId(
            walletAddress: address,
          );
          flowId = challenge.flowId;
          return challenge.message;
        },
      );
      _mwaAuthToken = result.authToken;

      final session = await _authClient.authenticate(
        flowId: flowId,
        signature: result.signature,
        publicKey: result.address,
      );
      await _persistSession(
        session,
        method: 'solana_mobile',
        mwaToken: result.authToken,
      );
      await refreshEntitlement();
      await refreshProfile();
      await refreshAccountOrgInvites();
      await refreshRank();
      debugPrint('[MWA] gateway auth OK for ${result.address}');
    } on MwaException catch (e) {
      authError = e.message;
    } on AuthException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    authError = null;
    entitlementError = null;
    entitlement = EntitlementState.none;
    final mwaToken = _mwaAuthToken;
    _token = null;
    _mwaAuthToken = null;
    walletAddress = '';
    userId = '';
    role = '';
    authMethod = '';
    userProfile = null;
    accountOrgInvites = [];
    isRedeemingReferral = false;
    referralError = null;
    referralMessage = null;
    referralSummary = null;
    rank = null;
    rankError = null;
    await _store.clear();
    if (appKitModal?.isConnected == true) {
      await appKitModal?.disconnect();
    }
    await googleSignOut();
    await disconnectSolanaMobile(mwaToken);
    awaitingWebCallback = false;
    DesktopWebAuth.clearPendingState();
    notifyListeners();
  }

  /// Revalidates the current bearer session without logging out for recoverable
  /// authorization, network, or server failures. Authenticated 401 responses are
  /// handled centrally by [handleBearerUnauthorized].
  Future<void> revalidateSession() async {
    final active = _revalidation;
    if (active != null) {
      await active;
      return;
    }
    final token = _token;
    if (token == null || token.isEmpty) return;

    final operation = _revalidateToken(token);
    _revalidation = operation;
    try {
      await operation;
    } finally {
      if (identical(_revalidation, operation)) _revalidation = null;
    }
  }

  Future<void> _revalidateToken(String token) async {
    isLoadingEntitlement = true;
    entitlementError = null;
    notifyListeners();
    try {
      entitlement = await _authClient.fetchSubscription(token);
    } on AuthException catch (e) {
      // A bearer-authenticated 401 has already invalidated the session in the
      // HTTP client. All other failures are recoverable and retain the token.
      if (e.statusCode != 401) entitlementError = e.message;
    } catch (e) {
      entitlementError = e.toString();
    } finally {
      isLoadingEntitlement = false;
      notifyListeners();
    }
  }

  /// Invalidates only the session that supplied [rejectedToken]. Clearing the
  /// in-memory token before awaiting storage makes concurrent 401s idempotent.
  Future<void> handleBearerUnauthorized(String rejectedToken) async {
    if (rejectedToken.isEmpty || _token != rejectedToken) return;

    _token = null;
    _mwaAuthToken = null;
    walletAddress = '';
    userId = '';
    role = '';
    authMethod = '';
    entitlement = EntitlementState.none;
    entitlementError = null;
    userProfile = null;
    profileError = null;
    accountOrgInvites = [];
    accountOrgInvitesError = null;
    isRedeemingReferral = false;
    referralError = null;
    referralMessage = null;
    referralSummary = null;
    rank = null;
    rankError = null;
    awaitingWebCallback = false;
    authError = kSessionExpiredMessage;
    sessionExpiredRevision++;
    DesktopWebAuth.clearPendingState();
    notifyListeners();

    try {
      await _store.clear();
    } catch (e) {
      debugPrint('[Auth] failed to clear expired persisted session: $e');
    }
  }

  Future<void> refreshEntitlement() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      entitlement = EntitlementState.none;
      notifyListeners();
      return;
    }
    isLoadingEntitlement = true;
    entitlementError = null;
    notifyListeners();
    try {
      entitlement = await _authClient.fetchSubscription(token);
    } on AuthException catch (e) {
      entitlementError = e.message;
      entitlement = EntitlementState.none;
    } catch (e) {
      entitlementError = e.toString();
      entitlement = EntitlementState.none;
    } finally {
      isLoadingEntitlement = false;
      notifyListeners();
    }
  }

  Future<void> refreshProfile() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      userProfile = null;
      notifyListeners();
      return;
    }
    isLoadingProfile = true;
    profileError = null;
    notifyListeners();
    try {
      userProfile = await _authClient.fetchProfile(token);
    } on AuthException catch (e) {
      profileError = e.message;
      userProfile = null;
    } catch (e) {
      profileError = e.toString();
      userProfile = null;
    } finally {
      isLoadingProfile = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccountOrgInvites() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      accountOrgInvites = [];
      notifyListeners();
      return;
    }
    isLoadingAccountOrgInvites = true;
    accountOrgInvitesError = null;
    notifyListeners();
    try {
      accountOrgInvites = await _authClient.fetchAccountOrgInvites(token);
    } on AuthException catch (e) {
      accountOrgInvitesError = e.message;
      accountOrgInvites = [];
    } catch (e) {
      accountOrgInvitesError = e.toString();
      accountOrgInvites = [];
    } finally {
      isLoadingAccountOrgInvites = false;
      notifyListeners();
    }
  }

  /// Accepts a pending org invite by its invite id. Callers are responsible for
  /// refreshing [OrgState] so the newly joined org appears in the list.
  Future<void> acceptAccountOrgInvite(String inviteId) async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    try {
      await _authClient.acceptAccountOrgInvite(inviteId, token);
      await refreshAccountOrgInvites();
    } on AuthException catch (e) {
      authError = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> declineAccountOrgInvite(String inviteId) async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    try {
      await _authClient.declineAccountOrgInvite(inviteId, token);
      await refreshAccountOrgInvites();
    } on AuthException catch (e) {
      authError = e.message;
      notifyListeners();
      rethrow;
    }
  }

  /// Redeems a referral / invite code for the signed-in user. Binding a
  /// referrer is one-shot per account; XP is awarded to both parties on the
  /// gateway once the caller has an active org membership. Returns true on
  /// success; on failure [referralError] holds the reason.
  Future<bool> redeemReferralCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      referralError = 'Enter a referral code';
      notifyListeners();
      return false;
    }
    final token = _token;
    if (token == null || token.isEmpty) {
      referralError = 'Sign in to redeem a referral code';
      notifyListeners();
      return false;
    }
    isRedeemingReferral = true;
    referralError = null;
    referralMessage = null;
    notifyListeners();
    try {
      referralSummary = await _authClient.redeemReferralCode(
        code: trimmed,
        bearerToken: token,
      );
      // XP unlocks only once the referee qualifies (active org membership), so
      // the message stays outcome-neutral. Lifetime XP lives on the rank
      // endpoint, not the profile — refresh it so any award shows.
      referralMessage = 'Invite code applied';
      await refreshRank();
      return true;
    } on AuthException catch (e) {
      referralError = e.message;
      return false;
    } catch (e) {
      referralError = e.toString();
      return false;
    } finally {
      isRedeemingReferral = false;
      notifyListeners();
    }
  }

  Future<void> refreshRank() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      rank = RankStanding.zero;
      notifyListeners();
      return;
    }
    isLoadingRank = true;
    rankError = null;
    notifyListeners();
    try {
      rank = await _authClient.fetchRank(token);
    } on AuthException catch (e) {
      if (e.statusCode != 401) rankError = e.message;
    } catch (e) {
      rankError = e.toString();
    } finally {
      isLoadingRank = false;
      notifyListeners();
    }
  }

  Future<void> createOrg({required String name, required String slug}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AuthException('Sign in to create an organization');
    }
    try {
      await _authClient.createOrg(name: name, slug: slug, bearerToken: token);
    } on AuthException catch (e) {
      authError = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _persistSession(
    AuthSession session, {
    required String method,
    String? mwaToken,
  }) async {
    _token = session.token;
    walletAddress = session.walletAddress;
    userId = session.userId;
    role = session.role;
    authMethod = method;
    if (mwaToken != null) _mwaAuthToken = mwaToken;
    await _store.write(
      token: session.token,
      walletAddress: session.walletAddress,
      userId: session.userId,
      role: session.role,
      authMethod: method,
      mwaAuthToken: mwaToken ?? _mwaAuthToken,
    );
    notifyListeners();
  }

  void _onModalConnect(ModalConnect? event) {
    if (event != null) _authenticateConnectedWallet();
  }

  void _onModalDisconnect(ModalDisconnect? event) {}

  void _onModalError(ModalError? event) {
    final message = event?.message;
    if (message == null || message.isEmpty) return;
    if (message.toLowerCase().contains('origin not allowed')) {
      authError = reownOriginNotAllowedMessage(kErebrusBundleId);
    } else {
      authError = message;
    }
    notifyListeners();
  }

  Future<void> _authenticateConnectedWallet() async {
    final modal = appKitModal;
    if (modal == null || !modal.isConnected) return;

    final address = await _solanaAddress(modal);
    if (address == null || address.isEmpty) {
      authError = 'Connect a Solana wallet';
      notifyListeners();
      return;
    }

    isAuthenticating = true;
    authError = null;
    notifyListeners();
    try {
      final challenge = await _authClient.fetchFlowId(walletAddress: address);
      final signature = await _signChallenge(modal, address, challenge.message);
      final session = await _authClient.authenticate(
        flowId: challenge.flowId,
        signature: signature,
        publicKey: address,
      );
      await _persistSession(session, method: 'reown');
      await refreshEntitlement();
      await refreshProfile();
      await refreshAccountOrgInvites();
      await refreshRank();
      if (modal.isOpen) modal.closeModal();
      debugPrint('[Reown] gateway auth OK for $address');
    } on AuthException catch (e) {
      authError = e.message;
    } catch (e) {
      authError = e.toString();
    } finally {
      isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<String?> _solanaAddress(ReownAppKitModal modal) async {
    final chainId = modal.selectedChain?.chainId ?? '';
    if (!chainId.startsWith('solana:')) {
      final solChains = ReownAppKitModalNetworks.getAllSupportedNetworks(
        namespace: 'solana',
      );
      if (solChains.isNotEmpty) {
        await modal.selectChain(solChains.first);
      }
    }
    final selected = modal.selectedChain?.chainId ?? '';
    if (!selected.startsWith('solana:')) return null;
    return modal.session?.getAddress('solana');
  }

  Future<String> _signChallenge(
    ReownAppKitModal modal,
    String address,
    String message,
  ) async {
    final chainId = modal.selectedChain!.chainId;
    final messageBase58 = base58.encode(utf8.encode(message));

    final response = await modal.request(
      topic: modal.session!.topic,
      chainId: chainId,
      request: SessionRequestParams(
        method: 'solana_signMessage',
        params: {'pubkey': address, 'message': messageBase58},
      ),
    );

    return _signatureToTransmittable(response);
  }

  String _signatureToTransmittable(dynamic response) {
    if (response is String) return response;
    if (response is Map) {
      final sig = ReownCoreUtils.recursiveSearchForMapKey(
        Map<String, dynamic>.from(response),
        'signature',
      );
      if (sig is String) return sig;
    }
    if (response is List && response.isNotEmpty) {
      return _signatureToTransmittable(response.first);
    }
    throw AuthException('Wallet returned an unreadable signature');
  }

  @override
  void dispose() {
    appKitModal?.onModalConnect.unsubscribe(_onModalConnect);
    appKitModal?.onModalDisconnect.unsubscribe(_onModalDisconnect);
    appKitModal?.onModalError.unsubscribe(_onModalError);
    super.dispose();
  }
}
