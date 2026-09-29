import 'dart:io';

import 'package:erebrus_ai/app.dart';
import 'package:erebrus_ai/auth/wallet_auth_controller.dart';
import 'package:erebrus_ai/data/catalog_service.dart';
import 'package:erebrus_ai/data/model_catalog.dart';
import 'package:erebrus_ai/org/org_state.dart';
import 'package:erebrus_ai/services/chat_service.dart';
import 'package:erebrus_ai/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screens-only smoke tests: every screen builds at desktop (1280×800) and
/// mobile (390×844) sizes, in guest and signed-in states, without exceptions.
///
/// The real app fonts are loaded so text metrics (and overflow checks) match
/// what users see instead of the square-glyph Ahem test font.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    Future<ByteData> read(String path) async =>
        ByteData.sublistView(File(path).readAsBytesSync());

    final grotesk = FontLoader('Space Grotesk')
      ..addFont(read('assets/fonts/SpaceGrotesk-Variable.ttf'));
    await grotesk.load();

    final mono = FontLoader('IBM Plex Mono')
      ..addFont(read('assets/fonts/IBMPlexMono-Regular.ttf'))
      ..addFont(read('assets/fonts/IBMPlexMono-Medium.ttf'))
      ..addFont(read('assets/fonts/IBMPlexMono-SemiBold.ttf'));
    await mono.load();

    // Use the compiled-in catalog in widget tests so remote network calls are
    // not attempted and expected model names stay stable.
    CatalogService.setEntries(modelCatalog);
  });

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'default_model_id': 'smollm2-135m-instruct',
      'default_model_variant_id': 'smollm2-135m-instruct-gguf-q8_0',
    }),
  );

  Future<void> pumpApp(
    WidgetTester tester,
    Size size, {
    WalletAuthController? auth,
    OrgState? orgState,
    double topPadding = 0,
    double textScaleFactor = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(top: topPadding);
    tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
    addTearDown(() {
      tester.view.reset();
      tester.view.resetPadding();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final controller = auth ?? WalletAuthController();
    await tester.pumpWidget(
      ErebrusApp(
        auth: controller,
        orgState: orgState ?? OrgState(auth: controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('desktop 1280x800', () {
    testWidgets('desktop first launch requires onboarding and model setup', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, const Size(1280, 800));

      expect(find.text('01 / PRIVATE AI'), findsOneWidget);
      await tester.tap(find.text('SKIP'));
      await tester.pumpAndSettle();
      expect(find.text('04 / INSTALL YOUR ON-DEVICE AI'), findsOneWidget);
      expect(find.text('AVAILABLE MODELS'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
    });

    testWidgets('chat, transcribe, models, and settings render', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1280, 800));

      // Chat (default tab) — sidebar + sessions + streaming status.
      expect(find.text('SESSIONS'), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.text('GUEST MODE'), findsOneWidget);
      expect(find.text('Node paused'), findsOneWidget);

      // Models → NETWORK tab with guest gate.
      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Models'), findsOneWidget);
      await tester.tap(find.text('NETWORK · 0'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Private workspace models'), findsOneWidget);
      expect(find.text('Private workspace models'), findsOneWidget);

      // Transcribe is a primary tab and does not invoke analysis automatically.
      await tester.tap(find.text('TRANSCRIBE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Transcribe'), findsOneWidget);
      expect(find.text('SET UP TRANSCRIPTION'), findsOneWidget);
      expect(
        find.textContaining('No analysis runs automatically'),
        findsOneWidget,
      );
      expect(find.textContaining('No chat model is required'), findsOneWidget);

      // Settings (guest): two-pane layout opens on Account.
      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Search settings…'), findsOneWidget);
      expect(find.text('Unlock private models & workspaces'), findsOneWidget);

      await tester.tap(find.text('Local server').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Serve on local network'), findsOneWidget);
      expect(find.text('API key'), findsOneWidget);

      // Personas stay nested under General.
      await tester.tap(find.text('General').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Model memory'), findsOneWidget);
      expect(find.text('No model in memory'), findsOneWidget);
      await tester.tap(find.text('Manage'));
      await tester.pumpAndSettle();
      expect(find.text('SYSTEM PROMPT'), findsOneWidget);
      expect(find.text('SAVE PERSONA'), findsOneWidget);
      expect(find.text('Share to workspace'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Voice').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Dictation engine'), findsOneWidget);
      expect(find.text('Speech recognition model'), findsOneWidget);
      expect(find.text('Read aloud button'), findsOneWidget);

      // Connections: empty state leads into the add form.
      await tester.tap(find.text('Connections').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No connections yet'), findsOneWidget);
      await tester.tap(find.text('llama.cpp'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.text('Load available models'), findsOneWidget);
      expect(
        find.text(
          'Or enter model IDs manually (one per line or comma-separated)',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Add connection'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Add connection'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Select at least one model, or enter model IDs manually'),
        findsOneWidget,
      );

      // Search narrows the section list.
      await tester.enterText(find.byType(TextField).first, 'whisper');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Account'), findsNothing);
      expect(find.text('Voice'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('models use desktop catalog details and show storage path', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1280, 800));

      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('MODEL CATALOG'), findsOneWidget);
      expect(find.text('Download options'), findsOneWidget);
      expect(find.text('About this model'), findsOneWidget);
      expect(find.text('MODELS FOLDER'), findsOneWidget);
      expect(find.textContaining('ErebrusAI/models'), findsOneWidget);
      expect(find.text('DOWNLOADS'), findsNothing);
      expect(find.text('STARS'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sign-in page swaps guest → signed-in content', (tester) async {
      await pumpApp(tester, const Size(1280, 800));

      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('SIGN IN / REGISTER'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Erebrus AI'), findsOneWidget);
      expect(find.text('CONTINUE AS GUEST'), findsOneWidget);

      // Real browser/native auth cannot run in widget tests, so toggle signed-in state
      // through AppScope and close the sign-in surface to verify the signed-in
      // UI surfaces.
      final appContext = tester.element(find.text('Welcome to Erebrus AI'));
      AppScope.of(appContext).signIn();
      Navigator.of(appContext).pop();
      await tester.pumpAndSettle();

      // Back on settings, signed in now.
      expect(find.text('Erebrus account'), findsOneWidget);
      expect(find.text('Create an organization'), findsOneWidget);

      // Org node card appears in models network tab.
      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('NETWORK · 0'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No models shared with this workspace'), findsOneWidget);

      // Sign out restores guest state.
      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Sign out').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Unlock private models & workspaces'), findsOneWidget);
    });

    testWidgets('model picker opens as dialog', (tester) async {
      await pumpApp(tester, const Size(1280, 800));
      await tester.tap(find.text('Select model'));
      await tester.pumpAndSettle();
      expect(find.text('SWITCH MODEL'), findsOneWidget);
      expect(find.text('No downloaded models'), findsOneWidget);
    });

    testWidgets('chat sessions can be permanently deleted', (tester) async {
      await pumpApp(tester, const Size(1280, 800));
      final before = ChatService.instance.sessions.length;
      await tester.tap(find.text('NEW'));
      await tester.pumpAndSettle();
      expect(ChatService.instance.sessions, hasLength(before + 1));

      await tester.tap(find.byTooltip('Delete chat').first);
      await tester.pumpAndSettle();
      expect(find.text('Delete chat?'), findsOneWidget);
      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();

      expect(ChatService.instance.sessions, hasLength(before));
    });
  });

  group('mobile 390x844', () {
    testWidgets('story skip still requires default-model setup', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, const Size(390, 844));
      expect(find.text('01 / PRIVATE AI'), findsOneWidget);

      await tester.tap(find.text('SKIP'));
      await tester.pumpAndSettle();
      expect(find.text('04 / INSTALL YOUR ON-DEVICE AI'), findsOneWidget);
      expect(find.text('START USING EREBRUS AI'), findsOneWidget);
      expect(find.text('CONTINUE WITHOUT LOCAL AI'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.setMockInitialValues({'onboarding_complete': true});
      await pumpApp(tester, const Size(390, 844));
      expect(find.text('01 / PRIVATE AI'), findsOneWidget);
    });

    testWidgets('shell content clears the system status bar', (tester) async {
      await pumpApp(tester, const Size(390, 844), topPadding: 48);

      expect(
        tester.getTopLeft(find.text('Select model')).dy,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('onboarding pages end in required model setup', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, const Size(390, 844));

      expect(find.text('01 / PRIVATE AI'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('02 / ONE NETWORK'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('03 / GUEST FIRST'), findsOneWidget);
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      expect(find.text('04 / INSTALL YOUR ON-DEVICE AI'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
      expect(find.text('START USING EREBRUS AI'), findsOneWidget);
      expect(find.text('CONTINUE WITHOUT LOCAL AI'), findsNothing);
    });

    testWidgets('models tabs, settings, and sign-in page', (tester) async {
      await pumpApp(tester, const Size(390, 844));

      // Configured setup opens the shell; switch to local models.
      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.textContaining('LOCAL ·'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('STORAGE · 0 MB USED'), findsOneWidget);
      expect(find.text('No Erebrus nodes discovered'), findsOneWidget);
      await tester.tap(find.text('IMPORT'));
      await tester.pumpAndSettle();
      expect(find.text('Import local model'), findsOneWidget);
      expect(find.text('GGUF model file'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Connections'), findsOneWidget);
      await tester.tap(find.text('Local server'));
      await tester.pumpAndSettle();
      expect(find.text('Serve on local network'), findsOneWidget);
      expect(find.text('Default · ErebrusAI/models'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();
      expect(find.text('Maximum response length'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      // Sign-in is a full-screen page with guest escape.
      await tester.tap(find.text('SIGN IN / REGISTER'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Erebrus AI'), findsOneWidget);
      await tester.tap(find.text('CONTINUE AS GUEST'));
      await tester.pumpAndSettle();
      expect(find.text('Unlock private models & workspaces'), findsOneWidget);
    });
  });

  group('responsive edge cases', () {
    testWidgets('compact phone onboarding and primary tabs do not overflow', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, const Size(320, 568));
      expect(find.text('01 / PRIVATE AI'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('SKIP'));
      await tester.pumpAndSettle();
      expect(find.text('04 / INSTALL YOUR ON-DEVICE AI'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.setMockInitialValues({
        'onboarding_complete': true,
        'default_model_id': 'smollm2-135m-instruct',
        'default_model_variant_id': 'smollm2-135m-instruct-gguf-q8_0',
      });
      await pumpApp(tester, const Size(320, 568));
      expect(find.text('CHAT'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('TRANSCRIBE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Transcribe'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Models'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text phone shell remains usable', (tester) async {
      await pumpApp(tester, const Size(320, 568), textScaleFactor: 1.4);
      expect(find.text('CHAT'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('TRANSCRIBE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Transcribe'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Models'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow desktop uses compact navigation without overflow', (
      tester,
    ) async {
      await pumpApp(tester, const Size(900, 600));
      expect(find.text('CHAT'), findsOneWidget);
      expect(find.text('SESSIONS'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('TRANSCRIBE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Transcribe'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Models'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('minimum desktop width renders every primary screen', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1024, 640));
      expect(find.text('SESSIONS'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('TRANSCRIBE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Transcribe'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('MODELS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Models'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('SETTINGS'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text onboarding remains usable', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, const Size(320, 568), textScaleFactor: 1.4);
      expect(find.text('01 / PRIVATE AI'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('SKIP'));
      await tester.pumpAndSettle();
      expect(find.text('04 / INSTALL YOUR ON-DEVICE AI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
