import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/app_state.dart';
import '../navigation/shell_tab.dart';
import '../services/transcription_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/ere_controls.dart';
import '../widgets/spark_logo.dart';
import 'auth/sign_in.dart';
import 'chat/chat_screen.dart';
import 'models/models_screen.dart';
import 'settings/settings_screen.dart';
import 'transcribe/transcribe_screen.dart';

/// Phones keep bottom navigation. Tablet and desktop windows use a compact
/// left rail, which expands into a workspace sidebar only when room permits.
const kDesktopNavigationBreakpoint = 720.0;
const kWideContentBreakpoint = 1024.0;
const kExpandedSidebarBreakpoint = 1200.0;

enum ShellNavigationMode { bottom, compactRail, expandedSidebar }

@visibleForTesting
ShellNavigationMode shellNavigationModeForWidth(double width) {
  if (width >= kExpandedSidebarBreakpoint) {
    return ShellNavigationMode.expandedSidebar;
  }
  if (width >= kDesktopNavigationBreakpoint) {
    return ShellNavigationMode.compactRail;
  }
  return ShellNavigationMode.bottom;
}

class _NavItem {
  const _NavItem(this.tab, this.label, this.icon);
  final ShellTab tab;
  final String label;
  final IconData icon;
}

const _navItems = [
  _NavItem(ShellTab.chat, 'CHAT', Symbols.chat_bubble),
  _NavItem(ShellTab.transcribe, 'TRANSCRIBE', Symbols.mic),
  _NavItem(ShellTab.models, 'MODELS', Symbols.deployed_code),
  _NavItem(ShellTab.settings, 'SETTINGS', Symbols.tune),
];

class Shell extends StatefulWidget {
  const Shell({super.key, this.initialTab = ShellTab.chat});

  final ShellTab initialTab;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late ShellTab _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
  }

  Future<void> _setTab(ShellTab tab) async {
    if (_tab == tab) return;
    final previousTab = _tab;
    final transcription = TranscriptionService.instance;
    if (previousTab == ShellTab.transcribe &&
        tab != ShellTab.transcribe &&
        transcription.hasUnfinishedRecording) {
      final action = await _confirmLeavingTranscription(transcription);
      if (!mounted || action == null) return;
      switch (action) {
        case _LeaveTranscriptionAction.keepRecording:
          break;
        case _LeaveTranscriptionAction.stopAndSave:
          await transcription.stop();
        case _LeaveTranscriptionAction.discard:
          await transcription.cancel();
      }
    }
    if (previousTab == ShellTab.transcribe && tab != ShellTab.transcribe) {
      await transcription.stopPlayback();
    }
    if (!mounted) return;
    // On-device models stay loaded until the user ejects them (chat header
    // or Settings → General); switching tabs never unloads them.
    setState(() => _tab = tab);
  }

  Future<_LeaveTranscriptionAction?> _confirmLeavingTranscription(
    TranscriptionService service,
  ) => showDialog<_LeaveTranscriptionAction>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(
        service.isCapturing ? 'Recording is active' : 'Transcription is busy',
      ),
      content: Text(
        service.isCapturing
            ? 'Keep recording in the background, stop and save before leaving, or discard this recording.'
            : 'Final preparation or processing is still running. Keep it running or discard this session.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('STAY HERE'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _LeaveTranscriptionAction.discard),
          child: const Text('DISCARD'),
        ),
        if (service.isCapturing)
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _LeaveTranscriptionAction.stopAndSave),
            child: const Text('STOP & SAVE'),
          )
        else
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _LeaveTranscriptionAction.keepRecording),
            child: const Text('KEEP RUNNING'),
          ),
        if (service.isCapturing)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _LeaveTranscriptionAction.keepRecording),
            child: const Text('KEEP RECORDING'),
          ),
      ],
    ),
  );

  Widget _body(bool wide) => IndexedStack(
    index: _tab.index,
    children: [
      ChatScreen(wide: wide),
      TranscribeScreen(
        wide: wide,
        onOpenChat: () => unawaited(_setTab(ShellTab.chat)),
        onOpenModels: () => unawaited(_setTab(ShellTab.models)),
      ),
      ModelsScreen(
        wide: wide,
        initialSubTab: widget.initialTab == ShellTab.models ? 1 : 0,
        onOpenChat: () => unawaited(_setTab(ShellTab.chat)),
      ),
      SettingsScreen(wide: wide),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: TranscriptionService.instance,
      builder: (context, _) {
        // ignore: deprecated_member_use
        return WillPopScope(
          onWillPop: () async {
            if (_tab != ShellTab.chat) {
              await _setTab(ShellTab.chat);
              return false;
            }
            return true;
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final navigationMode = shellNavigationModeForWidth(
                constraints.maxWidth,
              );
              final desktopNavigation =
                  navigationMode != ShellNavigationMode.bottom;
              final expandedSidebar =
                  navigationMode == ShellNavigationMode.expandedSidebar;
              final wideContent =
                  constraints.maxWidth >= kWideContentBreakpoint;
              if (desktopNavigation) {
                return Scaffold(
                  backgroundColor: AppColors.bg,
                  body: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        _Sidebar(
                          tab: _tab,
                          expanded: expandedSidebar,
                          onTab: (tab) => unawaited(_setTab(tab)),
                        ),
                        Expanded(
                          child: _DesktopWorkspaceBackground(
                            child: _bodyWithRecordingIndicator(wideContent),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Scaffold(
                backgroundColor: AppColors.bg,
                body: SafeArea(
                  bottom: false,
                  child: _bodyWithRecordingIndicator(false),
                ),
                bottomNavigationBar: _BottomNav(
                  tab: _tab,
                  onTab: (tab) => unawaited(_setTab(tab)),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _bodyWithRecordingIndicator(bool wide) {
    final service = TranscriptionService.instance;
    return Stack(
      children: [
        _body(wide),
        if (_tab != ShellTab.transcribe && service.hasUnfinishedRecording)
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: () => unawaited(_setTab(ShellTab.transcribe)),
              child: Semantics(
                button: true,
                label: 'Return to active transcription',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withA(0.14),
                    border: Border.all(color: AppColors.danger.withA(0.45)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const GlowDot(color: AppColors.danger, glow: true),
                      const SizedBox(width: 7),
                      Text(
                        service.isCapturing
                            ? 'RECORDING · ${_shellDuration(service.elapsed)}'
                            : 'TRANSCRIPTION BUSY',
                        style: AppText.mono(
                          10,
                          weight: FontWeight.w600,
                          color: AppColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

enum _LeaveTranscriptionAction { keepRecording, stopAndSave, discard }

String _shellDuration(Duration duration) {
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

// ─── Desktop sidebar ─────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.tab,
    required this.expanded,
    required this.onTab,
  });

  final ShellTab tab;
  final bool expanded;
  final ValueChanged<ShellTab> onTab;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: expanded ? 232 : 84,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.stroke)),
      ),
      padding: EdgeInsets.fromLTRB(
        expanded ? 14 : 10,
        18,
        expanded ? 14 : 10,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (expanded)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: LogoLockup(tileSize: 28, fontSize: 12),
            )
          else
            const Center(child: LogoTile(size: 34, radius: 10)),
          SizedBox(height: expanded ? 30 : 24),
          if (expanded) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('WORKSPACE', style: AppText.sectionHeader(size: 9)),
            ),
            const SizedBox(height: 9),
          ],
          for (final item in _navItems)
            Padding(
              padding: EdgeInsets.only(bottom: expanded ? 4 : 7),
              child: _SidebarItem(
                item: item,
                active: item.tab == tab,
                expanded: expanded,
                onTap: () => onTab(item.tab),
              ),
            ),
          const Spacer(),
          if (!expanded)
            _CompactNodeStatus(serving: app.serving)
          else if (tab == ShellTab.settings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) => Text(
                  snapshot.data == null
                      ? 'EREBRUS AI'
                      : 'EREBRUS AI ${snapshot.data!.version} (${snapshot.data!.buildNumber})',
                  style: AppText.mono(9.5, color: AppColors.textFaint),
                ),
              ),
            )
          else ...[
            const _LocalNodeCard(),
            if (!app.signedIn && tab == ShellTab.chat) ...[
              const SizedBox(height: 10),
              const _GuestModeCard(),
            ],
          ],
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.item,
    required this.active,
    required this.expanded,
    required this.onTap,
  });

  final _NavItem item;
  final bool active;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: Tooltip(
        message: expanded ? '' : item.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? 12 : 4,
              vertical: expanded ? 11 : 9,
            ),
            decoration: BoxDecoration(
              color: active ? AppColors.accent.withA(0.12) : Colors.transparent,
              border: Border.all(
                color: active
                    ? AppColors.accent.withA(0.28)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: expanded
                ? Row(
                    children: [
                      _NavIcon(item: item, active: active),
                      const SizedBox(width: 11),
                      Text(item.label, style: _labelStyle()),
                      if (active) ...[
                        const Spacer(),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _NavIcon(item: item, active: active),
                      const SizedBox(height: 5),
                      Text(item.label, maxLines: 1, style: _labelStyle()),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  TextStyle _labelStyle() => AppText.mono(
    expanded ? 11 : 8,
    weight: active ? FontWeight.w600 : FontWeight.w500,
    color: active ? AppColors.accent : AppColors.textSecondary,
    lsEm: expanded ? 0.08 : 0.035,
  );
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.item, required this.active});

  final _NavItem item;
  final bool active;

  @override
  Widget build(BuildContext context) => Icon(
    item.icon,
    size: 20,
    fill: active ? 1 : 0,
    color: active ? AppColors.accent : AppColors.textSecondary,
  );
}

class _CompactNodeStatus extends StatelessWidget {
  const _CompactNodeStatus({required this.serving});

  final bool serving;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: serving ? 'Local node serving on LAN' : 'Local node paused',
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Symbols.dns, size: 21, color: AppColors.textSecondary),
            Positioned(
              right: -4,
              bottom: -3,
              child: GlowDot(
                size: 7,
                color: serving ? AppColors.success : AppColors.textMuted,
                glow: serving,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopWorkspaceBackground extends StatelessWidget {
  const _DesktopWorkspaceBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        gradient: RadialGradient(
          center: Alignment(0.75, -1.15),
          radius: 1.2,
          colors: [Color(0x171F1510), AppColors.bg],
          stops: [0, 0.72],
        ),
      ),
      child: child,
    );
  }
}

class _LocalNodeCard extends StatelessWidget {
  const _LocalNodeCard();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LOCAL NODE',
                style: AppText.mono(
                  10,
                  weight: FontWeight.w600,
                  color: AppColors.textMuted,
                  lsEm: 0.12,
                ),
              ),
              EreToggle(value: app.serving, onChanged: app.setServing),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              GlowDot(
                color: app.serving ? AppColors.success : AppColors.textMuted,
                glow: app.serving,
              ),
              const SizedBox(width: 7),
              Text(
                app.serving ? 'Serving on LAN' : 'Node paused',
                style: AppText.grotesk(12.5, weight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            app.serving ? 'PORT 11434 · MDNS ON' : 'PORT 11434 · MDNS OFF',
            style: AppText.mono(10, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _GuestModeCard extends StatelessWidget {
  const _GuestModeCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent.withA(0.06),
        border: Border.all(color: AppColors.accent.withA(0.25)),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'GUEST MODE',
            style: AppText.mono(
              10,
              weight: FontWeight.w600,
              color: AppColors.accent,
              lsEm: 0.12,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Sign in to use private workspace models.',
            style: AppText.grotesk(
              11.5,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 9),
          PrimaryCta(
            'SIGN IN',
            fontSize: 11,
            radius: 9,
            glow: false,
            padding: const EdgeInsets.all(8),
            onTap: () => openSignIn(context),
          ),
        ],
      ),
    );
  }
}

// ─── Mobile bottom nav ───────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.tab, required this.onTab});

  final ShellTab tab;
  final ValueChanged<ShellTab> onTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg.withA(0.94),
        border: const Border(top: BorderSide(color: AppColors.stroke)),
      ),
      padding: EdgeInsets.only(
        top: 11,
        bottom: MediaQuery.viewPaddingOf(context).bottom + 11,
      ),
      child: Row(
        children: [
          for (final item in _navItems)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTab(item.tab),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item.icon,
                      size: 22,
                      fill: item.tab == tab ? 1 : 0,
                      color: item.tab == tab
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.label,
                      style: AppText.mono(
                        10,
                        weight: FontWeight.w500,
                        color: item.tab == tab
                            ? AppColors.accent
                            : AppColors.textSecondary,
                        lsEm: 0.05,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
