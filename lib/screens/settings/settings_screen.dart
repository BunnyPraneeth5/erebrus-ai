import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../state/app_state.dart';
import '../../services/backend_probe_service.dart';
import '../../services/device_info_service.dart';
import '../../services/inference_contract.dart';
import '../../services/inference_memory_policy.dart';
import '../../services/inference_service.dart';
import '../../services/local_server_service.dart';
import '../../services/on_device_diagnostics_service.dart';
import '../../services/storage_service.dart';
import '../../services/transcription_service.dart';
import '../../org/ai_org.dart';
import '../../org/org_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/settings_kit.dart';
import '../../widgets/settings_rows.dart';
import '../auth/sign_in.dart';
import '../personas/personas_screen.dart';
import 'connections_settings.dart';
import 'pair_sheet.dart';
import 'tools_settings.dart';
import 'voice_settings.dart';

/// Settings sections, in sidebar order. [keywords] feed the search box so a
/// query like "api key" or "whisper" finds the section that holds it.
enum SettingsSection {
  account(
    'Account',
    Symbols.account_circle,
    'Profile, organizations and invites',
    [
      'profile',
      'sign in',
      'sign out',
      'organization',
      'workspace',
      'referral',
      'invite',
      'xp',
      'wallet',
    ],
  ),
  general(
    'General',
    Symbols.settings,
    'Inference defaults, loaded model and personas',
    [
      'context',
      'response length',
      'tokens',
      'backend',
      'persona',
      'memory',
      'load',
      'offload',
      'unload',
    ],
  ),
  server('Local server', Symbols.dns, 'OpenAI-compatible API and LAN sharing', [
    'api',
    'port',
    'key',
    'pair',
    'qr',
    'lan',
    'serve',
    'network',
    'models folder',
    'mdns',
  ]),
  connections(
    'Connections',
    Symbols.cloud,
    'Remote model servers and cloud providers',
    [
      'llama.cpp',
      'ollama',
      'lm studio',
      'vllm',
      'openai',
      'anthropic',
      'openrouter',
      'endpoint',
      'base url',
      'remote',
      'load',
      'offload',
    ],
  ),
  tools(
    'Tools',
    Symbols.travel_explore,
    'Web search and page reading for models',
    [
      'web',
      'internet',
      'search',
      'searxng',
      'brave',
      'tavily',
      'tool',
      'tool calling',
      'fetch',
      'browse',
    ],
  ),
  voice(
    'Voice',
    Symbols.mic,
    'Microphone, dictation, speech-to-text and read-aloud',
    [
      'dictation',
      'transcription',
      'whisper',
      'speech',
      'microphone',
      'language',
      'tts',
      'read aloud',
      'rate',
      'pitch',
    ],
  ),
  data(
    'Data',
    Symbols.database,
    'On-device transcripts, exports and diagnostics',
    ['export', 'delete', 'transcript', 'diagnostics', 'storage'],
  ),
  about('About', Symbols.help, 'Version and runtime', [
    'version',
    'build',
    'llama',
  ]);

  const SettingsSection(this.title, this.icon, this.subtitle, this.keywords);

  final String title;
  final IconData icon;
  final String subtitle;
  final List<String> keywords;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return title.toLowerCase().contains(q) ||
        subtitle.toLowerCase().contains(q) ||
        keywords.any((keyword) => keyword.contains(q) || q.contains(keyword));
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.wide});

  final bool wide;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  SettingsSection _section = SettingsSection.account;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SettingsSection> get _visibleSections => SettingsSection.values
      .where((section) => section.matches(_search.text))
      .toList();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The two-pane layout needs room for the nav column plus content.
        if (constraints.maxWidth >= 760) return _twoPane();
        return _sectionList(context);
      },
    );
  }

  Widget _twoPane() {
    final visible = _visibleSections;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 248,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: AppColors.stroke)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 22, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsSearchField(
                controller: _search,
                onChanged: (_) => setState(() {
                  final matches = _visibleSections;
                  if (matches.isNotEmpty && !matches.contains(_section)) {
                    _section = matches.first;
                  }
                }),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: Text(
                  'Settings',
                  style: AppText.grotesk(12.5, color: AppColors.textMuted),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final section in visible)
                      _SectionNavItem(
                        section: section,
                        selected: section == _section,
                        onTap: () => setState(() => _section = section),
                      ),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No settings match “${_search.text}”',
                          style: AppText.grotesk(
                            12.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: KeyedSubtree(
                key: ValueKey(_section),
                child: _SectionBody(section: _section, wide: true),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionList(BuildContext context) {
    final app = AppScope.of(context);
    final visible = _visibleSections;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        children: [
          Text('Settings', style: AppText.screenTitle()),
          const SizedBox(height: 4),
          Text(
            'Control local inference, connections, voice, and device storage.',
            style: AppText.grotesk(13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          if (!app.signedIn) ...[
            const _GuestPromoCard(),
            const SizedBox(height: 16),
          ],
          _SettingsSearchField(
            controller: _search,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < visible.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: AppColors.strokeSoft,
                    ),
                  _SectionTile(
                    section: visible[i],
                    onTap: () => openSettingsSection(context, visible[i]),
                  ),
                ],
              ],
            ),
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No settings match “${_search.text}”',
                textAlign: TextAlign.center,
                style: AppText.grotesk(13, color: AppColors.textMuted),
              ),
            ),
          const SizedBox(height: 16),
          const Center(child: _VersionLabel()),
        ],
      ),
    );
  }
}

/// Opens one section as its own page (phones and narrow windows).
void openSettingsSection(BuildContext context, SettingsSection section) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: _SectionBody(section: section, wide: false, showBack: true),
        ),
      ),
    ),
  );
}

class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField({required this.controller, this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final style = AppText.grotesk(13.5, color: AppColors.textPrimary);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(22),
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: style,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search settings…',
        hintStyle: style.copyWith(color: AppColors.textMuted),
        prefixIcon: const Icon(
          Symbols.search,
          size: 18,
          color: AppColors.textMuted,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        border: border(AppColors.stroke),
        enabledBorder: border(AppColors.stroke),
        focusedBorder: border(AppColors.accent),
      ),
    );
  }
}

class _SectionNavItem extends StatelessWidget {
  const _SectionNavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? AppColors.surface3 : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          hoverColor: AppColors.surface2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  section.icon,
                  size: 19,
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.title,
                    style: AppText.grotesk(
                      14,
                      weight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textBody,
                    ),
                  ),
                ),
                if (section == SettingsSection.connections ||
                    section == SettingsSection.tools)
                  const _NavBadge('New'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBadge extends StatelessWidget {
  const _NavBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withA(0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: AppText.grotesk(
          10.5,
          weight: FontWeight.w600,
          color: AppColors.accentHi,
        ),
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section, required this.onTap});

  final SettingsSection section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        child: Row(
          children: [
            Icon(section.icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title,
                    style: AppText.grotesk(14.5, weight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    section.subtitle,
                    style: AppText.grotesk(11.5, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            const Icon(
              Symbols.chevron_right,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrollable body of one section. Connections manages its own sub-pages.
class _SectionBody extends StatelessWidget {
  const _SectionBody({
    required this.section,
    required this.wide,
    this.showBack = false,
  });

  final SettingsSection section;
  final bool wide;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final padding = wide
        ? const EdgeInsets.fromLTRB(36, 28, 36, 32)
        : const EdgeInsets.fromLTRB(18, 12, 18, 28);
    final onBack = showBack ? () => Navigator.of(context).pop() : null;
    if (section == SettingsSection.connections) {
      return ConnectionsSettingsPage(padding: padding, onExit: onBack);
    }
    final header = SettingsPageHeader(
      title: section.title,
      subtitle: section.subtitle,
      onBack: onBack,
    );
    final children = switch (section) {
      SettingsSection.account => _accountSection(context, wide),
      SettingsSection.general => _generalSection(context, wide),
      SettingsSection.server => _serverSection(context),
      SettingsSection.tools => const [ToolsSettingsContent()],
      SettingsSection.voice => const [VoiceSettingsContent()],
      SettingsSection.data => _dataSection(context),
      SettingsSection.about => _aboutSection(context),
      SettingsSection.connections => const <Widget>[],
    };
    return ListView(padding: padding, children: [header, ...children]);
  }
}

// ─── Account ─────────────────────────────────────────────────────────────────

List<Widget> _accountSection(BuildContext context, bool wide) {
  final app = AppScope.of(context);
  if (!app.signedIn) {
    return [
      const _GuestPromoCard(),
      const SizedBox(height: 24),
      const SettingsGroup(
        title: 'Guest mode',
        children: [
          SettingItem(
            title: 'Everything runs without an account',
            description:
                'Chats, downloaded models, personas, connections and transcripts stay on this device.',
          ),
        ],
      ),
    ];
  }
  return [
    const _AccountCard(),
    const SizedBox(height: 26),
    const SettingsGroup(
      title: 'Organizations',
      description: 'Private workspaces for sharing models and personas.',
      children: [_OrganizationsCard()],
    ),
    const SettingsGroup(title: 'Referrals', children: [_ReferralCard()]),
    SettingsGroup(
      children: [
        SettingItem(
          title: 'Sign out',
          titleColor: AppColors.danger,
          description: 'Guest chats, models and personas stay on this device',
          control: PillButton(
            'Sign out',
            icon: Symbols.logout,
            tone: PillTone.danger,
            onTap: app.signOut,
          ),
        ),
      ],
    ),
  ];
}

// ─── General ─────────────────────────────────────────────────────────────────

List<Widget> _generalSection(BuildContext context, bool wide) {
  final app = AppScope.of(context);
  final profile = DeviceInfoService.detect();
  final contextSize = const InferenceMemoryPolicy()
      .plan(device: profile, backend: BackendKind.llamaCpp)
      .contextSize;
  return [
    const SettingsGroup(
      title: 'Model memory',
      description:
          'Keep the chat model resident for fast replies, or offload it to free RAM and VRAM.',
      children: [_LoadedModelItem()],
    ),
    SettingsGroup(
      title: 'Inference',
      children: [
        SettingItem(
          title: 'Context size',
          description:
              'Chosen automatically from this device’s memory so models load safely.',
          control: _ValueText('$contextSize tokens'),
        ),
        SettingItem(
          title: 'Maximum response length',
          description: app.responseTokenOverride == null
              ? 'Using the ${app.selectedPersona} persona default'
              : 'Device override applied to every persona',
          control: PillButton(
            '${app.maxResponseTokens} tokens',
            icon: Symbols.tune,
            onTap: () => _showResponseLengthSheet(context),
          ),
        ),
        AnimatedBuilder(
          animation: BackendProbeService.instance,
          builder: (context, _) {
            final probe = BackendProbeService.instance;
            return SettingItem(
              title: 'Inference backend',
              description: probe.activeDescription,
              control: _ValueText(probe.activeLabel),
            );
          },
        ),
      ],
    ),
    SettingsGroup(
      title: 'Personas',
      children: [
        SettingItem(
          title: 'Manage personas',
          description:
              '${app.selectedPersona} is selected for Chat. Personas set the system prompt and sampling.',
          control: PillButton(
            'Manage',
            onTap: () => _openPersonas(context, wide),
          ),
        ),
      ],
    ),
  ];
}

class _ValueText extends StatelessWidget {
  const _ValueText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) =>
      Text(value, style: AppText.mono(12.5, color: AppColors.textTertiary));
}

/// Shows which local model is resident in memory with load/offload controls.
class _LoadedModelItem extends StatelessWidget {
  const _LoadedModelItem();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedBuilder(
      animation: InferenceService.instance,
      builder: (context, _) {
        final inference = InferenceService.instance;
        final loadedId = inference.hasLoadedModel
            ? inference.activeModelId
            : null;
        final selectedLocal =
            !app.isNetworkModelSelected &&
            app.selectedModelId.isNotEmpty &&
            app.isSelectedModelReady;
        final loadedName = loadedId == null
            ? null
            : loadedId == app.selectedModelId
            ? app.selectedModel
            : loadedId;
        final busy = inference.isLoading;
        return SettingItem(
          title: loadedName ?? 'No model in memory',
          description: busy
              ? 'Loading ${app.selectedModel}…'
              : loadedName != null
              ? inference.isGenerating
                    ? 'Generating a response · offload is available when it finishes'
                    : 'Resident in memory · ready for chat and LAN requests'
              : selectedLocal
              ? 'Preload ${app.selectedModel} so the first reply starts instantly'
              : 'Select a downloaded model in Chat or Models to preload it',
          control: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (loadedName != null)
                const StatePill('LOADED', color: AppColors.success)
              else if (busy)
                const StatePill('LOADING', color: AppColors.warn, pulse: true),
              if (loadedName != null)
                PillButton(
                  'Offload',
                  icon: Symbols.eject,
                  onTap: inference.isGenerating
                      ? null
                      : () => _guard(context, inference.unload),
                )
              else
                PillButton(
                  'Load',
                  icon: Symbols.memory,
                  busy: busy,
                  onTap: selectedLocal
                      ? () => _guard(
                          context,
                          () => inference.load(app.selectedModelId),
                        )
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _guard(BuildContext context, Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

// ─── Local server ────────────────────────────────────────────────────────────

List<Widget> _serverSection(BuildContext context) {
  final app = AppScope.of(context);
  final mobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
  return [
    if (!kIsWeb && Platform.isIOS) ...[
      const SettingsNote(
        'On iOS, stay in the app while serving or downloading. The screen stays on automatically.',
        tone: NoteTone.warn,
        icon: Symbols.info,
      ),
      const SizedBox(height: 18),
    ],
    SettingsGroup(
      title: 'Sharing',
      children: [
        SettingItem(
          title: mobile ? 'Serve while app is open' : 'Serve on local network',
          description: mobile
              ? 'Other devices can use this phone’s models'
              : 'Publish _erebrusai._tcp so other devices find this node',
          control: EreToggle(value: app.serving, onChanged: app.setServing),
        ),
        SettingItem(
          title: 'Server port',
          description:
              'OpenAI-compatible API · /v1/models, /v1/chat/completions, /v1/models/load and /v1/models/unload',
          control: _ValueText(
            app.serving
                ? ':${LocalServerService.instance.port} · running'
                : ':${LocalServerService.instance.port} · stopped',
          ),
        ),
        const _ApiKeyRow(),
      ],
    ),
    const SettingsGroup(title: 'Storage', children: [_ModelsFolderRow()]),
  ];
}

// ─── Data ────────────────────────────────────────────────────────────────────

List<Widget> _dataSection(BuildContext context) {
  final app = AppScope.of(context);
  return [
    SettingsGroup(
      title: 'Transcriptions',
      description: 'Stored only on this device.',
      children: [
        _TranscriptionDataCard(
          defaultModelId: app.defaultModelId,
          defaultVariantId: app.defaultModelVariantId,
        ),
      ],
    ),
  ];
}

// ─── About ───────────────────────────────────────────────────────────────────

List<Widget> _aboutSection(BuildContext context) => [
  SettingsGroup(
    children: [
      const SettingItem(
        title: 'Erebrus AI',
        description:
            'Run AI models locally and chat with them from any device on your network.',
        control: _VersionLabel(),
      ),
      AnimatedBuilder(
        animation: BackendProbeService.instance,
        builder: (context, _) => SettingItem(
          title: 'Runtime',
          description: BackendProbeService.instance.activeDescription,
          control: _ValueText(BackendProbeService.instance.activeLabel),
        ),
      ),
    ],
  ),
];

class _VersionLabel extends StatelessWidget {
  const _VersionLabel();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(
          info == null
              ? 'EREBRUS AI'
              : 'EREBRUS AI ${info.version} (${info.buildNumber})',
          style: AppText.mono(10.5, color: AppColors.textFaint),
        );
      },
    );
  }
}

void _openPersonas(BuildContext context, bool wide) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.textPrimary,
          title: const Text('Personas'),
        ),
        body: PersonasScreen(wide: wide),
      ),
    ),
  );
}

class _TranscriptionDataCard extends StatelessWidget {
  const _TranscriptionDataCard({
    required this.defaultModelId,
    required this.defaultVariantId,
  });

  final String defaultModelId;
  final String defaultVariantId;

  @override
  Widget build(BuildContext context) {
    final service = TranscriptionService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<int>(
          future: service.storageBytes(),
          builder: (context, snapshot) => SettingItem(
            title: 'Transcriptions and session audio',
            description:
                '${service.sessions.length} sessions · ${_formatBytes(snapshot.data ?? 0)} · stored only on this device',
          ),
        ),
        SettingItem(
          title: 'Export transcription data',
          description:
              'Copies transcripts, metadata, and session audio to a folder you choose',
          control: PillButton(
            'Export',
            icon: Symbols.folder_copy,
            onTap: () => _exportTranscriptions(context, service),
          ),
        ),
        SettingItem(
          title: 'On-device diagnostics',
          description:
              'Backend, model, ASR, RAM, and storage status—never transcript text or paths',
          control: PillButton(
            'View',
            icon: Symbols.monitor_heart,
            onTap: () => _showDiagnostics(
              context,
              defaultModelId: defaultModelId,
              defaultVariantId: defaultVariantId,
            ),
          ),
        ),
        SettingItem(
          title: 'Delete all transcription data',
          titleColor: AppColors.danger,
          description:
              'Permanently removes transcripts, indexes, and session audio',
          control: PillButton(
            'Delete',
            icon: Symbols.delete_forever,
            tone: PillTone.danger,
            onTap: () => _deleteTranscriptions(context, service),
          ),
        ),
      ],
    );
  }
}

Future<void> _exportTranscriptions(
  BuildContext context,
  TranscriptionService service,
) async {
  final consent = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Export private transcription data?'),
      content: const Text(
        'The export includes transcript text and any saved session audio. '
        'Choose a folder you control and protect the exported files.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('I UNDERSTAND'),
        ),
      ],
    ),
  );
  if (consent != true || !context.mounted) return;
  final path = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose export destination',
  );
  if (path == null || !context.mounted) return;
  try {
    final exported = await service.exportAll(
      Directory(path),
      userConsented: true,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Exported to ${exported.path}')));
  } on Object catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
  }
}

Future<void> _deleteTranscriptions(
  BuildContext context,
  TranscriptionService service,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete every transcription?'),
      content: const Text(
        'This permanently deletes all transcript text, local search indexes, '
        'metadata, and saved session audio. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('DELETE EVERYTHING'),
        ),
      ],
    ),
  );
  if (confirmed == true) await service.deleteAll();
}

Future<void> _showDiagnostics(
  BuildContext context, {
  required String defaultModelId,
  required String defaultVariantId,
}) async {
  final report = await const OnDeviceDiagnosticsService().collectJson(
    defaultModelId: defaultModelId,
    defaultVariantId: defaultVariantId,
  );
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('On-device diagnostics'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: SelectableText(report, style: AppText.mono(10.5)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('COPY'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

void _showResponseLengthSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surface,
    barrierColor: Colors.black.withA(0.6),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => const _ResponseLengthContent(),
  );
}

class _ResponseLengthContent extends StatelessWidget {
  const _ResponseLengthContent();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final value = app.maxResponseTokens.clamp(128, app.responseTokenLimit);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('MAXIMUM RESPONSE LENGTH', style: AppText.sectionHeader()),
          const SizedBox(height: 10),
          Text(
            'This is the generation ceiling, not a target. Raise it for long answers. Responses can still end normally before reaching it.',
            style: AppText.grotesk(
              12.5,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: value.toDouble(),
                  min: 128,
                  max: app.responseTokenLimit.toDouble(),
                  divisions: (app.responseTokenLimit - 128) ~/ 128,
                  activeColor: AppColors.accent,
                  inactiveColor: AppColors.strokeHi,
                  onChanged: (next) =>
                      app.setMaxResponseTokens((next / 128).round() * 128),
                ),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  '$value',
                  textAlign: TextAlign.right,
                  style: AppText.mono(
                    14,
                    weight: FontWeight.w600,
                    color: AppColors.accentHi,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            app.responseTokenOverride == null
                ? '${app.selectedPersona} currently supplies this value.'
                : 'This device override applies to every persona.',
            style: AppText.grotesk(11.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: GhostButton(
                  'USE PERSONA DEFAULT',
                  onTap: () => app.setMaxResponseTokens(null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryCta(
                  'DONE',
                  glow: false,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuestPromoCard extends StatelessWidget {
  const _GuestPromoCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.accent.withA(0.14), AppColors.accent.withA(0.04)],
        ),
        border: Border.all(color: AppColors.accent.withA(0.3)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Unlock private models & workspaces',
            style: AppText.grotesk(15, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Everything here works without an account. Sign in only to access '
            'models shared privately in your organization — and to share yours.',
            style: AppText.grotesk(
              12.5,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 13),
          PrimaryCta(
            'SIGN IN / REGISTER',
            glow: false,
            padding: const EdgeInsets.all(12),
            onTap: () => openSignIn(context),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final displayName = app.userProfile?.name?.trim().isNotEmpty == true
        ? app.userProfile!.name!.trim()
        : app.userProfile?.email?.trim().isNotEmpty == true
        ? app.userProfile!.email!.trim()
        : 'Erebrus account';
    final wallet = app.walletAddress;
    final initials = _initials(displayName);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment(-0.34, -0.94),
                end: Alignment(0.34, 0.94),
                colors: [AppColors.accentHi, AppColors.accentDeep],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: AppText.mono(
                16,
                weight: FontWeight.w600,
                color: AppColors.onAccent,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: AppText.grotesk(16, weight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  wallet == null ? 'Signed in' : 'Solana · $wallet',
                  style: AppText.mono(12, color: AppColors.textTertiary),
                ),
                if (app.xpEarned case final xp?) ...[
                  const SizedBox(height: 4),
                  Text(
                    '$xp XP',
                    style: AppText.mono(
                      12,
                      weight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withA(0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Symbols.content_copy,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Redeem a referral / invite code. Redeeming credits the referrer with XP on
/// the gateway. The field pre-fills from any captured code (deep links are not
/// wired yet); the APPLY button calls [AppState.redeemReferralCode].
class _ReferralCard extends StatefulWidget {
  const _ReferralCard();

  @override
  State<_ReferralCard> createState() => _ReferralCardState();
}

class _ReferralCardState extends State<_ReferralCard> {
  final _code = TextEditingController();
  String? _syncedCapture;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _apply(AppState app) async {
    final code = _code.text.trim();
    if (code.isEmpty || app.isRedeemingReferral) return;
    FocusScope.of(context).unfocus();
    final ok = await app.redeemReferralCode(code);
    if (ok && mounted) _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedBuilder(
      animation: app.auth,
      builder: (context, _) {
        // Pre-fill from a newly captured code without clobbering user edits.
        final captured = app.capturedReferralCode;
        if (captured != null && captured != _syncedCapture) {
          _syncedCapture = captured;
          _code.text = captured;
        }
        final busy = app.isRedeemingReferral;
        final message = app.referralMessage;
        final error = app.referralError;
        return SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Symbols.redeem,
                        color: AppColors.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Have an invite code?',
                              style: AppText.grotesk(
                                14.5,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Redeem it to reward whoever invited you.',
                              style: AppText.grotesk(
                                12,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _code,
                          enabled: !busy,
                          textInputAction: TextInputAction.done,
                          textCapitalization: TextCapitalization.characters,
                          onSubmitted: (_) => _apply(app),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Referral code',
                            hintText: 'EREBRUS-XXXX',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: busy ? null : () => _apply(app),
                        child: Text(busy ? '…' : 'APPLY'),
                      ),
                    ],
                  ),
                  if (error != null && error.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      error,
                      style: AppText.grotesk(12, color: AppColors.danger),
                    ),
                  ] else if (message != null && message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      style: AppText.grotesk(12, color: AppColors.accent),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OrganizationsCard extends StatelessWidget {
  const _OrganizationsCard();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final org = app.selectedOrg;
    final invite = app.pendingInvites.isNotEmpty
        ? app.pendingInvites.first
        : null;
    return SettingsCard(
      children: [
        if (org != null)
          SettingsRow(
            icon: Symbols.apartment,
            iconColor: AppColors.orgPurple,
            title: org.name,
            subtitle:
                OrgState.sharedFeaturesAvailable
                    ? '${org.isAdmin ? 'Admin' : org.role} · ${app.orgModels.length} shared model${app.orgModels.length == 1 ? '' : 's'}'
                    : '${org.isAdmin ? 'Admin' : org.role} · shared models coming soon',
            trailing: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.orgPurple.withA(0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'PRIVATE',
                  style: AppText.mono(
                    10,
                    weight: FontWeight.w600,
                    color: AppColors.orgPurple,
                    lsEm: 0.08,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Symbols.swap_horiz,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
            onTap: () => _showOrganizationSheet(context),
          )
        else
          SettingsRow(
            icon: Symbols.add_business,
            iconColor: AppColors.accent,
            title: 'Create an organization',
            subtitle: app.orgState.isLoading
                ? 'Loading your organizations…'
                : 'Create a private workspace for shared models',
            onTap: app.orgState.isLoading
                ? null
                : () => _showOrganizationSheet(context),
          ),
        if (invite != null)
          SettingsRow(
            icon: Symbols.mail,
            title: 'Pending invites',
            subtitle:
                '${app.pendingInvites.length} invitation${app.pendingInvites.length == 1 ? '' : 's'} · ${invite.orgName}',
            trailing: const [
              GlowDot(size: 8, color: AppColors.accent, glow: false),
            ],
            onTap: () => _showInviteSheet(context),
          ),
      ],
    );
  }
}

Future<void> _showOrganizationSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _OrganizationSheet(),
  );
}

class _OrganizationSheet extends StatefulWidget {
  const _OrganizationSheet();

  @override
  State<_OrganizationSheet> createState() => _OrganizationSheetState();
}

class _OrganizationSheetState extends State<_OrganizationSheet> {
  final _name = TextEditingController();
  final _slug = TextEditingController();
  bool _creating = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedBuilder(
      animation: app.orgState,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Organization',
                style: AppText.grotesk(22, weight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'Select the workspace used for private models and sharing.',
                style: AppText.grotesk(13, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 18),
              if (_creating)
                _createForm(app)
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final org in app.orgs)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 9),
                            child: _OrganizationRow(
                              org: org,
                              selected: app.selectedOrg?.id == org.id,
                              onTap: () async {
                                await app.orgState.selectOrg(org);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => setState(() => _creating = true),
                            icon: const Icon(Symbols.add),
                            label: const Text('Create new organization'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (app.orgState.error case final error?
                  when error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  error,
                  style: AppText.grotesk(12, color: AppColors.danger),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _createForm(AppState app) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _name,
        enabled: !_busy,
        decoration: const InputDecoration(labelText: 'Organization name'),
        onChanged: (value) {
          if (_slug.text.isEmpty) {
            _slug.text = value
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
                .replaceAll(RegExp(r'^-|-$'), '');
          }
        },
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _slug,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: 'Slug',
          hintText: 'my-org',
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _create(app),
              child: Text(_busy ? 'Creating…' : 'Create'),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _creating = false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ],
  );

  Future<void> _create(AppState app) async {
    final name = _name.text.trim();
    final slug = _slug.text.trim().toLowerCase();
    if (name.isEmpty || slug.isEmpty) return;
    setState(() => _busy = true);
    try {
      await app.orgState.createOrg(name: name, slug: slug);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _OrganizationRow extends StatelessWidget {
  const _OrganizationRow({
    required this.org,
    required this.selected,
    required this.onTap,
  });

  final AiOrg org;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.accent.withA(0.09) : AppColors.surface2,
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: selected ? AppColors.accent.withA(0.45) : AppColors.stroke,
      ),
      borderRadius: BorderRadius.circular(13),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            const Icon(Symbols.apartment, color: AppColors.orgPurple),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    org.name,
                    style: AppText.grotesk(14.5, weight: FontWeight.w600),
                  ),
                  Text(
                    '${org.role} · ${org.planLabel}',
                    style: AppText.mono(11, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Symbols.check_circle, color: AppColors.accent),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showInviteSheet(BuildContext context) async {
  final app = AppScope.of(context);
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pending invites',
            style: AppText.grotesk(22, weight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          for (final invite in app.pendingInvites)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(invite.orgName),
              subtitle: Text(invite.role ?? 'member'),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: () async {
                      await app.auth.declineAccountOrgInvite(invite.id);
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      await app.auth.acceptAccountOrgInvite(invite.id);
                      await app.orgState.refreshOrgs();
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

String _initials(String name) {
  // Emails use the local part; names use the first two words. Guards against
  // empty segments such as ".alex@…" or double spaces.
  final base = name.contains('@') ? name.split('@').first : name;
  final parts = base
      .split(RegExp(r'[\s._-]+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '??';
  if (parts.length >= 2) {
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }
  final word = parts.first;
  return word.substring(0, word.length >= 2 ? 2 : 1).toUpperCase();
}

class _ApiKeyRow extends StatelessWidget {
  const _ApiKeyRow();

  @override
  Widget build(BuildContext context) {
    final server = LocalServerService.instance;
    return FutureBuilder<String>(
      future: server.apiKey,
      builder: (context, snapshot) {
        final key = snapshot.data;
        final masked = key == null
            ? 'Generating secure key…'
            : '${key.substring(0, 7)}••••••${key.substring(key.length - 4)}';
        return SettingItem(
          title: 'API key',
          description:
              'Send as “Authorization: Bearer …”. Pair a phone by QR code.',
          control: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                masked,
                style: AppText.mono(12, color: AppColors.textTertiary),
              ),
              if (key != null)
                _CopySquare(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: key));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('API key copied')),
                      );
                    }
                  },
                ),
              PillButton(
                'Pair',
                icon: Symbols.qr_code_2,
                onTap: () => showPairSheet(context),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModelsFolderRow extends StatelessWidget {
  const _ModelsFolderRow();

  bool get _isSupported => StorageService.supportsCustomModelsDirectory;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final custom = app.usesCustomModelsDirectory;
    return SettingItem(
      title: 'Models folder',
      description: app.modelsDirectoryDisplayLabel,
      control: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_isSupported && custom)
            PillButton(
              'Reset',
              tone: PillTone.subtle,
              onTap: () => _resetModelsFolder(context, app),
            ),
          if (_isSupported)
            PillButton(
              custom ? 'Change' : 'Choose',
              icon: Symbols.folder_open,
              onTap: () => _pickModelsFolder(context, app),
            )
          else
            const _ValueText('Default'),
        ],
      ),
    );
  }

  Future<void> _pickModelsFolder(BuildContext context, AppState app) async {
    if (Platform.isAndroid) {
      final ok = await StorageService.instance.ensurePermissions();
      if (!ok) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Storage permission is needed for a public models folder',
            ),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: StorageService.instance.openSettings,
            ),
          ),
        );
        return;
      }
    }

    // Ensure the current models directory exists before offering to change it.
    await app.refreshModelsDirectory();

    try {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose your models folder',
        initialDirectory: app.modelsDirectory,
      );
      if (picked == null || picked.isEmpty) return;
      if (!context.mounted) return;
      final ok = await app.setModelsDirectory(picked);
      if (!context.mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not use selected folder')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Folder picker failed: $e')));
    }
  }

  Future<void> _resetModelsFolder(BuildContext context, AppState app) async {
    await app.resetModelsDirectory();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Using the default models folder')),
    );
  }
}

class _CopySquare extends StatelessWidget {
  const _CopySquare({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.surface2,
          border: Border.all(color: AppColors.strokeHi),
          borderRadius: BorderRadius.circular(9),
        ),
        child: const Icon(
          Symbols.content_copy,
          size: 16,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
