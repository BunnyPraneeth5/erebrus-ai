import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/wallet_auth_controller.dart';
import '../services/storage_service.dart';
import 'ai_org.dart';
import 'org_client.dart';
import 'shared_model.dart';

/// Reactive org list, selected org, and shared models for the signed-in user.
class OrgState extends ChangeNotifier {
  OrgState({required this._auth, OrgClient? client})
    : _client = client ?? OrgClient() {
    _client.onUnauthorized = _auth.handleBearerUnauthorized;
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final WalletAuthController _auth;
  final OrgClient _client;

  List<AiOrg> orgs = [];
  AiOrg? selectedOrg;
  List<SharedModel> orgModels = [];
  bool isLoading = false;
  String? error;
  String? _loadedForToken;

  bool get isAuthenticated => _auth.isAuthenticated;
  String? get _token => _auth.bearerToken;

  void _onAuthChanged() {
    if (!_auth.isAuthenticated) {
      // The cache holds the previous account's workspaces; drop it so the
      // next account never sees them, even briefly.
      if (_loadedForToken != null) unawaited(_deleteCache());
      _loadedForToken = null;
      orgs = [];
      selectedOrg = null;
      orgModels = [];
      notifyListeners();
      return;
    }
    if (_loadedForToken == _token) return;
    _loadedForToken = _token;
    unawaited(_loadCache().then((_) => refreshOrgs()));
  }

  Future<void> refreshOrgs() async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      orgs = await _client.fetchOrganizations(token);
      final selectedId = selectedOrg?.id;
      if (orgs.isEmpty) {
        selectedOrg = null;
      } else {
        selectedOrg = orgs.firstWhere(
          (org) => org.id == selectedId,
          orElse: () => orgs.first,
        );
      }
      await refreshOrgModels();
      await _persistCache();
    } on OrgException catch (e) {
      error = e.message;
      orgs = [];
      selectedOrg = null;
      orgModels = [];
    } catch (e) {
      error = e.toString();
      orgs = [];
      selectedOrg = null;
      orgModels = [];
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectOrg(AiOrg org) async {
    selectedOrg = org;
    notifyListeners();
    await refreshOrgModels();
  }

  Future<void> createOrg({required String name, required String slug}) async {
    await _auth.createOrg(name: name, slug: slug);
    await refreshOrgs();
    if (orgs.isNotEmpty) {
      selectedOrg = orgs.firstWhere(
        (org) => org.slug == slug.trim().toLowerCase(),
        orElse: () => orgs.last,
      );
      await refreshOrgModels();
    }
  }

  Future<void> refreshOrgModels() async {
    final token = _token;
    final org = selectedOrg;
    if (token == null || token.isEmpty || org == null) {
      orgModels = [];
      notifyListeners();
      return;
    }
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      orgModels = await _client.fetchOrgModels(org.id, token);
      await _persistCache();
    } on OrgException catch (e) {
      error = e.message;
      orgModels = [];
    } catch (e) {
      error = e.toString();
      orgModels = [];
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> sharePersona(String personaId) async {
    final token = _token;
    final org = selectedOrg;
    if (token == null || token.isEmpty || org == null) return;
    try {
      await _client.sharePersona(
        orgId: org.id,
        personaId: personaId,
        bearerToken: token,
      );
    } on OrgException catch (e) {
      error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _loadCache() async {
    if (kIsWeb) return;
    try {
      final dir = await StorageService.instance.baseDir();
      final file = File('${dir.path}/org_state.json');
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final j = jsonDecode(text) as Map<String, dynamic>;
      final cachedUser = j['user_id']?.toString() ?? '';
      if (cachedUser.isEmpty || cachedUser != _auth.userId) return;
      final orgList = j['orgs'];
      if (orgList is List) {
        orgs = orgList
            .map((e) => AiOrg.fromJson(Map<String, dynamic>.from(e as Map)))
            .where((o) => o.id.isNotEmpty)
            .toList();
      }
      final selectedId = j['selected_org_id']?.toString();
      if (selectedId != null && selectedId.isNotEmpty) {
        selectedOrg = orgs.firstWhere(
          (o) => o.id == selectedId,
          orElse: () =>
              orgs.isNotEmpty ? orgs.first : const AiOrg(id: '', name: ''),
        );
        if (selectedOrg!.id.isEmpty) selectedOrg = null;
      } else if (orgs.isNotEmpty) {
        selectedOrg = orgs.first;
      }
      final modelList = j['org_models'];
      if (modelList is List) {
        orgModels = modelList
            .map(
              (e) => SharedModel.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .where((m) => m.id.isNotEmpty)
            .toList();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[OrgState] cache load failed: $e');
    }
  }

  Future<void> _persistCache() async {
    if (kIsWeb) return;
    try {
      final dir = await StorageService.instance.baseDir();
      final file = File('${dir.path}/org_state.json');
      final payload = {
        'user_id': _auth.userId,
        'orgs': orgs.map((o) => o.toJson()).toList(),
        'selected_org_id': selectedOrg?.id,
        'org_models': orgModels.map((m) => m.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(payload));
    } catch (e) {
      debugPrint('[OrgState] cache persist failed: $e');
    }
  }

  Future<void> _deleteCache() async {
    if (kIsWeb) return;
    try {
      final dir = await StorageService.instance.baseDir();
      final file = File('${dir.path}/org_state.json');
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[OrgState] cache delete failed: $e');
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
