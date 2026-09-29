import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:record/record.dart';

import '../../services/speech_service.dart';
import '../../services/transcription_service.dart';
import '../../services/voice_preferences.dart';
import '../../services/whisper_model_manager.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/settings_kit.dart';
import '../transcribe/transcribe_screen.dart' show transcriptionLocales;

/// Settings → Voice: dictation engine, local speech model, microphone,
/// language, and read-aloud voice.
class VoiceSettingsContent extends StatefulWidget {
  const VoiceSettingsContent({super.key});

  @override
  State<VoiceSettingsContent> createState() => _VoiceSettingsContentState();
}

class _VoiceSettingsContentState extends State<VoiceSettingsContent> {
  bool? _systemSpeechAvailable;
  bool? _micGranted;
  bool _requestingMic = false;

  @override
  void initState() {
    super.initState();
    _probeSystemSpeech();
    _checkMicrophone();
  }

  /// Reads the current microphone permission without prompting, so the row
  /// reflects reality when the page opens.
  Future<void> _checkMicrophone() async {
    if (_inTest || kIsWeb) return;
    final recorder = AudioRecorder();
    try {
      final granted = await recorder.hasPermission(request: false);
      if (mounted) setState(() => _micGranted = granted);
    } on Object {
      // Unknown: keep offering the request button.
    } finally {
      await recorder.dispose();
    }
  }

  bool get _inTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> _probeSystemSpeech() async {
    if (_inTest || kIsWeb) {
      setState(() => _systemSpeechAvailable = false);
      return;
    }
    var available = false;
    try {
      final probe = await TranscriptionService.instance.probe(
        locale: VoicePreferences.instance.locale,
      );
      available = probe.available;
    } on Object {
      available = false;
    }
    if (mounted) setState(() => _systemSpeechAvailable = available);
  }

  Future<void> _requestMicrophone() async {
    if (_inTest) return;
    setState(() => _requestingMic = true);
    var granted = false;
    final recorder = AudioRecorder();
    try {
      granted = await recorder.hasPermission();
    } on Object {
      granted = false;
    } finally {
      await recorder.dispose();
    }
    if (!mounted) return;
    setState(() {
      _micGranted = granted;
      _requestingMic = false;
    });
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone access is off. Enable it for Erebrus AI in system privacy settings.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        VoicePreferences.instance,
        WhisperModelManager.selectedSpecId,
        WhisperModelManager.instance,
        SpeechService.instance,
      ]),
      builder: (context, _) {
        final prefs = VoicePreferences.instance;
        final speech = SpeechService.instance;
        final systemAvailable = _systemSpeechAvailable ?? false;
        final usesWhisper =
            prefs.engine == DictationEngine.whisper ||
            (prefs.engine == DictationEngine.auto && !systemAvailable);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              title: 'Dictation',
              children: [
                SettingItem(
                  title: 'Dictation engine',
                  description: prefs.engine == DictationEngine.auto
                      ? (_systemSpeechAvailable == null
                            ? 'Checking this device’s speech support…'
                            : systemAvailable
                            ? 'Uses on-device system speech; falls back to local Whisper for unsupported languages.'
                            : 'System speech isn’t available here, so the local Whisper model is used.')
                      : prefs.engine.description,
                  control: EreSelect<DictationEngine>(
                    value: prefs.engine,
                    onChanged: prefs.setEngine,
                    options: [
                      for (final engine in DictationEngine.values)
                        SelectOption(
                          engine,
                          engine.label,
                          description:
                              engine == DictationEngine.system &&
                                  _systemSpeechAvailable == false
                              ? 'Not available on this device'
                              : engine.description,
                          enabled:
                              engine != DictationEngine.system ||
                              _systemSpeechAvailable != false,
                        ),
                    ],
                  ),
                ),
                if (usesWhisper || prefs.engine != DictationEngine.system)
                  const _SpeechModelItem(),
                SettingItem(
                  title: 'Microphone',
                  description: _micGranted == true
                      ? 'Microphone access is allowed'
                      : 'Allow mic access to dictate and record transcriptions',
                  control: _micGranted == true
                      ? const StatePill('ALLOWED', color: AppColors.success)
                      : PillButton(
                          'Allow microphone',
                          icon: Symbols.mic,
                          busy: _requestingMic,
                          onTap: _requestMicrophone,
                        ),
                ),
                SettingItem(
                  title: 'Dictation language',
                  description: usesWhisper && prefs.whisperModel.englishOnly
                      ? 'The selected speech model only recognizes English'
                      : 'Language to recognize',
                  control: EreSelect<String>(
                    value: transcriptionLocales.containsKey(prefs.locale)
                        ? prefs.locale
                        : 'auto',
                    onChanged: prefs.setLocale,
                    options: [
                      for (final entry in transcriptionLocales.entries)
                        SelectOption(entry.key, entry.value),
                    ],
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Read aloud',
              children: [
                SettingItem(
                  title: 'Read aloud button',
                  description: 'Show on assistant responses',
                  control: EreToggle(
                    value: prefs.readAloudEnabled,
                    onChanged: prefs.setReadAloudEnabled,
                  ),
                ),
                if (speech.engines.isNotEmpty)
                  SettingItem(
                    title: 'TTS engine',
                    description:
                        'Install another Android speech engine to see it here',
                    control: EreSelect<String>(
                      value: speech.selectedEngine,
                      onChanged: speech.selectEngine,
                      options: [
                        for (final engine in speech.engines)
                          SelectOption(engine, speech.engineLabel(engine)),
                      ],
                    ),
                  )
                else
                  const SettingItem(
                    title: 'TTS engine',
                    description: 'Built-in device voices',
                    control: _ValueLabel('System voices'),
                  ),
                SettingItem(
                  title: 'Voice',
                  description: speech.isInitialized
                      ? 'Best voices on this device are listed first. Add more in system Spoken Content / Text-to-speech settings.'
                      : 'Loading installed voices…',
                  control: EreSelect<String>(
                    value: speech.selectedVoice?.id ?? '',
                    onChanged: (id) => speech.selectVoice(
                      speech.voices
                          .where((voice) => voice.id == id)
                          .firstOrNull,
                    ),
                    options: [
                      const SelectOption('', 'System default'),
                      for (final voice in speech.voices.take(80))
                        SelectOption(
                          voice.id,
                          voice.name,
                          trailing: voice.locale,
                        ),
                    ],
                  ),
                ),
                SettingItem(
                  title: 'Speaking rate',
                  description: '${speech.rate.toStringAsFixed(2)}×',
                  control: _SliderControl(
                    value: speech.rate,
                    min: 0.2,
                    max: 0.8,
                    onChanged: speech.setRate,
                  ),
                ),
                SettingItem(
                  title: 'Pitch',
                  description: speech.pitch.toStringAsFixed(2),
                  control: _SliderControl(
                    value: speech.pitch,
                    min: 0.5,
                    max: 1.5,
                    onChanged: speech.setPitch,
                  ),
                ),
                SettingItem(
                  title: 'Preview voice',
                  description: 'Hear the current voice, rate and pitch',
                  control: PillButton(
                    speech.isSpeakingMessage('__voice_preview__')
                        ? 'Stop'
                        : 'Preview',
                    icon: speech.isSpeakingMessage('__voice_preview__')
                        ? Symbols.stop
                        : Symbols.play_arrow,
                    onTap: speech.preview,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Speech model picker with download / delete controls for the selection.
class _SpeechModelItem extends StatelessWidget {
  const _SpeechModelItem();

  @override
  Widget build(BuildContext context) {
    final prefs = VoicePreferences.instance;
    final spec = WhisperModelManager.selectedSpec;
    final manager = WhisperModelManager.instance;
    return FutureBuilder<String?>(
      future: manager.installedPath(),
      builder: (context, snapshot) {
        final installed = snapshot.data != null;
        final checking = snapshot.connectionState != ConnectionState.done;
        final Widget status;
        if (manager.downloading) {
          status = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 110,
                child: EreProgressBar(value: manager.progress.clamp(0, 1)),
              ),
              const SizedBox(width: 10),
              Text(
                '${(manager.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: AppText.mono(11, color: AppColors.textTertiary),
              ),
              const SizedBox(width: 10),
              PillButton(
                'Cancel',
                compact: true,
                onTap: manager.cancelDownload,
              ),
            ],
          );
        } else {
          status = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                checking
                    ? 'Checking…'
                    : installed
                    ? 'Downloaded · verified'
                    : 'Not downloaded',
                style: AppText.grotesk(
                  12,
                  color: installed ? AppColors.success : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 12),
              if (installed)
                PillButton(
                  'Delete',
                  compact: true,
                  tone: PillTone.danger,
                  onTap: () => _delete(context, manager),
                )
              else if (!checking)
                PillButton(
                  'Download',
                  compact: true,
                  icon: Symbols.download,
                  onTap: () => _install(context, manager),
                ),
            ],
          );
        }
        return SettingItem(
          title: 'Speech recognition model',
          description:
              '${spec.summary} · ${spec.sizeLabel}. Runs locally and offline; checksum-verified before use.',
          control: EreSelect<String>(
            value: spec.id,
            onChanged: manager.downloading ? null : prefs.setWhisperModel,
            options: [
              for (final option in WhisperModelManager.specs)
                SelectOption(
                  option.id,
                  option.displayName,
                  description: option.summary,
                  trailing: option.sizeLabel,
                ),
            ],
          ),
          below: status,
        );
      },
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Speech model download failed: $error')),
      );
    }
  }

  Future<void> _delete(
    BuildContext context,
    WhisperModelManager manager,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${manager.spec.displayName}?'),
        content: Text(
          'Frees ${manager.spec.sizeLabel}. Local transcription needs a speech model; you can download it again anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed == true) await manager.delete();
  }
}

class _SliderControl extends StatelessWidget {
  const _SliderControl({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          overlayShape: SliderComponentShape.noOverlay,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: AppColors.accent,
          inactiveColor: AppColors.strokeHi,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ValueLabel extends StatelessWidget {
  const _ValueLabel(this.value);

  final String value;

  @override
  Widget build(BuildContext context) =>
      Text(value, style: AppText.grotesk(13.5, color: AppColors.textSecondary));
}
