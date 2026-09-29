import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:solana_mobile_client/solana_mobile_client.dart';

import '../platform/platform_capabilities.dart';
import 'auth_config.dart';
import 'runtime_config.dart';

bool? _solanaMobileDeviceCache;

/// True on Solana Mobile hardware (Seeker, Saga) — not generic Android.
bool get isSolanaMobileDevice => _solanaMobileDeviceCache ?? false;

/// Detects Seeker/Saga devices via Android build metadata.
Future<bool> detectSolanaMobileDevice() async {
  if (_solanaMobileDeviceCache != null) return _solanaMobileDeviceCache!;

  if (kIsWeb || !Platform.isAndroid) {
    _solanaMobileDeviceCache = false;
    return false;
  }

  try {
    final info = await DeviceInfoPlugin().androidInfo;
    _solanaMobileDeviceCache = _isSolanaMobileAndroid(info);
    PlatformCapabilities.isSolanaMobileDevice = _solanaMobileDeviceCache!;
    debugPrint(
      '[MWA] device=${info.brand}/${info.model} solanaMobile=$_solanaMobileDeviceCache',
    );
    return _solanaMobileDeviceCache!;
  } catch (e) {
    debugPrint('[MWA] device detection failed: $e');
    _solanaMobileDeviceCache = false;
    return false;
  }
}

bool _isSolanaMobileAndroid(AndroidDeviceInfo info) {
  final brand = info.brand.toLowerCase();
  final manufacturer = info.manufacturer.toLowerCase();
  final model = info.model.toLowerCase();
  final device = info.device.toLowerCase();
  final product = info.product.toLowerCase();

  if (brand == 'solanamobile' || brand.contains('solana')) return true;
  if (manufacturer.contains('solana mobile') ||
      manufacturer.contains('solanamobile')) {
    return true;
  }
  const markers = ['seeker', 'saga', 'solana mobile'];
  for (final m in markers) {
    if (model.contains(m) || device.contains(m) || product.contains(m)) {
      return true;
    }
  }
  return false;
}

/// Opens MWA: wallet selector activity + local websocket in parallel.
Future<({LocalAssociationScenario scenario, MobileWalletAdapterClient client})>
_openMwaSession() async {
  final scenario = await LocalAssociationScenario.create();
  // Must not await — start() must listen while the wallet activity is open.
  // The activity future completes when the wallet closes; if that happens
  // before association (no wallet app, or the user backed out), start()
  // would wait forever, so the two race and the early close becomes an error.
  final walletClosed = scenario
      .startActivityForResult(null)
      .then<MobileWalletAdapterClient>(
        (_) => throw MwaException('The wallet closed before connecting'),
        onError: (Object error) => throw MwaException(
          'No compatible Solana wallet could be opened: $error',
        ),
      );
  debugPrint('[MWA] waiting for wallet association…');
  final MobileWalletAdapterClient client;
  try {
    client = await Future.any([scenario.start(), walletClosed]);
  } catch (_) {
    await scenario.close();
    rethrow;
  }
  debugPrint('[MWA] wallet associated');
  return (scenario: scenario, client: client);
}

/// Fetches the gateway login challenge for [address] mid-MWA-session.
typedef MwaChallengeBuilder =
    Future<String> Function(String address, Uint8List publicKey);

/// Full Seed Vault / Mobile Wallet Adapter sign-in in a **single association**:
/// authorize (or reauthorize) → fetch the login challenge → sign it → return the
/// hex signature. Throws [MwaException] with a specific reason on failure.
Future<MwaSignInResult> mwaSignIn({
  String? storedAuthToken,
  required MwaChallengeBuilder challengeBuilder,
}) async {
  if (!isSolanaMobileDevice) {
    throw MwaException(
      'Solana Mobile sign-in is only available on Seeker and Saga',
    );
  }

  LocalAssociationScenario? scenario;
  try {
    final session = await _openMwaSession();
    scenario = session.scenario;
    final client = session.client;

    final origin = RuntimeConfig.erebrusWalletOrigin;
    final identityUri = Uri.parse(erebrusMwaIdentityUrlFromOrigin(origin));
    final iconUri = Uri.parse(kErebrusMwaIconRelative);

    AuthorizationResult? auth;
    if (storedAuthToken != null && storedAuthToken.isNotEmpty) {
      auth = await client.reauthorize(
        identityUri: identityUri,
        iconUri: iconUri,
        identityName: 'Erebrus AI',
        authToken: storedAuthToken,
      );
    }
    auth ??= await client.authorize(
      identityUri: identityUri,
      iconUri: iconUri,
      identityName: 'Erebrus AI',
      cluster: 'mainnet-beta',
    );
    if (auth == null) {
      throw MwaException('Wallet authorization was declined or failed');
    }

    final address = base58.encode(auth.publicKey);
    debugPrint('[MWA] authorized $address — requesting login challenge');

    final message = await challengeBuilder(address, auth.publicKey);
    if (message.isEmpty) {
      throw MwaException('Gateway did not return a login challenge');
    }

    final signed = await client.signMessages(
      messages: [Uint8List.fromList(utf8.encode(message))],
      addresses: [auth.publicKey],
    );
    if (signed.signedMessages.isEmpty ||
        signed.signedMessages.first.signatures.isEmpty) {
      throw MwaException('Seed Vault did not sign the login challenge');
    }

    final sigBytes = signed.signedMessages.first.signatures.first;
    final signature = sigBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    debugPrint('[MWA] signed challenge for $address');

    return MwaSignInResult(
      authToken: auth.authToken,
      address: address,
      publicKey: auth.publicKey,
      signature: signature,
    );
  } on MwaException {
    rethrow;
  } catch (e) {
    debugPrint('[MWA] sign-in failed: $e');
    throw MwaException('Wallet sign-in failed: $e');
  } finally {
    await scenario?.close();
  }
}

/// Clears the local MWA authorization without opening a wallet association.
Future<void> disconnectSolanaMobile(String? mwaAuthToken) async {
  if (mwaAuthToken == null || mwaAuthToken.isEmpty) return;
  debugPrint('[MWA] cleared local authorization');
}

/// The result of a successful Seed Vault / MWA sign-in.
class MwaSignInResult {
  const MwaSignInResult({
    required this.authToken,
    required this.address,
    required this.publicKey,
    required this.signature,
  });

  final String authToken;
  final String address;
  final Uint8List publicKey;
  final String signature; // hex-encoded ed25519 signature
}

/// A Mobile Wallet Adapter failure with a user-facing reason.
class MwaException implements Exception {
  MwaException(this.message);
  final String message;

  @override
  String toString() => message;
}
