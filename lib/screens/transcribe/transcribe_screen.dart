import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/transcription_session.dart';
import '../../services/chat_service.dart';
import '../../services/transcript_prompt_template_service.dart';
import '../../services/transcription_contract.dart';
import '../../services/transcription_service.dart';
import '../../services/voice_preferences.dart';
import '../../services/whisper_model_manager.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/adaptive_row.dart';
import '../../widgets/ere_controls.dart';

@visibleForTesting
bool shouldShowWhisperRuntime({
  required bool checking,
  required bool speechReady,
  required bool whisperReady,
}) => !checking && !speechReady;

const transcriptionLocales = <String, String>{
  'auto': 'Auto (device language)',
  'en-US': 'English (US)',
  'en-GB': 'English (UK)',
  'es-ES': 'Spanish',
  'fr-FR': 'French',
  'de-DE': 'German',
  'hi-IN': 'Hindi',
  'ja-JP': 'Japanese',
  'ko-KR': 'Korean',
  'zh-CN': 'Chinese (Simplified)',
  'pt-BR': 'Portuguese (Brazil)',
  'ar-SA': 'Arabic',
};

@visibleForTesting
Widget analysisPromptDialogForTest(String transcript) =>
    _AnalysisPromptDialog(transcript: transcript);

class TranscribeScreen extends StatefulWidget {
  const TranscribeScreen({
    super.key,
    required this.wide,
    required this.onOpenChat,
    required this.onOpenModels,
  });

  final bool wide;
  final VoidCallback onOpenChat;
  final VoidCallback onOpenModels;

  @override
  State<TranscribeScreen> createState() => _TranscribeScreenState();
}

class _TranscribeScreenState extends State<TranscribeScreen>
    with WidgetsBindingObserver {
  final _service = TranscriptionService.instance;
  bool _speechReady = false;
  bool _whisperReady = false;
  bool _checkingReadiness = true;
  String _selectedLocale = VoicePreferences.instance.locale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.initialize();
    TranscriptPromptTemplateService.instance.load();
    // This tab stays mounted, so follow Settings → Voice changes live.
    VoicePreferences.instance.addListener(_onVoicePreferencesChanged);
    WhisperModelManager.selectedSpecId.addListener(_refreshReadiness);
    for (final spec in WhisperModelManager.specs) {
      WhisperModelManager.forSpec(spec).addListener(_onWhisperModelChanged);
    }
    _refreshReadiness();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VoicePreferences.instance.removeListener(_onVoicePreferencesChanged);
    WhisperModelManager.selectedSpecId.removeListener(_refreshReadiness);
    for (final spec in WhisperModelManager.specs) {
      WhisperModelManager.forSpec(spec).removeListener(_onWhisperModelChanged);
    }
    super.dispose();
  }

  DictationEngine _engine = VoicePreferences.instance.engine;

  void _onVoicePreferencesChanged() {
    final prefs = VoicePreferences.instance;
    var changed = false;
    // Never switch language under an active recording.
    if (prefs.locale != _selectedLocale && !_service.hasUnfinishedRecording) {
      _selectedLocale = prefs.locale;
      changed = true;
    }
    if (prefs.engine != _engine) {
      _engine = prefs.engine;
      changed = true;
    }
    if (changed) _refreshReadiness();
  }

  /// Re-checks readiness when a speech-model download, delete or rollback
  /// completes. Managers also notify on every download chunk; skip those.
  void _onWhisperModelChanged() {
    if (WhisperModelManager.instance.downloading) return;
    _refreshReadiness();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused) &&
        _service.state == TranscriptionUiState.recording) {
      // Never leave the microphone recording invisibly after the app is
      // backgrounded. Resuming remains an explicit user action.
      _service.pause();
    }
  }

  Future<void> _refreshReadiness() async {
    if (mounted) setState(() => _checkingReadiness = true);
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      if (!mounted) return;
      setState(() {
        _speechReady = false;
        _whisperReady = false;
        _checkingReadiness = false;
      });
      return;
    }
    // Mirror TranscriptionService.start(): system speech only counts when
    // the chosen engine allows it; Whisper only when the engine can use it.
    final engine = VoicePreferences.instance.engine;
    var speechReady = false;
    if (engine != DictationEngine.whisper) {
      try {
        final probe = await _service.probe(locale: _selectedLocale);
        speechReady = probe.available && probe.localeSupported;
      } on Object {
        speechReady = false;
      }
    }
    final whisper =
        engine != DictationEngine.system &&
        await WhisperModelManager.instance.installedPath() != null;
    if (!mounted) return;
    setState(() {
      _speechReady = speechReady;
      _whisperReady = whisper;
      _checkingReadiness = false;
    });
  }

  Future<void> _setupTranscription() async {
    if (_speechReady || _whisperReady) return;
    try {
      await WhisperModelManager.instance.install();
      await _refreshReadiness();
    } on WhisperDownloadCancelled {
      await _refreshReadiness();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription setup failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _service,
        WhisperModelManager.instance,
        WhisperModelManager.selectedSpecId,
      ]),
      builder: (context, _) {
        final content = _RecorderPane(
          service: _service,
          onAnalyze: _analyze,
          checkingReadiness: _checkingReadiness,
          speechReady: _speechReady,
          whisperReady: _whisperReady,
          onSetup: _setupTranscription,
          wide: widget.wide,
          locale: _selectedLocale,
          onLocaleChanged: (locale) {
            setState(() => _selectedLocale = locale);
            VoicePreferences.instance.setLocale(locale);
            _refreshReadiness();
          },
        );
        if (widget.wide) {
          return Row(
            children: [
              SizedBox(width: 286, child: _SessionList(service: _service)),
              const VerticalDivider(width: 1, color: AppColors.stroke),
              Expanded(child: content),
            ],
          );
        }
        return content;
      },
    );
  }

  Future<void> _analyze(TranscriptionSession session) async {
    await _service.stopPlayback();
    if (!mounted) return;
    if (!AppScope.of(context).isSelectedModelReady) {
      final chooseModel = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Download a chat model first'),
          content: const Text(
            'Transcription does not need a chat model, but Analyze does. '
            'Choose a downloaded model before preparing the analysis draft.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('NOT NOW'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('CHOOSE MODEL'),
            ),
          ],
        ),
      );
      if (chooseModel == true) widget.onOpenModels();
      return;
    }
    final prompt = await showDialog<String>(
      context: context,
      builder: (context) =>
          _AnalysisPromptDialog(transcript: session.effectiveTranscript),
    );
    if (prompt == null || prompt.isEmpty) return;
    final chatId = await ChatService.instance.prepareDraft(prompt);
    await _service.linkAnalysisChat(chatId);
    widget.onOpenChat();
  }
}

class _AnalysisPromptDialog extends StatefulWidget {
  const _AnalysisPromptDialog({required this.transcript});

  final String transcript;

  @override
  State<_AnalysisPromptDialog> createState() => _AnalysisPromptDialogState();
}

class _AnalysisPromptDialogState extends State<_AnalysisPromptDialog> {
  late final TextEditingController _controller;
  late TranscriptPromptTemplate _selected;

  @override
  void initState() {
    super.initState();
    _selected = TranscriptPromptTemplateService.builtIns.first;
    _controller = TextEditingController(
      text: _selected.promptFor(widget.transcript),
    );
  }

  @override
  Widget build(BuildContext context) {
    final templateService = TranscriptPromptTemplateService.instance;
    final media = MediaQuery.of(context);
    final compactHeight =
        media.size.height -
            media.viewInsets.bottom -
            media.viewPadding.vertical <
        560;
    return AnimatedBuilder(
      animation: templateService,
      builder: (context, _) => AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        title: const Text('Prepare analysis prompt'),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Nothing is sent or analyzed until you open this editable draft in Chat.',
                style: AppText.grotesk(12, color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selected.id,
                decoration: const InputDecoration(
                  labelText: 'Prompt template',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final template in templateService.templates)
                    DropdownMenuItem(
                      value: template.id,
                      child: Text(template.name),
                    ),
                ],
                onChanged: (id) {
                  final template = templateService.templates.firstWhere(
                    (candidate) => candidate.id == id,
                  );
                  setState(() {
                    _selected = template;
                    _controller.text = template.promptFor(widget.transcript);
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                minLines: compactHeight ? 4 : 8,
                maxLines: compactHeight ? 6 : 16,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Edit the prompt before opening Chat',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!_selected.builtIn)
            TextButton(
              onPressed: () async {
                await templateService.delete(_selected.id);
                if (!mounted) return;
                setState(() {
                  _selected = TranscriptPromptTemplateService.builtIns.first;
                  _controller.text = _selected.promptFor(widget.transcript);
                });
              },
              child: const Text('DELETE TEMPLATE'),
            ),
          TextButton(
            onPressed: _saveTemplate,
            child: const Text('SAVE TEMPLATE'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () {
              final prompt = _controller.text.trim();
              if (prompt.isNotEmpty) Navigator.pop(context, prompt);
            },
            child: const Text('OPEN IN CHAT'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTemplate() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save local template'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Template name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    final instruction = _controller.text
        .split('\n\n--- TRANSCRIPT ---\n')
        .first
        .trim();
    final created = await TranscriptPromptTemplateService.instance.add(
      name: name,
      instruction: instruction,
    );
    if (!mounted) return;
    setState(() => _selected = created);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _RecorderPane extends StatelessWidget {
  const _RecorderPane({
    required this.service,
    required this.onAnalyze,
    required this.checkingReadiness,
    required this.speechReady,
    required this.whisperReady,
    required this.onSetup,
    required this.wide,
    required this.locale,
    required this.onLocaleChanged,
  });

  final TranscriptionService service;
  final ValueChanged<TranscriptionSession> onAnalyze;
  final bool checkingReadiness;
  final bool speechReady;
  final bool whisperReady;
  final Future<void> Function() onSetup;
  final bool wide;
  final String locale;
  final ValueChanged<String> onLocaleChanged;

  @override
  Widget build(BuildContext context) {
    final current = service.current;
    final recording = service.isCapturing;
    final busy = service.hasUnfinishedRecording;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Transcribe', style: AppText.screenTitle()),
                    const SizedBox(height: 4),
                    Text(
                      'On-device speech to text. No analysis runs automatically.',
                      style: AppText.grotesk(
                        13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (current != null && !busy)
                GhostButton(
                  'NEW',
                  icon: Symbols.add,
                  onTap: service.newSession,
                ),
            ],
          ),
          const SizedBox(height: 18),
          _TranscriptionReadinessCard(
            checking: checkingReadiness,
            speechReady: speechReady,
            whisperReady: whisperReady,
            onSetup: onSetup,
          ),
          const SizedBox(height: 12),
          _LanguageSelector(
            value: locale,
            enabled: !busy,
            onChanged: onLocaleChanged,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlowDot(
                      color: recording ? AppColors.danger : AppColors.success,
                      glow: recording,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _stateLabel(service.state),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.mono(
                              11,
                              weight: FontWeight.w600,
                              color: recording
                                  ? AppColors.danger
                                  : AppColors.textSecondary,
                            ),
                          ),
                          if (busy) ...[
                            const SizedBox(height: 3),
                            Text(
                              service.activeBackend ==
                                      TranscriptionBackendKind.whisperCpp
                                  ? 'WHISPER.CPP · ON DEVICE'
                                  : 'SPEECHANALYZER · ON DEVICE',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.mono(
                                9.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _duration(service.elapsed),
                      style: AppText.mono(
                        20,
                        weight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  constraints: const BoxConstraints(
                    minHeight: 180,
                    maxHeight: 380,
                  ),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: current != null && !busy
                      ? SingleChildScrollView(
                          child: _StoredTranscript(
                            session: current,
                            position: service.playbackPosition,
                            onSeek: service.seekCurrent,
                          ),
                        )
                      : _LiveTranscript(service: service),
                ),
                if (service.state == TranscriptionUiState.failed ||
                    (service.state == TranscriptionUiState.paused &&
                        service.error.isNotEmpty)) ...[
                  const SizedBox(height: 12),
                  Text(
                    service.error,
                    style: AppText.grotesk(12.5, color: AppColors.danger),
                  ),
                ],
                const SizedBox(height: 16),
                _RecordingControls(
                  service: service,
                  ready: speechReady || whisperReady,
                  checking: checkingReadiness,
                  onSetup: onSetup,
                  locale: locale,
                ),
              ],
            ),
          ),
          if (current != null && !busy) ...[
            const SizedBox(height: 14),
            _SessionActions(
              service: service,
              session: current,
              onAnalyze: () => onAnalyze(current),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.accent.withA(0.06),
              border: Border.all(color: AppColors.accent.withA(0.22)),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Text(
              'Audio is saved with each session so you can replay it against '
              'the raw transcript. Nothing is uploaded by this workflow.',
              style: AppText.grotesk(
                12.5,
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (shouldShowWhisperRuntime(
            checking: checkingReadiness,
            speechReady: speechReady,
            whisperReady: whisperReady,
          ))
            const _WhisperRuntimeCard(),
          if (!wide && service.sessions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('RECENT SESSIONS', style: AppText.sectionHeader()),
            const SizedBox(height: 8),
            _MobileSessionSearch(service: service),
          ],
        ],
      ),
    );
  }
}

class _TranscriptionReadinessCard extends StatelessWidget {
  const _TranscriptionReadinessCard({
    required this.checking,
    required this.speechReady,
    required this.whisperReady,
    required this.onSetup,
  });

  final bool checking;
  final bool speechReady;
  final bool whisperReady;
  final Future<void> Function() onSetup;

  @override
  Widget build(BuildContext context) {
    final manager = WhisperModelManager.instance;
    final spec = manager.spec;
    final ready = speechReady || whisperReady;
    final title = manager.downloading
        ? 'Downloading ${spec.displayName}…'
        : checking
        ? 'Checking transcription engine…'
        : speechReady
        ? 'SpeechAnalyzer ready'
        : whisperReady
        ? '${spec.displayName} ready'
        : 'Transcription setup required';
    final detail = manager.downloading
        ? '${(manager.progress * 100).clamp(0, 100).toStringAsFixed(0)}% of ${spec.sizeLabel} · verified before activation'
        : checking
        ? 'Verifying private on-device speech support.'
        : speechReady
        ? 'Uses Apple on-device speech assets. No chat model is required.'
        : whisperReady
        ? 'Uses the verified local Whisper model. No chat model is required.'
        : 'SpeechAnalyzer is unavailable here. Download the verified '
              '${spec.sizeLabel} ${spec.displayName} model before recording '
              '(change it in Settings → Voice). No chat model is required.';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ready
            ? AppColors.success.withA(0.06)
            : AppColors.warn.withA(0.06),
        border: Border.all(
          color: ready
              ? AppColors.success.withA(0.25)
              : AppColors.warn.withA(0.28),
        ),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          if (checking || manager.downloading)
            const SizedBox(
              width: 19,
              height: 19,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            )
          else
            Icon(
              ready ? Symbols.check_circle : Symbols.download,
              size: 20,
              color: ready ? AppColors.success : AppColors.warn,
            ),
          const SizedBox(width: 11),
          Expanded(
            child: () {
              final text = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.grotesk(13, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: AppText.grotesk(
                      11.5,
                      color: AppColors.textMuted,
                      height: 1.35,
                    ),
                  ),
                ],
              );
              final action = manager.downloading
                  ? GhostButton(
                      'CANCEL',
                      icon: Symbols.close,
                      onTap: manager.cancelDownload,
                    )
                  : !checking && !ready
                  ? GhostButton(
                      'DOWNLOAD',
                      icon: Symbols.download,
                      onTap: onSetup,
                    )
                  : null;
              // On narrow phones the button drops under the text instead
              // of squeezing the heading onto two lines.
              return action == null
                  ? text
                  : AdaptiveRow(
                      leading: text,
                      trailing: action,
                      gap: 10,
                      minLeadingWidth: 190,
                      stackedAlignment: AlignmentDirectional.centerEnd,
                    );
            }(),
          ),
        ],
      ),
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      // Expanded so long language names ellipsize inside the field instead
      // of overflowing it on narrow phones or with large text.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Spoken language',
        helperText: 'Auto uses your device language; Whisper can auto-detect.',
        prefixIcon: Icon(Symbols.language),
        border: OutlineInputBorder(),
      ),
      items: [
        for (final entry in transcriptionLocales.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: enabled
          ? (value) {
              if (value != null) onChanged(value);
            }
          : null,
    );
  }
}

class _WhisperRuntimeCard extends StatelessWidget {
  const _WhisperRuntimeCard();

  @override
  Widget build(BuildContext context) {
    final manager = WhisperModelManager.instance;
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) => FutureBuilder<String?>(
        future: manager.installedPath(),
        builder: (context, snapshot) {
          final installed = snapshot.data != null;
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                const Icon(
                  Symbols.offline_bolt,
                  color: AppColors.accentHi,
                  size: 21,
                ),
                const SizedBox(width: 11),
                Expanded(
                  // Actions drop under the text on narrow phones rather than
                  // wrapping the model name.
                  child: AdaptiveRow(
                    leading: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${manager.spec.displayName} runtime',
                          style: AppText.grotesk(13, weight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          installed
                              ? manager.updateAvailable
                                    ? 'Verified update available · previous revision stays rollback-ready'
                                    : 'Required on this device · verified · ${manager.spec.sizeLabel} · ${manager.spec.summary.toLowerCase()}'
                              : manager.downloading
                              ? '${(manager.progress * 100).clamp(0, 100).toStringAsFixed(0)}% · checksum verified after download'
                              : 'Required before transcription can start on this device',
                          style: AppText.grotesk(
                            11.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    trailing: installed && manager.updateAvailable
                        ? GhostButton(
                            'UPDATE',
                            icon: Symbols.system_update_alt,
                            onTap: () => _install(context, manager),
                          )
                        : installed && manager.canRollback
                        ? GhostButton(
                            'ROLLBACK',
                            icon: Symbols.history,
                            onTap: () => _rollback(context, manager),
                          )
                        : installed
                        ? const Icon(
                            Symbols.check_circle,
                            color: AppColors.success,
                            size: 20,
                          )
                        : manager.downloading
                        ? GhostButton(
                            'CANCEL',
                            icon: Symbols.close,
                            onTap: manager.cancelDownload,
                          )
                        : GhostButton(
                            'DOWNLOAD',
                            icon: Symbols.download,
                            onTap: () => _install(context, manager),
                          ),
                    gap: 10,
                    minLeadingWidth: 190,
                    stackedAlignment: AlignmentDirectional.centerEnd,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _install(
    BuildContext context,
    WhisperModelManager manager,
  ) async {
    try {
      await manager.install();
    } on WhisperDownloadCancelled {
      return;
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Whisper install failed: $error')));
    }
  }

  Future<void> _rollback(
    BuildContext context,
    WhisperModelManager manager,
  ) async {
    try {
      final rolledBack = await manager.rollback();
      if (!rolledBack) throw StateError('No verified ASR revision to restore');
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ASR rollback failed: $error')));
    }
  }
}

class _LiveTranscript extends StatefulWidget {
  const _LiveTranscript({required this.service});

  final TranscriptionService service;

  @override
  State<_LiveTranscript> createState() => _LiveTranscriptState();
}

class _LiveTranscriptState extends State<_LiveTranscript> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (service.visibleTranscript.isEmpty) {
      return Center(
        child: Text(
          service.state == TranscriptionUiState.preparing
              ? 'Preparing on-device language assets…'
              : 'Tap record and start speaking',
          style: AppText.grotesk(14, color: AppColors.textMuted),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
    return SingleChildScrollView(
      controller: _scrollController,
      child: SelectionArea(
        child: RichText(
          text: TextSpan(
            style: AppText.grotesk(15, height: 1.6),
            children: [
              TextSpan(text: service.finalizedText),
              if (service.partialText.isNotEmpty)
                TextSpan(
                  text:
                      '${service.finalizedText.isEmpty ? '' : ' '}${service.partialText}',
                  style: AppText.grotesk(
                    15,
                    color: AppColors.textMuted,
                    height: 1.6,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoredTranscript extends StatelessWidget {
  const _StoredTranscript({
    required this.session,
    required this.position,
    required this.onSeek,
  });

  final TranscriptionSession session;
  final Duration position;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    if (!session.hasTranscript) {
      return Text(
        'Transcript deleted. The session audio is still available for replay '
        'or sharing.',
        style: AppText.grotesk(14, color: AppColors.textMuted, height: 1.55),
      );
    }
    if (session.segments.isEmpty ||
        session.editState == TranscriptEditState.edited) {
      return SelectableText(
        session.effectiveTranscript,
        style: AppText.grotesk(15, height: 1.6),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 5,
      children: [
        for (final segment in session.segments)
          Semantics(
            button: true,
            label:
                'Play from ${_duration(Duration(milliseconds: segment.startMilliseconds))}',
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () =>
                  onSeek(Duration(milliseconds: segment.startMilliseconds)),
              child: Text(
                segment.text,
                style: AppText.grotesk(
                  15,
                  height: 1.5,
                  color:
                      position.inMilliseconds >= segment.startMilliseconds &&
                          position.inMilliseconds <= segment.endMilliseconds
                      ? AppColors.accent
                      : AppColors.textPrimary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RecordingControls extends StatelessWidget {
  const _RecordingControls({
    required this.service,
    required this.ready,
    required this.checking,
    required this.onSetup,
    required this.locale,
  });

  final TranscriptionService service;
  final bool ready;
  final bool checking;
  final Future<void> Function() onSetup;
  final String locale;

  @override
  Widget build(BuildContext context) {
    return switch (service.state) {
      TranscriptionUiState.recording => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: GhostButton(
                  'PAUSE',
                  icon: Symbols.pause,
                  onTap: service.pause,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: PrimaryCta('STOP & SAVE', onTap: service.stop)),
            ],
          ),
          const SizedBox(height: 9),
          DangerGhostButton(
            'DISCARD RECORDING',
            icon: Symbols.delete,
            onTap: () => _confirmDiscard(context),
          ),
        ],
      ),
      TranscriptionUiState.paused => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: GhostButton(
                  'RESUME',
                  icon: Symbols.play_arrow,
                  onTap: service.resume,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: PrimaryCta('STOP & SAVE', onTap: service.stop)),
            ],
          ),
          const SizedBox(height: 9),
          DangerGhostButton(
            'DISCARD RECORDING',
            icon: Symbols.delete,
            onTap: () => _confirmDiscard(context),
          ),
        ],
      ),
      TranscriptionUiState.preparing ||
      TranscriptionUiState.finalizing => Column(
        children: [
          const LinearProgressIndicator(color: AppColors.accent),
          const SizedBox(height: 10),
          Text(
            service.state == TranscriptionUiState.preparing
                ? 'Preparing the private transcription engine…'
                : service.activeBackend == TranscriptionBackendKind.whisperCpp
                ? 'Transcribing the saved audio on device…'
                : 'Saving transcript and audio…',
            textAlign: TextAlign.center,
            style: AppText.grotesk(12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          DangerGhostButton(
            'CANCEL & DISCARD',
            icon: Symbols.close,
            onTap: () => _confirmDiscard(context),
          ),
        ],
      ),
      _ => PrimaryCta(
        ready ? 'START TRANSCRIPTION' : 'SET UP TRANSCRIPTION',
        enabled: !checking,
        onTap: checking
            ? null
            : ready
            ? () => service.start(locale: locale)
            : onSetup,
      ),
    };
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Discard this recording?'),
        content: const Text(
          'The unfinished transcript and its audio will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('KEEP RECORDING'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DISCARD'),
          ),
        ],
      ),
    );
    if (discard == true) await service.cancel();
  }
}

class _SessionActions extends StatelessWidget {
  const _SessionActions({
    required this.service,
    required this.session,
    required this.onAnalyze,
  });

  final TranscriptionService service;
  final TranscriptionSession session;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    final playbackDuration = service.playbackDuration.inMilliseconds > 0
        ? service.playbackDuration
        : Duration(milliseconds: session.durationMilliseconds);
    final maxMilliseconds = playbackDuration.inMilliseconds.clamp(1, 1 << 31);
    final positionMilliseconds = service.playbackPosition.inMilliseconds.clamp(
      0,
      maxMilliseconds,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (session.audio != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: service.isPlaying ? 'Pause audio' : 'Play audio',
                  onPressed: () => _guard(context, service.playCurrent),
                  icon: Icon(
                    service.isPlaying ? Symbols.pause : Symbols.play_arrow,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: positionMilliseconds.toDouble(),
                    max: maxMilliseconds.toDouble(),
                    onChanged: (value) => service.seekCurrent(
                      Duration(milliseconds: value.round()),
                    ),
                  ),
                ),
                Text(
                  '${_duration(service.playbackPosition)} / ${_duration(playbackDuration)}',
                  style: AppText.mono(10, color: AppColors.textMuted),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<double>(
                  tooltip: 'Playback speed',
                  color: AppColors.surface,
                  onSelected: service.setPlaybackSpeed,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 0.75, child: Text('0.75×')),
                    PopupMenuItem(value: 1, child: Text('1×')),
                    PopupMenuItem(value: 1.25, child: Text('1.25×')),
                    PopupMenuItem(value: 1.5, child: Text('1.5×')),
                    PopupMenuItem(value: 2, child: Text('2×')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '${service.playbackSpeed.toStringAsFixed(service.playbackSpeed == 1 ? 0 : 2)}×',
                      style: AppText.mono(10, color: AppColors.textSecondary),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            if (session.hasTranscript)
              AccentChip(
                'ANALYZE',
                icon: Symbols.auto_awesome,
                onTap: onAnalyze,
              ),
            if (session.hasTranscript)
              AccentChip(
                'EDIT',
                icon: Symbols.edit,
                onTap: () => _edit(context),
              ),
            if (session.hasTranscript &&
                session.editState == TranscriptEditState.edited)
              AccentChip(
                'COMPARE EDITS',
                icon: Symbols.difference,
                onTap: () => _showRaw(context),
              ),
            if (session.hasTranscript)
              AccentChip(
                'COPY',
                icon: Symbols.content_copy,
                onTap: () async {
                  await Clipboard.setData(
                    ClipboardData(text: session.effectiveTranscript),
                  );
                },
              ),
            Builder(
              builder: (shareContext) =>
                  PopupMenuButton<TranscriptionShareKind>(
                    color: AppColors.surface,
                    onSelected: (kind) => _guard(
                      context,
                      () => service.shareCurrent(
                        kind,
                        sharePositionOrigin: _shareOrigin(shareContext),
                      ),
                    ),
                    itemBuilder: (_) => [
                      if (session.hasTranscript)
                        const PopupMenuItem(
                          value: TranscriptionShareKind.transcript,
                          child: Text('Transcript'),
                        ),
                      const PopupMenuItem(
                        value: TranscriptionShareKind.audio,
                        child: Text('Audio'),
                      ),
                      if (session.hasTranscript)
                        const PopupMenuItem(
                          value: TranscriptionShareKind.both,
                          child: Text('Both'),
                        ),
                    ],
                    child: const AccentChip('SHARE', icon: Symbols.share),
                  ),
            ),
            AccentChip(
              'DELETE',
              icon: Symbols.delete,
              onTap: () => _delete(context),
            ),
          ],
        ),
      ],
    );
  }

  Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(text: session.effectiveTranscript);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        title: const Text('Edit transcript'),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: controller,
            minLines: 6,
            maxLines: 16,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SAVE EDIT'),
          ),
        ],
      ),
    );
    final text = controller.text;
    controller.dispose();
    if (save == true) await service.editCurrent(text);
  }

  Future<void> _showRaw(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        title: const Text('Compare transcript edits'),
        content: SizedBox(
          width: 760,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final raw = _ComparisonPane(
                label: 'RAW · ON DEVICE',
                text: session.rawTranscript,
              );
              final edited = _ComparisonPane(
                label: 'YOUR EDIT',
                text: session.effectiveTranscript,
              );
              if (constraints.maxWidth < 650) {
                return Column(
                  children: [raw, const SizedBox(height: 12), edited],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: raw),
                  const SizedBox(width: 12),
                  Expanded(child: edited),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final keepAudio = await showDialog<bool?>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete transcription?'),
        content: const Text(
          'Delete the transcript only and retain audio, or delete the entire session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('KEEP AUDIO'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('DELETE ALL'),
          ),
        ],
      ),
    );
    if (keepAudio != null) await service.deleteCurrent(keepAudio: keepAudio);
  }

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _ComparisonPane extends StatelessWidget {
  const _ComparisonPane({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: AppText.sectionHeader()),
          const SizedBox(height: 8),
          SelectableText(text, style: AppText.grotesk(14, height: 1.55)),
        ],
      ),
    );
  }
}

class _SessionList extends StatefulWidget {
  const _SessionList({required this.service});

  final TranscriptionService service;

  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sessions = widget.service.searchSessions(_query);
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('TRANSCRIPTIONS', style: AppText.sectionHeader()),
          const SizedBox(height: 10),
          Semantics(
            textField: true,
            label: 'Search saved transcripts on this device',
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Search transcripts',
                prefixIcon: Icon(Symbols.search, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No local matches',
                      style: AppText.grotesk(12, color: AppColors.textMuted),
                    ),
                  ),
                for (final session in sessions)
                  _SessionTile(service: widget.service, session: session),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileSessionSearch extends StatefulWidget {
  const _MobileSessionSearch({required this.service});

  final TranscriptionService service;

  @override
  State<_MobileSessionSearch> createState() => _MobileSessionSearchState();
}

class _MobileSessionSearchState extends State<_MobileSessionSearch> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sessions = widget.service.searchSessions(_query);
    return Column(
      children: [
        Semantics(
          textField: true,
          label: 'Search saved transcripts on this device',
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search on this device',
              prefixIcon: Icon(Symbols.search, size: 18),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final session in sessions)
          _SessionTile(service: widget.service, session: session),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'No local matches',
              style: AppText.grotesk(12, color: AppColors.textMuted),
            ),
          ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.service, required this.session});

  final TranscriptionService service;
  final TranscriptionSession session;

  @override
  Widget build(BuildContext context) {
    final active = service.current?.id == session.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          selected: active,
          selectedTileColor: AppColors.surface3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Text(
            session.effectiveTranscript.isEmpty
                ? 'Recording · ${_sessionDate(session.createdAt)}'
                : session.effectiveTranscript,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.grotesk(12.5, weight: FontWeight.w600),
          ),
          subtitle: Text(
            '${_sessionDate(session.createdAt)} · ${session.locale} · '
            '${_duration(Duration(milliseconds: session.durationMilliseconds))}'
            '${session.analysisChatIds.isEmpty ? '' : ' · ${session.analysisChatIds.length} analysis draft${session.analysisChatIds.length == 1 ? '' : 's'}'}',
            style: AppText.mono(9.5, color: AppColors.textMuted),
          ),
          onTap: () => service.selectSession(session),
        ),
      ),
    );
  }
}

String _stateLabel(TranscriptionUiState state) => switch (state) {
  TranscriptionUiState.ready => 'READY · ON DEVICE',
  TranscriptionUiState.preparing => 'PREPARING ASSETS',
  TranscriptionUiState.recording => 'RECORDING · ON DEVICE',
  TranscriptionUiState.paused => 'PAUSED',
  TranscriptionUiState.finalizing => 'FINALIZING',
  TranscriptionUiState.complete => 'SAVED · ON DEVICE',
  TranscriptionUiState.failed => 'ACTION REQUIRED',
};

String _duration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
      : '$minutes:$seconds';
}

String _sessionDate(DateTime value) {
  final local = value.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = local.hour.remainder(12) == 0 ? 12 : local.hour.remainder(12);
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $period';
}
