import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop shell keeps the app tray-owned', () {
    final shell = File('lib/platform/desktop_shell.dart').readAsStringSync();

    expect(shell, contains('windowManager.setPreventClose(true)'));
    // The taskbar entry must be suppressed via waitUntilReadyToShow: on
    // Windows that is the only call which constructs the ITaskbarList3 COM
    // instance the native SetSkipTaskbar dereferences. Calling setSkipTaskbar
    // directly aborts the process with an access violation, so assert the
    // direct call never comes back.
    expect(shell, contains('windowManager.waitUntilReadyToShow('));
    expect(shell, contains('WindowOptions(skipTaskbar: true)'));
    expect(shell, isNot(contains('windowManager.setSkipTaskbar(')));
    expect(shell, contains('void onWindowClose()'));
    expect(shell, contains('windowManager.hide()'));
    expect(shell, contains("case 'open':"));
    expect(shell, contains('windowManager.show()'));
  });

  test('macOS runs as a menu-bar accessory and survives window close', () {
    final infoPlist = File(
      'macos/Runner/Info.plist',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final appDelegate = File(
      'macos/Runner/AppDelegate.swift',
    ).readAsStringSync();

    expect(infoPlist, contains('<key>LSUIElement</key>\n\t<true/>'));
    expect(
      appDelegate,
      contains('applicationShouldTerminateAfterLastWindowClosed'),
    );
    expect(appDelegate, contains('return false'));
  });
}
