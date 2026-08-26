import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/app_state.dart';
import '../../services/speech_service.dart';
import '../../services/backend_probe_service.dart';
import '../../services/local_server_service.dart';
import '../../services/on_device_diagnostics_service.dart';
import '../../services/storage_service.dart';
import '../../services/transcription_service.dart';
import '../../org/ai_org.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/settings_rows.dart';
import '../auth/sign_in.dart';
import '../personas/personas_screen.dart';
import 'pair_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final children = <Widget>[
      Text('Settings', style: AppText.screenTitle()),
      const SizedBox(height: 4),
      Text(
        'Control local inference, privacy, voice, and device storage.',
        style: AppText.grotesk(13, color: AppColors.textSecondary),
      ),
      SizedBox(height: wide ? 22 : 16),
      if (app.signedIn) ...[
        const _AccountCard(),
        const SizedBox(height: 14),
        _SectionLabel('ORGANIZATIONS', wide: wide),
        const SizedBox(height: 9),
        const _OrganizationsCard(),
        const SizedBox(height: 14),
        _SectionLabel('REFERRALS', wide: wide),
        const SizedBox(height: 9),
        const _ReferralCard(),
        const SizedBox(height: 14),
        SettingsCard(
          children: [
            SettingsRow(
              icon: Symbols.logout,
              iconColor: AppColors.danger,
              title: 'Sign out',
              titleColor: AppColors.danger,
              subtitle: 'Guest chats, models and personas stay on this device',
              dense: !wide,
              onTap: app.signOut,
            ),
          ],
        ),
      ] else
        const _GuestPromoCard(),
      SizedBox(height: wide ? 20 : 18),
      _SectionLabel('LOCAL SERVER', wide: wide),
      SizedBox(height: wide ? 9 : 8),
      if (!kIsWeb && Platform.isIOS) ...[
        SettingsCard(
          children: [
            SettingsRow(
              icon: Symbols.info,
              iconColor: AppColors.accentHi,
              title: 'Keep Erebrus AI open',
              subtitle:
                  'On iOS, stay in the app while serving or downloading. The screen stays on automatically.',
              dense: !wide,
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (wide)
        SettingsCard(
          children: [
            SettingsRow(
              icon: Symbols.dns,
              title: 'Server port',
              subtitle: 'OpenAI-compatible API on this machine',
              trailing: [
                RowValue('${LocalServerService.instance.port}', chevron: false),
              ],
            ),
            const _ApiKeyRow(dense: false),
            const _ModelsFolderRow(dense: false),
            SettingsRow(
              icon: Symbols.wifi,
              title: 'Serve on local network',
              subtitle:
                  'Publish _erebrusai._tcp so other devices find this node',
              trailing: [
                EreToggle(value: app.serving, onChanged: app.setServing),
              ],
            ),
          ],
        )
      else
        SettingsCard(
          children: [
            SettingsRow(
              icon: Symbols.wifi,
              title: 'Serve while app is open',
              subtitle: 'Other devices can use this phone’s models',
              dense: true,
              trailing: [
                EreToggle(value: app.serving, onChanged: app.setServing),
              ],
            ),
            SettingsRow(
              icon: Symbols.dns,
              title: 'Server port',
              dense: true,
              trailing: [
                RowValue('${LocalServerService.instance.port}', chevron: false),
              ],
            ),
            const _ApiKeyRow(dense: true),
            const _ModelsFolderRow(dense: true),
          ],
        ),
      SizedBox(height: wide ? 20 : 18),
      _SectionLabel('INFERENCE', wide: wide),
      SizedBox(height: wide ? 9 : 8),
      if (wide)
        SettingsCard(
          children: [
            const SettingsRow(
              icon: Symbols.memory,
              title: 'Context size',
              subtitle: 'Default --ctx-size for loaded models',
              trailing: [RowValue('8192')],
            ),
            SettingsRow(
              icon: Symbols.output,
              title: 'Maximum response length',
              subtitle: app.responseTokenOverride == null
                  ? 'Using the active persona default'
                  : 'Override saved on this device',
              trailing: [RowValue('${app.maxResponseTokens}')],
              onTap: () => _showResponseLengthSheet(context),
            ),
            AnimatedBuilder(
              animation: BackendProbeService.instance,
              builder: (context, _) {
                final probe = BackendProbeService.instance;
                return SettingsRow(
                  icon: Symbols.bolt,
                  title: 'Inference backend',
                  subtitle: probe.activeDescription,
                  trailing: [RowValue(probe.activeLabel)],
                );
              },
            ),
          ],
        )
      else
        SettingsCard(
          children: [
            const SettingsRow(
              icon: Symbols.memory,
              title: 'Context size',
              dense: true,
              trailing: [RowValue('2048')],
            ),
            SettingsRow(
              icon: Symbols.output,
              title: 'Maximum response length',
              subtitle: app.responseTokenOverride == null
                  ? '${app.selectedPersona} persona default'
                  : 'Device override',
              dense: true,
              trailing: [RowValue('${app.maxResponseTokens}')],
              onTap: () => _showResponseLengthSheet(context),
            ),
          ],
        ),
      SizedBox(height: wide ? 20 : 18),
      _SectionLabel('PERSONAS', wide: wide),
      SizedBox(height: wide ? 9 : 8),
      SettingsCard(
        children: [
          SettingsRow(
            icon: Symbols.theater_comedy,
            title: 'Manage personas',
            subtitle: '${app.selectedPersona} is selected for Chat',
            dense: !wide,
            trailing: const [RowValue('OPEN')],
            onTap: () => _openPersonas(context, wide),
          ),
        ],
      ),
      SizedBox(height: wide ? 20 : 18),
      _SectionLabel('ON-DEVICE DATA', wide: wide),
      SizedBox(height: wide ? 9 : 8),
      _TranscriptionDataCard(
        dense: !wide,
        defaultModelId: app.defaultModelId,
        defaultVariantId: app.defaultModelVariantId,
      ),
      SizedBox(height: wide ? 20 : 18),
      _SectionLabel('VOICE', wide: wide),
      SizedBox(height: wide ? 9 : 8),
      AnimatedBuilder(
        animation: SpeechService.instance,
        builder: (context, _) {
          final speech = SpeechService.instance;
          return SettingsCard(
            children: [
              SettingsRow(
                icon: Symbols.record_voice_over,
                title: 'Assistant voice',
                subtitle:
                    '${speech.selectedEngineLabel} · ${speech.selectedVoiceLabel}',
                dense: !wide,
                trailing: const [RowValue('CHANGE')],
                onTap: () => showVoiceSettings(context),
              ),
              SettingsRow(
                icon: Symbols.speed,
                title: 'Speech tuning',
                subtitle: 'Rate and pitch are saved on this device',
                dense: !wide,
                trailing: [
                  RowValue(
                    '${speech.rate.toStringAsFixed(2)}× · ${speech.pitch.toStringAsFixed(2)}',
                  ),
                ],
                onTap: () => showVoiceSettings(context),
              ),
            ],
          );
        },
      ),
      if (!wide) ...[
        const SizedBox(height: 16),
        Center(
          child: Text(
            'EREBRUS AI 0.1.0 · LLAMA.CPP B4432',
            style: AppText.mono(9.5, color: AppColors.textFaint),
          ),
        ),
      ],
      const SizedBox(height: 24),
    ];

    if (wide) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            children: children,
          ),
        ),
      );
    }
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        children: children,
      ),
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

void showVoiceSettings(BuildContext context) {
  final wide = MediaQuery.sizeOf(context).width >= 900;
  final content = const _VoiceSettingsContent();
  if (wide) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withA(0.6),
      builder: (_) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.strokeHi),
        ),
        child: SizedBox(width: 480, height: 620, child: content),
      ),
    );
  } else {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black.withA(0.6),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      builder: (_) => content,
    );
  }
}

class _VoiceSettingsContent extends StatelessWidget {
  const _VoiceSettingsContent();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SpeechService.instance,
      builder: (context, _) {
        final speech = SpeechService.instance;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('VOICE', style: AppText.sectionHeader()),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(
                      Symbols.close,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  border: Border.all(color: AppColors.stroke),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Column(
                  children: [
                    _VoiceSlider(
                      label: 'RATE',
                      value: speech.rate,
                      min: 0.2,
                      max: 0.8,
                      display: '${speech.rate.toStringAsFixed(2)}×',
                      onChanged: speech.setRate,
                    ),
                    const SizedBox(height: 12),
                    _VoiceSlider(
                      label: 'PITCH',
                      value: speech.pitch,
                      min: 0.5,
                      max: 1.5,
                      display: speech.pitch.toStringAsFixed(2),
                      onChanged: speech.setPitch,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: AccentChip(
                        speech.isSpeakingMessage('__voice_preview__')
                            ? 'STOP PREVIEW'
                            : 'PREVIEW',
                        icon: speech.isSpeakingMessage('__voice_preview__')
                            ? Symbols.stop
                            : Symbols.play_arrow,
                        onTap: speech.preview,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (speech.engines.isNotEmpty) ...[
                Text('SPEECH ENGINE', style: AppText.sectionHeader()),
                const SizedBox(height: 6),
                Text(
                  'The engine controls voice quality. Install another Android speech engine to make it appear here.',
                  style: AppText.grotesk(
                    11.5,
                    color: AppColors.textMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                for (final engine in speech.engines)
                  _VoiceRow(
                    title: speech.engineLabel(engine),
                    subtitle: engine,
                    selected: speech.selectedEngine == engine,
                    onTap: () => speech.selectEngine(engine),
                  ),
                const SizedBox(height: 14),
              ],
              Text('INSTALLED VOICES', style: AppText.sectionHeader()),
              const SizedBox(height: 6),
              Text(
                'This list comes from your device. Download additional accents in Android Text-to-speech or Apple Spoken Content settings, then reopen this panel.',
                style: AppText.grotesk(
                  11.5,
                  color: AppColors.textMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    _VoiceRow(
                      title: 'System default voice',
                      subtitle: 'Uses the device language and preferred voice',
                      selected: speech.selectedVoice == null,
                      onTap: () => speech.selectVoice(null),
                    ),
                    if (!speech.isInitialized)
                      const Padding(
                        padding: EdgeInsets.all(14),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (speech.voices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          'No selectable voices were reported by the system speech engine.',
                          style: AppText.grotesk(
                            12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      )
                    else
                      for (final voice in speech.voices)
                        _VoiceRow(
                          title: voice.name,
                          subtitle: voice.locale,
                          selected: speech.selectedVoice?.id == voice.id,
                          onTap: () => speech.selectVoice(voice),
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VoiceSlider extends StatelessWidget {
  const _VoiceSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 48, child: Text(label, style: AppText.mono(9.5))),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            activeColor: AppColors.accent,
            inactiveColor: AppColors.strokeHi,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: AppText.mono(10.5, color: AppColors.textTertiary),
          ),
        ),
      ],
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.surface3 : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Symbols.radio_button_checked
                  : Symbols.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.accentHi : AppColors.textMuted,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.grotesk(13, weight: FontWeight.w500),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppText.mono(9.5, color: AppColors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {required this.wide});

  final String label;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Text(label, style: AppText.sectionHeader(size: wide ? 11 : 10.5));
  }
}

class _TranscriptionDataCard extends StatelessWidget {
  const _TranscriptionDataCard({
    required this.dense,
    required this.defaultModelId,
    required this.defaultVariantId,
  });

  final bool dense;
  final String defaultModelId;
  final String defaultVariantId;

  @override
  Widget build(BuildContext context) {
    final service = TranscriptionService.instance;
    return SettingsCard(
      children: [
        FutureBuilder<int>(
          future: service.storageBytes(),
          builder: (context, snapshot) => SettingsRow(
            icon: Symbols.audio_file,
            title: 'Transcriptions and session audio',
            subtitle:
                '${service.sessions.length} sessions · ${_formatBytes(snapshot.data ?? 0)} · stored only on this device',
            dense: dense,
          ),
        ),
        SettingsRow(
          icon: Symbols.folder_copy,
          title: 'Export transcription data',
          subtitle:
              'Copies transcripts, metadata, and session audio to a folder you choose',
          dense: dense,
          trailing: const [RowValue('EXPORT')],
          onTap: () => _exportTranscriptions(context, service),
        ),
        SettingsRow(
          icon: Symbols.delete_forever,
          iconColor: AppColors.danger,
          title: 'Delete all transcription data',
          titleColor: AppColors.danger,
          subtitle:
              'Permanently removes transcripts, indexes, and session audio',
          dense: dense,
          onTap: () => _deleteTranscriptions(context, service),
        ),
        SettingsRow(
          icon: Symbols.monitor_heart,
          title: 'On-device diagnostics',
          subtitle:
              'Backend, model, ASR, RAM, and storage status—never transcript text or paths',
          dense: dense,
          trailing: const [RowValue('VIEW')],
          onTap: () => _showDiagnostics(
            context,
            defaultModelId: defaultModelId,
            defaultVariantId: defaultVariantId,
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
                '${org.isAdmin ? 'Admin' : org.role} · ${app.orgModels.length} shared model${app.orgModels.length == 1 ? '' : 's'}',
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
  if (name.isEmpty) return '??';
  if (name.contains('.')) {
    return name.split('.').first.substring(0, 1).toUpperCase();
  }
  final parts = name.split(' ').where((s) => s.isNotEmpty).toList();
  if (parts.length >= 2) {
    return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
  }
  return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
}

class _ApiKeyRow extends StatelessWidget {
  const _ApiKeyRow({required this.dense});

  final bool dense;

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
        return SettingsRow(
          icon: Symbols.key,
          title: 'API key',
          subtitle: masked,
          subtitleMono: true,
          dense: dense,
          trailing: [
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
            AccentChip(
              'PAIR',
              icon: Symbols.qr_code_2,
              radius: 9,
              fontSize: dense ? 10 : 11,
              iconSize: dense ? 14 : 16,
              padding: EdgeInsets.symmetric(
                horizontal: dense ? 10 : 12,
                vertical: dense ? 7 : 8,
              ),
              onTap: () => showPairSheet(context),
            ),
          ],
        );
      },
    );
  }
}

class _ModelsFolderRow extends StatelessWidget {
  const _ModelsFolderRow({required this.dense});

  final bool dense;

  bool get _isSupported => StorageService.supportsCustomModelsDirectory;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final custom = app.usesCustomModelsDirectory;
    return SettingsRow(
      icon: Symbols.folder,
      title: 'Models folder',
      subtitle: app.modelsDirectoryDisplayLabel,
      subtitleMaxLines: 1,
      dense: dense,
      trailing: [
        if (_isSupported && custom)
          AccentChip(
            'RESET',
            radius: 8,
            fontSize: dense ? 9 : 10,
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 10,
              vertical: dense ? 6 : 7,
            ),
            onTap: () => _resetModelsFolder(context, app),
          ),
        RowValue(
          _isSupported ? (custom ? 'CHANGE' : 'CHOOSE') : 'DEFAULT',
          chevron: false,
        ),
      ],
      onTap: _isSupported ? () => _pickModelsFolder(context, app) : null,
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
