import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/tool_activity.dart';
import '../../services/chat_service.dart';
import '../../services/connection_service.dart';
import '../../services/inference_service.dart';
import '../../services/network_inference_service.dart';
import '../../services/speech_service.dart';
import '../../services/tools/agent_tools.dart';
import '../../services/tools/web_tools.dart';
import '../../services/voice_preferences.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/markdown_view.dart';
import '../../widgets/spark_logo.dart';
import '../settings/settings_screen.dart';
import 'pickers.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (wide) {
      return const Row(
        children: [
          _SessionsColumn(),
          Expanded(child: _ChatPane(wide: true)),
        ],
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      drawer: const Drawer(
        backgroundColor: AppColors.bgElevated,
        width: 300,
        child: SafeArea(child: _SessionsList()),
      ),
      body: const _ChatPane(wide: false),
    );
  }
}

// ─── Sessions ────────────────────────────────────────────────────────────────

class _SessionsColumn extends StatelessWidget {
  const _SessionsColumn();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 252,
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(right: BorderSide(color: AppColors.stroke)),
      ),
      child: const _SessionsList(),
    );
  }
}

class _SessionsList extends StatelessWidget {
  const _SessionsList();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ChatService.instance,
      builder: (context, _) {
        final chat = ChatService.instance;
        final sessions = chat.sessions;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('SESSIONS', style: AppText.sectionHeader()),
                    AccentChip(
                      'NEW',
                      icon: Symbols.add,
                      iconSize: 14,
                      fontSize: 10,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      onTap: () => chat.newSession(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: sessions.isEmpty
                    ? Center(
                        child: Text(
                          'No chats yet',
                          style: AppText.grotesk(
                            13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 3),
                        itemBuilder: (context, i) {
                          final s = sessions[i];
                          final active = chat.activeSessionId == s.id;
                          return GestureDetector(
                            onTap: () => chat.selectSession(s.id),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: active ? AppColors.surface3 : null,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppText.grotesk(
                                            13,
                                            weight: active
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                            color: active
                                                ? AppColors.textPrimary
                                                : AppColors.textSecondary,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          _sessionMeta(s),
                                          style: AppText.mono(
                                            10,
                                            color: active
                                                ? AppColors.textTertiary
                                                : AppColors.textFaint,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete chat',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 17,
                                    color: AppColors.textMuted,
                                    onPressed: () =>
                                        _confirmDelete(context, chat, s),
                                    icon: const Icon(Symbols.delete),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ChatService chat,
    ChatSession session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          '"${session.title}" and all of its messages will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await chat.deleteSession(session.id);
    }
  }

  String _sessionMeta(ChatSession s) {
    final name = s.modelId.isEmpty ? 'NO MODEL' : s.modelId.toUpperCase();
    final when = _formatWhen(s.updatedAt);
    return '$name · $when';
  }

  String _formatWhen(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'NOW';
    if (diff.inHours < 1) return '${diff.inMinutes}M AGO';
    if (diff.inDays < 1) return '${diff.inHours}H AGO';
    return '${diff.inDays}D AGO';
  }
}

// ─── Chat pane ───────────────────────────────────────────────────────────────

class _ChatPane extends StatelessWidget {
  const _ChatPane({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (wide) const _DesktopHeader() else const _MobileHeader(),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: AnimatedBuilder(
                animation: ChatService.instance,
                builder: (context, _) {
                  final messages = ChatService.instance.messagesFor(
                    ChatService.instance.activeSessionId,
                  );
                  if (messages.isEmpty) {
                    return _EmptyChatState(wide: wide);
                  }
                  return ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 28 : 16,
                      wide ? 22 : 18,
                      wide ? 28 : 16,
                      8,
                    ),
                    itemCount: messages.length,
                    separatorBuilder: (_, _) =>
                        SizedBox(height: wide ? 18 : 14),
                    itemBuilder: (context, i) =>
                        _MessageTile(message: messages[i], wide: wide),
                  );
                },
              ),
            ),
          ),
        ),
        _Composer(wide: wide),
      ],
    );
  }
}

class _DesktopHeader extends StatelessWidget {
  const _DesktopHeader();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.bgElevated.withA(0.72),
        border: const Border(bottom: BorderSide(color: AppColors.stroke)),
      ),
      child: Row(
        children: [
          Flexible(
            child: _HeaderChip(
              onTap: () => showModelPicker(context),
              children: [
                const Icon(Symbols.memory, size: 16, color: AppColors.accent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    app.selectedModel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.grotesk(13, weight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  app.selectedModelQuant,
                  style: AppText.mono(10, color: AppColors.textMuted),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Symbols.expand_more,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: _HeaderChip(
              onTap: () => showPersonaPicker(context),
              children: [
                const Icon(
                  Symbols.theater_comedy,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    app.selectedPersona,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.grotesk(13, weight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Symbols.expand_more,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
          const Spacer(),
          const SizedBox(width: 10),
          const _ModelStateControl(compact: false),
        ],
      ),
    );
  }
}

class _EmptyChatState extends StatelessWidget {
  const _EmptyChatState({required this.wide});

  final bool wide;

  static const _suggestions = [
    ('SUMMARIZE', 'Summarize the key ideas from this text: '),
    ('BRAINSTORM', 'Help me brainstorm practical approaches for '),
    ('EXPLAIN', 'Explain this clearly, with a concrete example: '),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoTile(size: 46, radius: 14, glow: true),
            const SizedBox(height: 20),
            Text(
              'Your private AI workspace',
              textAlign: TextAlign.center,
              style: AppText.grotesk(
                wide ? 24 : 20,
                weight: FontWeight.w600,
                lsEm: -0.02,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(
                'Ask, write, or reason with a model that stays on this device.',
                textAlign: TextAlign.center,
                style: AppText.grotesk(
                  13,
                  color: AppColors.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
            if (wide) ...[
              const SizedBox(height: 26),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final suggestion in _suggestions)
                    _SuggestionCard(
                      label: suggestion.$1,
                      prompt: suggestion.$2,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Symbols.lock, size: 13, color: AppColors.success),
                const SizedBox(width: 6),
                Text(
                  'LOCAL BY DEFAULT',
                  style: AppText.mono(
                    9.5,
                    weight: FontWeight.w600,
                    color: AppColors.textMuted,
                    lsEm: 0.1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.label, required this.prompt});

  final String label;
  final String prompt;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => ChatService.instance.prepareDraft(prompt),
      child: Container(
        width: 176,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.surface.withA(0.82),
          border: Border.all(color: AppColors.strokeHi),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: AppText.mono(
                9.5,
                weight: FontWeight.w600,
                color: AppColors.textSecondary,
                lsEm: 0.08,
              ),
            ),
            const Spacer(),
            const Icon(Symbols.north_east, size: 15, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.children, this.onTap});

  final List<Widget> children;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.stroke)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Scaffold.of(context).openDrawer(),
            child: const Icon(
              Symbols.menu,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => showModelPicker(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.stroke),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const GlowDot(size: 6, glow: false),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        app.selectedModel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.grotesk(13, weight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      ' · ${app.selectedPersona.split(' ').last.toUpperCase()}',
                      style: AppText.mono(10, color: AppColors.textMuted),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Symbols.expand_more,
                      size: 15,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const _ModelStateControl(compact: true),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => ChatService.instance.newSession(),
            child: const Icon(
              Symbols.add,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Messages ────────────────────────────────────────────────────────────────

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.wide});

  final ChatMessage message;
  final bool wide;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Response copied')));
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: message.text,
        subject: 'Erebrus AI response',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _regenerate(BuildContext context) async {
    final app = AppScope.of(context);
    await ChatService.instance.regenerate(
      message.id,
      persona: app.effectivePersonaConfig,
      webTools: app.webSearchActive,
    );
    if (!context.mounted) return;
  }

  Future<void> _speak(BuildContext context) async {
    try {
      await SpeechService.instance.toggle(
        messageId: message.id,
        text: message.text,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Speech unavailable: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: wide ? 0.78 : 0.82,
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              decoration: const BoxDecoration(
                color: AppColors.surface3,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Text(
                message.text,
                style: AppText.grotesk(14, height: 1.5),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.activity.isNotEmpty) ...[
          _ToolActivityList(activity: message.activity),
          const SizedBox(height: 10),
        ],
        if (message.text.isNotEmpty || message.activity.isEmpty)
          _AssistantBody(
            text: message.text,
            streaming: message.streaming,
            sources: message.sources,
          ),
        if (message.sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          _SourceList(sources: message.sources),
        ],
        const SizedBox(height: 8),
        if (message.streaming)
          Row(
            children: [
              Text(
                'STREAMING',
                style: AppText.mono(
                  10,
                  weight: FontWeight.w500,
                  color: AppColors.accent,
                  lsEm: 0.08,
                ),
              ),
              Text(
                message.tokensPerSecond == null
                    ? ' · CALCULATING TOK/S'
                    : ' · ${_formatTokenRate(message.tokensPerSecond!)} TOK/S',
                style: AppText.mono(10, color: AppColors.textFaint),
              ),
            ],
          )
        else
          AnimatedBuilder(
            animation: Listenable.merge([
              SpeechService.instance,
              VoicePreferences.instance,
            ]),
            builder: (context, _) => Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MessageAction(
                  icon: Symbols.content_copy,
                  label: 'Copy',
                  onTap: () => _copy(context),
                ),
                _MessageAction(
                  icon: Symbols.refresh,
                  label: 'Regenerate',
                  onTap: () => _regenerate(context),
                ),
                _MessageAction(
                  icon: Symbols.share,
                  label: 'Share',
                  onTap: () => _share(context),
                ),
                if (VoicePreferences.instance.readAloudEnabled)
                  _MessageAction(
                    icon: SpeechService.instance.isSpeakingMessage(message.id)
                        ? Symbols.stop_circle
                        : Symbols.volume_up,
                    label: SpeechService.instance.isSpeakingMessage(message.id)
                        ? 'Stop speaking'
                        : 'Speak',
                    active: SpeechService.instance.isSpeakingMessage(
                      message.id,
                    ),
                    onTap: () => _speak(context),
                  ),
                if (message.meta?.isNotEmpty == true ||
                    message.tokensPerSecond != null ||
                    message.truncated)
                  Text(
                    [
                      message.meta ?? '',
                      if (message.tokensPerSecond != null)
                        '${_formatTokenRate(message.tokensPerSecond!)} TOK/S',
                      if (message.truncated) 'MAX TOKENS REACHED',
                    ].where((part) => part.isNotEmpty).join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(10, color: AppColors.textFaint),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MessageAction extends StatelessWidget {
  const _MessageAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            size: 17,
            color: active ? AppColors.accent : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

String _formatTokenRate(double rate) {
  if (!rate.isFinite || rate < 0) return '0.0';
  return rate.toStringAsFixed(rate >= 10 ? 1 : 2);
}

/// Assistant prose rendered as Markdown, with the blinking block cursor
/// appended while streaming and `[n]` citations opening their source.
class _AssistantBody extends StatelessWidget {
  const _AssistantBody({
    required this.text,
    required this.streaming,
    this.sources = const [],
  });

  final String text;
  final bool streaming;
  final List<SourceRef> sources;

  void _openCitation(int number) {
    final source = sources.where((item) => item.index == number).firstOrNull;
    final uri = source == null ? null : Uri.tryParse(source.url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: MarkdownView(
        data: text,
        trailing: streaming ? const _BlinkCursor() : null,
        onCitationTap: sources.isEmpty ? null : _openCitation,
      ),
    );
  }
}

/// 8×15 accent block cursor blinking in 1s steps.
class _BlinkCursor extends StatefulWidget {
  const _BlinkCursor();

  @override
  State<_BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<_BlinkCursor> {
  Timer? _timer;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 550), (_) {
      if (mounted) setState(() => _on = !_on);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _on ? 1 : 0.15,
      child: Container(
        width: 8,
        height: 15,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

// ─── Composer ────────────────────────────────────────────────────────────────

class _Composer extends StatefulWidget {
  const _Composer({required this.wide});

  final bool wide;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ChatService.instance.addListener(_takeDraft);
  }

  void _takeDraft() {
    final draft = ChatService.instance.pendingDraft;
    if (draft.isEmpty || _controller.text.isNotEmpty) return;
    _controller.text = ChatService.instance.takePendingDraft();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    ChatService.instance.removeListener(_takeDraft);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final app = AppScope.of(context);
    if (app.selectedModelIsLocal && !app.selectedModelLoaded) {
      // Keep the draft; loading is the user's explicit choice.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Load ${app.selectedModel} to start chatting'),
          action: SnackBarAction(
            label: 'LOAD',
            onPressed: () => loadSelectedModelWithFeedback(context),
          ),
        ),
      );
      return;
    }
    _controller.clear();
    _focusNode.unfocus();
    setState(() => _busy = true);
    await ChatService.instance.send(
      text,
      modelId: app.selectedModelId,
      networkNodeId: app.selectedNetworkNodeId,
      persona: app.effectivePersonaConfig,
      webTools: app.webSearchActive,
    );
    if (mounted) setState(() => _busy = false);
  }

  void _toggleWebSearch(AppState app) {
    if (!WebTools.instance.isReady) {
      openSettingsSection(context, SettingsSection.tools);
      return;
    }
    if (!app.selectedModelSupportsTools && !app.webSearchInChat) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Web search works with Connection models for now (llama.cpp, '
            'Ollama, LM Studio, vLLM, OpenAI, Anthropic, OpenRouter). Pick one '
            'from the model menu.',
          ),
        ),
      );
      return;
    }
    app.setWebSearchInChat(!app.webSearchInChat);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.wide ? 28 : 16,
        widget.wide ? 14 : 12,
        widget.wide ? 28 : 16,
        widget.wide ? 16 : 8,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.strokeHi),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        enabled: !_busy,
                        style: AppText.grotesk(14),
                        cursorColor: AppColors.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: widget.wide
                              ? 'Message ${app.selectedModel.split(' ').take(2).join(' ')}…'
                              : 'Message…',
                          hintStyle: AppText.grotesk(
                            14,
                            color: AppColors.textMuted,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _WebSearchToggle(
                      active: app.webSearchActive,
                      armed: app.webSearchInChat,
                      onTap: () => _toggleWebSearch(app),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _busy ? null : _send,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _busy ? AppColors.textMuted : AppColors.accent,
                          borderRadius: BorderRadius.circular(11),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withA(0.6),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                              spreadRadius: -6,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Symbols.arrow_upward,
                          size: 19,
                          color: AppColors.onAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: widget.wide ? 9 : 7),
              if (widget.wide)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _ComposerPrivacyLine(app: app, centered: false),
                )
              else
                _ComposerPrivacyLine(app: app, centered: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the next message goes: this device, a LAN node, a model server, or
/// a cloud API — plus the search provider when web search is on.
class _ComposerPrivacyLine extends StatelessWidget {
  const _ComposerPrivacyLine({required this.app, required this.centered});

  final AppState app;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final target = app.selectedNetworkModelTarget;
    final connection = ConnectionService.instance.byNodeId(
      app.selectedNetworkNodeId,
    );
    final cloud = connection != null && !connection.provider.isLocal;
    final (icon, label) = !app.isNetworkModelSelected
        ? (
            Symbols.lock,
            centered
                ? 'ON-DEVICE · NOTHING LEAVES YOUR DEVICE'
                : 'LOCAL · NOTHING LEAVES THIS DEVICE',
          )
        : cloud
        ? (
            Symbols.cloud,
            'CLOUD · SENT TO ${connection.provider.label.toUpperCase()}',
          )
        : (
            Symbols.wifi,
            'NETWORK · SENT TO ${target?.nodeName.toUpperCase() ?? 'SELECTED NODE'}',
          );
    final web = app.webSearchActive;
    final color = cloud || web ? AppColors.warn : AppColors.success;
    final text = web
        ? '$label · WEB SEARCH VIA ${WebTools.instance.provider.label.toUpperCase()}'
        : label;
    return Row(
      mainAxisAlignment: centered
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Icon(icon, size: centered ? 12 : 13, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            style: AppText.mono(
              centered ? 9.5 : 10,
              color: centered ? AppColors.textFaint : AppColors.textMuted,
              lsEm: 0.08,
            ),
          ),
        ),
      ],
    );
  }
}

/// Globe button in the composer. [armed] is the user's switch; [active]
/// means web search will really run (configured + tool-capable model).
class _WebSearchToggle extends StatelessWidget {
  const _WebSearchToggle({
    required this.active,
    required this.armed,
    required this.onTap,
  });

  final bool active;
  final bool armed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tooltip = active
        ? 'Web search on for this chat'
        : armed
        ? 'Web search is on but unavailable for this model'
        : WebTools.instance.isReady
        ? 'Search the web'
        : 'Set up web search';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: armed,
        label: 'Web search',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: active ? AppColors.accent.withA(0.14) : null,
              border: Border.all(
                color: active
                    ? AppColors.accent.withA(0.45)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              Symbols.language,
              size: 19,
              color: active
                  ? AppColors.accentHi
                  : armed
                  ? AppColors.warn
                  : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The tool steps behind an answer: "Searched the web for …" etc.
class _ToolActivityList extends StatelessWidget {
  const _ToolActivityList({required this.activity});

  final List<ToolActivity> activity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final step in activity)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 16,
                  height: 18,
                  child: Center(
                    child: switch (step.status) {
                      ToolActivityStatus.running => const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppColors.accent,
                        ),
                      ),
                      ToolActivityStatus.done => Icon(
                        step.name == 'fetch_url'
                            ? Symbols.article
                            : Symbols.travel_explore,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                      ToolActivityStatus.failed => const Icon(
                        Symbols.error,
                        size: 14,
                        color: AppColors.danger,
                      ),
                    },
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: step.label,
                      children: [
                        if (step.summary.isNotEmpty)
                          TextSpan(
                            text: '  ·  ${step.summary}',
                            style: AppText.grotesk(
                              12,
                              color: step.status == ToolActivityStatus.failed
                                  ? AppColors.danger
                                  : AppColors.textFaint,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.grotesk(12.5, color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Numbered sources matching the answer's [n] citations; tap to open.
class _SourceList extends StatelessWidget {
  const _SourceList({required this.sources});

  final List<SourceRef> sources;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final source in sources) _SourceChip(source: source)],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final SourceRef source;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(source.url);
    final host = (uri?.host ?? source.url).replaceFirst(RegExp(r'^www\.'), '');
    return Tooltip(
      message: source.title.isEmpty
          ? source.url
          : '${source.title}\n${source.url}',
      child: InkWell(
        onTap: uri == null
            ? null
            : () => launchUrl(uri, mode: LaunchMode.externalApplication),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${source.index}',
                style: AppText.mono(
                  10.5,
                  weight: FontWeight.w600,
                  color: AppColors.accentHi,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.grotesk(12, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loads the selected on-device model, reporting failures in a snackbar.
Future<void> loadSelectedModelWithFeedback(BuildContext context) async {
  final app = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final error = await app.loadSelectedModel();
  if (error != null) {
    messenger.showSnackBar(SnackBar(content: Text('Could not load: $error')));
  }
}

/// Memory state of the selected model with Load / Eject for on-device
/// models. Network models are always ready, so they only show activity.
class _ModelStateControl extends StatelessWidget {
  const _ModelStateControl({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        InferenceService.instance,
        NetworkInferenceService.instance,
      ]),
      builder: (context, _) {
        final inference = InferenceService.instance;
        final network = NetworkInferenceService.instance;
        final local = app.selectedModelIsLocal;
        final loaded = app.selectedModelLoaded;
        final generating = inference.isGenerating || network.isGenerating;
        final loading =
            inference.isLoading &&
            inference.activeModelId == app.selectedModelId;

        if (!local) {
          if (compact) return const SizedBox.shrink();
          return _StateLabel(
            color: generating ? AppColors.accent : AppColors.success,
            label: generating ? 'GENERATING' : 'READY',
            glow: generating,
          );
        }

        final rate = inference.isGenerating
            ? inference.currentTokensPerSecond
            : inference.lastTokensPerSecond;
        final (Color color, String label) = loading
            ? (AppColors.warn, 'LOADING')
            : generating
            ? (AppColors.accent, 'GENERATING')
            : loaded
            ? (AppColors.success, 'LOADED')
            : (AppColors.textMuted, 'NOT LOADED');
        final otherLoaded =
            !loaded &&
            inference.hasLoadedModel &&
            inference.activeModelId != null;

        final Widget action;
        if (loading) {
          action = const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.warn,
            ),
          );
        } else if (loaded) {
          action = _HeaderAction(
            icon: Symbols.eject,
            label: compact ? null : 'Eject',
            tooltip: generating
                ? 'Wait for the response to finish to eject'
                : 'Eject ${app.selectedModel} and free its memory',
            onTap: generating ? null : app.ejectModel,
          );
        } else {
          action = _HeaderAction(
            icon: Symbols.memory,
            label: compact ? null : 'Load',
            primary: true,
            tooltip: otherLoaded
                ? 'Load ${app.selectedModel} (replaces the model in memory)'
                : 'Load ${app.selectedModel} into memory',
            onTap: () => loadSelectedModelWithFeedback(context),
          );
        }

        if (compact) return action;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StateLabel(color: color, label: label, glow: generating),
            if (loaded && rate != null)
              Text(
                ' · ${_formatTokenRate(rate)} TOK/S',
                style: AppText.mono(11, color: AppColors.textMuted),
              ),
            const SizedBox(width: 10),
            action,
          ],
        );
      },
    );
  }
}

class _StateLabel extends StatelessWidget {
  const _StateLabel({
    required this.color,
    required this.label,
    this.glow = false,
  });

  final Color color;
  final String label;
  final bool glow;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      GlowDot(color: color, glow: glow),
      const SizedBox(width: 7),
      Text(
        label,
        style: AppText.mono(
          11,
          weight: FontWeight.w500,
          color: color,
          lsEm: 0.06,
        ),
      ),
    ],
  );
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final String? label;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = primary ? AppColors.accentHi : AppColors.textPrimary;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label ?? tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              height: 32,
              padding: EdgeInsets.symmetric(horizontal: label == null ? 7 : 11),
              decoration: BoxDecoration(
                color: primary
                    ? AppColors.accent.withA(0.14)
                    : AppColors.surface2,
                border: Border.all(
                  color: primary
                      ? AppColors.accent.withA(0.4)
                      : AppColors.strokeHi,
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: fg),
                  if (label != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      label!,
                      maxLines: 1,
                      softWrap: false,
                      style: AppText.grotesk(
                        12.5,
                        weight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
