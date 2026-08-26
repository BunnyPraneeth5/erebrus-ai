import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/entitlement_state.dart';
import '../services/model_download_service.dart';
import '../services/imported_model_service.dart';
import '../services/model_package_service.dart';
import '../services/storage_service.dart';
import '../navigation/shell_tab.dart';
import '../auth/user_org_invite.dart';
import '../auth/user_profile.dart';
import '../auth/gateway_auth_client.dart';
import '../auth/wallet_auth_controller.dart';
import '../org/ai_org.dart';
import '../org/org_state.dart';
import '../org/shared_model.dart';
import '../services/local_server_service.dart';
import '../services/node_discovery_service.dart';
import '../services/power_service.dart';
import '../services/persona_service.dart';
import '../data/mock_data.dart';

/// App-level state that wraps auth and org controllers for the existing UI.
///
/// The auth/org controllers remain the source of truth; this class listens to
/// them and exposes a flatter API so the screens don't have to manage multiple
/// notifiers.
class AppState extends ChangeNotifier {
  AppState({required this.auth, required this.orgState}) {
    auth.addListener(_onAuthChanged);
    orgState.addListener(_onOrgChanged);
    LocalServerService.instance.addListener(_onServerChanged);
    NodeDiscoveryService.instance.addListener(_onDiscoveryChanged);
    _syncFromAuth();
    unawaited(_loadLocalSettings());
  }

  final WalletAuthController auth;
  final OrgState orgState;

  bool signedIn = false;
  bool localSettingsLoaded = false;
  bool onboarded = false;
  ShellTab onboardingTargetTab = ShellTab.chat;

  bool serving = LocalServerService.instance.isRunning;

  // Chat header selections.
  String selectedModel = 'Select model';
  String selectedModelId = '';
  String selectedModelVariantId = '';
  String selectedNetworkNodeId = '';
  String defaultModelId = '';
  String defaultModelVariantId = '';
  String selectedModelQuant = 'LOCAL';
  String selectedPersonaId = 'default';
  MockPersona get selectedPersonaConfig =>
      PersonaService.instance.byId(selectedPersonaId) ??
      PersonaService.instance.defaultPersona;
  int? responseTokenOverride;
  int get responseTokenLimit =>
      Platform.isAndroid || Platform.isIOS ? 1792 : 4096;
  int get maxResponseTokens =>
      responseTokenOverride ?? selectedPersonaConfig.maxTokens;
  MockPersona get effectivePersonaConfig =>
      selectedPersonaConfig.copyWith(maxTokens: maxResponseTokens);
  String get selectedPersona => selectedPersonaConfig.name;

  bool get isNetworkModelSelected => selectedNetworkNodeId.isNotEmpty;

  NetworkModelTarget? get selectedNetworkModelTarget => NodeDiscoveryService
      .instance
      .targetFor(selectedNetworkNodeId, selectedModelId);

  /// True when the selected model is runnable locally or reachable on LAN.
  bool get isSelectedModelReady =>
      (isNetworkModelSelected && selectedNetworkModelTarget != null) ||
      (selectedModelVariantId.isNotEmpty &&
          ModelPackageService.instance
                  .byVariantId(selectedModelVariantId)
                  ?.runnable ==
              true) ||
      (selectedModelId.isNotEmpty &&
          (ModelDownloadService.instance.isDownloaded(selectedModelId) ||
              ImportedModelService.instance.contains(selectedModelId)));

  /// Onboarding is not complete until a default local package was selected
  /// after its download/readiness check succeeded.
  bool get hasConfiguredDefaultModel =>
      defaultModelId.isNotEmpty && defaultModelVariantId.isNotEmpty;

  String? get walletAddress =>
      auth.walletAddress.isNotEmpty ? auth.walletAddress : null;
  String? get userId => auth.userId.isNotEmpty ? auth.userId : null;
  String? get role => auth.role.isNotEmpty ? auth.role : null;
  UserProfile? get userProfile => auth.userProfile;
  List<UserOrgInvite> get pendingInvites => auth.accountOrgInvites;
  EntitlementState get entitlement => auth.entitlement;

  /// A referral / invite code captured before the user redeems it (e.g. from a
  /// share link). The referral card pre-fills its field with this value. Deep
  /// linking is not wired yet, so today it is only ever set explicitly.
  String? capturedReferralCode;

  bool get isRedeemingReferral => auth.isRedeemingReferral;
  String? get referralError => auth.referralError;
  String? get referralMessage => auth.referralMessage;
  ReferralSummary? get referralSummary => auth.referralSummary;

  /// Lifetime XP from `GET /api/v2/rank/me` (`xp_earned`). The account profile
  /// does not carry XP, so this is the source for the XP shown in Settings.
  RankStanding? get rank => auth.rank;
  int? get xpEarned => auth.rank?.xpEarned;

  void setCapturedReferralCode(String? code) {
    final next = code?.trim();
    capturedReferralCode = (next != null && next.isNotEmpty) ? next : null;
    notifyListeners();
  }

  /// Redeems a referral code and clears any captured value on success.
  Future<bool> redeemReferralCode(String code) async {
    final ok = await auth.redeemReferralCode(code);
    if (ok) capturedReferralCode = null;
    return ok;
  }

  List<AiOrg> get orgs => orgState.orgs;
  AiOrg? get selectedOrg => orgState.selectedOrg;
  List<SharedModel> get orgModels => orgState.orgModels;

  void _onAuthChanged() {
    _syncFromAuth();
    notifyListeners();
  }

  void _onOrgChanged() {
    notifyListeners();
  }

  void _onServerChanged() {
    serving = LocalServerService.instance.isRunning;
    notifyListeners();
  }

  void _onDiscoveryChanged() => notifyListeners();

  void _syncFromAuth() {
    signedIn = auth.isAuthenticated;
  }

  /// Toggles signed-in state for tests / mock mode. In production the UI calls
  /// [auth.openSignIn()] directly.
  void signIn() {
    signedIn = true;
    notifyListeners();
  }

  Future<void> signOut() async {
    signedIn = false;
    notifyListeners();
    try {
      await auth.signOut();
    } catch (e) {
      debugPrint('[AppState] auth.signOut error: $e');
    }
    signedIn = auth.isAuthenticated;
    notifyListeners();
  }

  void completeOnboarding() {
    onboarded = true;
    notifyListeners();
    unawaited(_persistOnboardingCompletion());
  }

  Future<void> _persistOnboardingCompletion() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('onboarding_complete', true);
  }

  Future<void> setServing(bool v) async {
    serving = v;
    notifyListeners();
    await PowerService.instance.setServing(
      v,
      label: v ? 'Serving on LAN' : 'Node paused',
    );
    try {
      if (v) {
        await LocalServerService.instance.start();
      } else {
        await LocalServerService.instance.stop();
      }
    } catch (e) {
      if (v) {
        debugPrint('[AppState] server start failed: $e');
      } else {
        debugPrint('[AppState] server stop failed: $e');
      }
    } finally {
      serving = LocalServerService.instance.isRunning;
      notifyListeners();
    }
  }

  Future<void> setMaxResponseTokens(int? value) async {
    responseTokenOverride = value?.clamp(128, responseTokenLimit);
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    if (responseTokenOverride == null) {
      await preferences.remove('max_response_tokens');
    } else {
      await preferences.setInt('max_response_tokens', responseTokenOverride!);
    }
  }

  /// The resolved filesystem path of the current models directory, or `null`
  /// while it is still being determined.
  String? modelsDirectory;
  bool get usesCustomModelsDirectory =>
      StorageService.instance.usesCustomModelsDirectory;
  String get modelsDirectoryDisplayLabel =>
      StorageService.instance.modelsDirectoryDisplayLabel;

  Future<bool> setModelsDirectory(String? path) async {
    if (path == null || path.isEmpty) {
      // Resetting to default is not implemented; use the current directory.
      return false;
    }
    final ok = await StorageService.instance.setCustomModelsDirectory(path);
    if (!ok) return false;
    modelsDirectory = await StorageService.instance
        .currentModelsDirectoryPath();
    notifyListeners();
    await ModelDownloadService.instance.scanDownloads();
    return true;
  }

  Future<void> resetModelsDirectory() async {
    await StorageService.instance.resetModelsDirectory();
    await refreshModelsDirectory();
  }

  Future<void> refreshModelsDirectory({bool scan = true}) async {
    try {
      modelsDirectory = await StorageService.instance
          .currentModelsDirectoryPath();
      notifyListeners();
      if (scan) await ModelDownloadService.instance.scanDownloads();
    } catch (error) {
      debugPrint('[AppState] models directory refresh failed: $error');
    }
  }

  Future<void> _loadLocalSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      onboarded = preferences.getBool('onboarding_complete') ?? false;
      final saved = preferences.getInt('max_response_tokens');
      if (saved != null) {
        responseTokenOverride = saved.clamp(128, responseTokenLimit);
      }
      selectedModel =
          preferences.getString('selected_model_name') ?? selectedModel;
      selectedModelId =
          preferences.getString('selected_model_id') ?? selectedModelId;
      selectedModelVariantId =
          preferences.getString('selected_model_variant_id') ?? '';
      selectedNetworkNodeId =
          preferences.getString('selected_network_node_id') ?? '';
      selectedModelQuant =
          preferences.getString('selected_model_quant') ?? selectedModelQuant;
      defaultModelId = preferences.getString('default_model_id') ?? '';
      defaultModelVariantId =
          preferences.getString('default_model_variant_id') ?? '';
      if (selectedModelId.isEmpty && defaultModelId.isNotEmpty) {
        selectedModelId = defaultModelId;
        selectedModelVariantId = defaultModelVariantId;
      }
    } catch (error) {
      debugPrint('[AppState] local settings load failed: $error');
    } finally {
      localSettingsLoaded = true;
      notifyListeners();
      // main() performs the initial model scan after the first frame.
      unawaited(refreshModelsDirectory(scan: false));
    }
  }

  void selectModel(String name, String quant, {String? id, String? variantId}) {
    selectedModel = name;
    selectedModelQuant = quant;
    selectedNetworkNodeId = '';
    if (id != null) {
      selectedModelId = id;
      selectedModelVariantId = variantId ?? '';
    }
    notifyListeners();
    unawaited(_persistActiveModel());
  }

  void selectNetworkModel(DiscoveredNode node, DiscoveredNodeModel model) {
    selectedModel = model.name;
    selectedModelId = model.id;
    selectedModelVariantId = '';
    selectedModelQuant = 'NETWORK';
    selectedNetworkNodeId = node.id;
    notifyListeners();
    unawaited(_persistActiveModel());
  }

  void clearSelectedModelIf(String modelId) {
    var changed = false;
    if (selectedModelId == modelId) {
      selectedModel = 'Select model';
      selectedModelId = '';
      selectedModelVariantId = '';
      selectedModelQuant = 'LOCAL';
      selectedNetworkNodeId = '';
      changed = true;
    }
    if (defaultModelId == modelId) {
      defaultModelId = '';
      defaultModelVariantId = '';
      unawaited(_clearPersistedDefaultModel());
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    unawaited(_persistActiveModel());
  }

  Future<void> _clearPersistedDefaultModel() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('default_model_id');
    await preferences.remove('default_model_variant_id');
  }

  Future<void> setDefaultModel({
    required String modelId,
    required String variantId,
    required String name,
    required String quant,
  }) async {
    defaultModelId = modelId;
    defaultModelVariantId = variantId;
    selectModel(name, quant, id: modelId, variantId: variantId);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('default_model_id', modelId);
    await preferences.setString('default_model_variant_id', variantId);
  }

  Future<void> _persistActiveModel() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('selected_model_name', selectedModel);
    await preferences.setString('selected_model_id', selectedModelId);
    await preferences.setString(
      'selected_model_variant_id',
      selectedModelVariantId,
    );
    await preferences.setString('selected_model_quant', selectedModelQuant);
    await preferences.setString(
      'selected_network_node_id',
      selectedNetworkNodeId,
    );
  }

  void selectPersona(String name, {String? id}) {
    selectedPersonaId =
        id ??
        PersonaService.instance.all
            .where((persona) => persona.name == name)
            .firstOrNull
            ?.effectiveId ??
        PersonaService.instance.defaultPersona.effectiveId;
    notifyListeners();
  }

  Future<void> sharePersonaToOrg(String personaId) async {
    await orgState.sharePersona(personaId);
  }

  @override
  void dispose() {
    auth.removeListener(_onAuthChanged);
    orgState.removeListener(_onOrgChanged);
    LocalServerService.instance.removeListener(_onServerChanged);
    NodeDiscoveryService.instance.removeListener(_onDiscoveryChanged);
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
