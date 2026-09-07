import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/inference_service.dart';
import '../services/local_server_service.dart';
import '../services/node_discovery_service.dart';
import 'platform_capabilities.dart';

/// Adds the Erebrus AI menu-bar/system-tray icon on desktop platforms.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell>
    with TrayListener, WindowListener {
  static const _macOSTrayIcon = 'assets/icons/tray/tray_icon_template.png';
  static const _macOSInactiveTrayIcon =
      'assets/icons/tray/tray_icon_inactive.png';
  static const _windowsTrayIcon = 'assets/icons/tray/tray_icon.ico';
  static const _windowsInactiveTrayIcon =
      'assets/icons/tray/tray_icon_inactive.ico';
  static const _linuxTrayIcon = 'assets/icons/tray/tray_icon.png';
  static const _linuxInactiveTrayIcon =
      'assets/icons/tray/tray_icon_inactive_desktop.png';

  bool _initialized = false;
  bool? _displayedActiveState;
  Future<void> _stateUpdate = Future.value();

  @override
  void initState() {
    super.initState();
    if (!PlatformCapabilities.supportsTray) return;
    trayManager.addListener(this);
    windowManager.addListener(this);
    InferenceService.instance.addListener(_onInferenceChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await windowManager.ensureInitialized();
      // A tray-owned app should never have a second launcher in the Dock or
      // taskbar. On macOS this switches the process to accessory mode; the
      // native LSUIElement setting also prevents a Dock icon from flashing
      // briefly before Flutter has initialized.
      //
      // skipTaskbar has to be applied through waitUntilReadyToShow: on Windows
      // that is the only call which constructs the ITaskbarList3 COM instance
      // the native SetSkipTaskbar dereferences, so invoking it directly aborts
      // the process with an access violation. The call is a no-op on macOS and
      // Linux.
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(skipTaskbar: true),
      );
      await windowManager.setPreventClose(true);
      _initialized = true;
      await _syncInferenceState(force: true);
      debugPrint('[Desktop] Erebrus AI tray ready');
    } on Object catch (error) {
      debugPrint('[Desktop] tray initialization failed: $error');
    }
  }

  @override
  void dispose() {
    if (PlatformCapabilities.supportsTray) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      InferenceService.instance.removeListener(_onInferenceChanged);
    }
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(_showWindow());
      case 'hide':
        unawaited(windowManager.hide());
      case 'quit':
        unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    unawaited(windowManager.hide());
  }

  void _onInferenceChanged() {
    if (!_initialized) return;
    _stateUpdate = _stateUpdate.then((_) => _syncInferenceState()).onError((
      error,
      _,
    ) {
      debugPrint('[Desktop] tray state update failed: $error');
    });
  }

  Future<void> _syncInferenceState({bool force = false}) async {
    final active = InferenceService.instance.hasLoadedModel;
    if (!force && _displayedActiveState == active) return;

    if (Platform.isMacOS) {
      await trayManager.setIcon(
        active ? _macOSTrayIcon : _macOSInactiveTrayIcon,
        isTemplate: active,
        iconSize: 18,
      );
    } else if (Platform.isWindows) {
      await trayManager.setIcon(
        active ? _windowsTrayIcon : _windowsInactiveTrayIcon,
      );
    } else {
      await trayManager.setIcon(
        active ? _linuxTrayIcon : _linuxInactiveTrayIcon,
      );
    }

    final status = active ? 'Model active' : 'No model loaded';
    await trayManager.setToolTip('Erebrus AI — $status');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'status', label: status, disabled: true),
          MenuItem.separator(),
          MenuItem(key: 'open', label: 'Open Erebrus AI'),
          MenuItem(key: 'hide', label: 'Hide window'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit Erebrus AI'),
        ],
      ),
    );
    _displayedActiveState = active;
    debugPrint('[Desktop] tray state: ${active ? 'active' : 'inactive'}');
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    try {
      await InferenceService.instance.unload();
      await LocalServerService.instance.stop();
      await NodeDiscoveryService.instance.stop();
    } on Object catch (error) {
      debugPrint('[Desktop] shutdown cleanup failed: $error');
    } finally {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
