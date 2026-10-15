import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/mock_data.dart';
import '../../org/org_state.dart';
import '../../services/persona_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/ere_slider.dart';
import '../auth/sign_in.dart';

class PersonasScreen extends StatefulWidget {
  const PersonasScreen({super.key, required this.wide});

  final bool wide;

  @override
  State<PersonasScreen> createState() => _PersonasScreenState();
}

class _PersonasScreenState extends State<PersonasScreen> {
  late MockPersona _selected;

  @override
  void initState() {
    super.initState();
    _selected = _defaultSelected();
  }

  MockPersona _defaultSelected() {
    final all = PersonaService.instance.all;
    return all.firstWhere(
      (p) => p.name == 'Concise Analyst',
      orElse: () => all.isNotEmpty ? all.first : mockBuiltInPersonas[1],
    );
  }

  void _select(MockPersona p) {
    if (widget.wide) {
      setState(() => _selected = p);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: AppColors.bg,
            body: SafeArea(
              child: PersonaEditor(
                persona: p,
                wide: false,
                showBack: true,
                onSaved: (persona) => setState(() => _selected = persona),
                onDeleted: () => setState(() => _selected = _defaultSelected()),
              ),
            ),
          ),
        ),
      );
    }
  }

  void _onSaved(MockPersona p) => setState(() => _selected = p);
  void _onDeleted() => setState(() => _selected = _defaultSelected());

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PersonaService.instance,
      builder: (context, _) {
        final all = PersonaService.instance.all;
        final stillExists = all.any(
          (p) => p.effectiveId == _selected.effectiveId,
        );
        final selected = stillExists ? _selected : _defaultSelected();
        if (widget.wide) {
          return Row(
            children: [
              Container(
                width: 290,
                decoration: const BoxDecoration(
                  color: AppColors.bgElevated,
                  border: Border(right: BorderSide(color: AppColors.stroke)),
                ),
                child: _PersonaList(selected: selected, onSelect: _select),
              ),
              Expanded(
                child: PersonaEditor(
                  key: ValueKey(selected.effectiveId),
                  persona: selected,
                  wide: true,
                  onSaved: _onSaved,
                  onDeleted: _onDeleted,
                ),
              ),
            ],
          );
        }
        return SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Text('Personas', style: AppText.screenTitle()),
              ),
              const SizedBox(height: 6),
              Expanded(child: _PersonaList(selected: null, onSelect: _select)),
            ],
          ),
        );
      },
    );
  }
}

class _PersonaList extends StatelessWidget {
  const _PersonaList({required this.selected, required this.onSelect});

  final MockPersona? selected;
  final ValueChanged<MockPersona> onSelect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PersonaService.instance,
      builder: (context, _) {
        final service = PersonaService.instance;
        final builtIns = service.builtIns;
        final yours = service.userPersonas;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('PERSONAS', style: AppText.sectionHeader()),
                    AccentChip(
                      'NEW',
                      icon: Symbols.add,
                      iconSize: 14,
                      fontSize: 10,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      onTap: () async {
                        final blank = const MockPersona(
                          'New persona',
                          'NP',
                          'TEMP 0.7 · 768 MAX',
                          builtIn: false,
                          systemPrompt: '',
                          maxTokens: 768,
                        );
                        final saved = await PersonaService.instance.save(blank);
                        onSelect(saved);
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Text(
                        'BUILT-IN',
                        style: AppText.mono(
                          10,
                          weight: FontWeight.w500,
                          color: AppColors.textFaint,
                          lsEm: 0.12,
                        ),
                      ),
                    ),
                    for (final p in builtIns)
                      _PersonaRow(
                        persona: p,
                        active: p.effectiveId == selected?.effectiveId,
                        onTap: () => onSelect(p),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                      child: Text(
                        'YOURS',
                        style: AppText.mono(
                          10,
                          weight: FontWeight.w500,
                          color: AppColors.textFaint,
                          lsEm: 0.12,
                        ),
                      ),
                    ),
                    for (final p in yours)
                      _PersonaRow(
                        persona: p,
                        active: p.effectiveId == selected?.effectiveId,
                        onTap: () => onSelect(p),
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

class _PersonaRow extends StatelessWidget {
  const _PersonaRow({
    required this.persona,
    required this.active,
    required this.onTap,
  });

  final MockPersona persona;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: active ? AppColors.surface3 : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            LetterTile(
              persona.initials,
              size: 28,
              radius: 9,
              fontSize: 11,
              accent: active,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    persona.name,
                    style: AppText.grotesk(
                      13,
                      weight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    persona.meta,
                    style: AppText.mono(
                      9.5,
                      color: active
                          ? AppColors.textTertiary
                          : AppColors.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Editor ──────────────────────────────────────────────────────────────────

class PersonaEditor extends StatefulWidget {
  const PersonaEditor({
    super.key,
    required this.persona,
    required this.wide,
    this.showBack = false,
    this.onSaved,
    this.onDeleted,
  });

  final MockPersona persona;
  final bool wide;
  final bool showBack;
  final ValueChanged<MockPersona>? onSaved;
  final VoidCallback? onDeleted;

  @override
  State<PersonaEditor> createState() => _PersonaEditorState();
}

class _PersonaEditorState extends State<PersonaEditor> {
  late final TextEditingController _name;
  late final TextEditingController _system;
  late final TextEditingController _stop;
  late double _temperature;
  late double _topP;
  late int _maxTokens;
  late double _repeatPenalty;
  bool _shareToOrg = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.persona.name);
    _system = TextEditingController(text: widget.persona.systemPrompt);
    _stop = TextEditingController(text: widget.persona.stopSequences);
    _temperature = widget.persona.temperature;
    _topP = widget.persona.topP;
    _maxTokens = widget.persona.maxTokens;
    _repeatPenalty = widget.persona.repeatPenalty;
  }

  @override
  void dispose() {
    _name.dispose();
    _system.dispose();
    _stop.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PersonaEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.persona.effectiveId != widget.persona.effectiveId) {
      _name.text = widget.persona.name;
      _system.text = widget.persona.systemPrompt;
      _stop.text = widget.persona.stopSequences;
      _temperature = widget.persona.temperature;
      _topP = widget.persona.topP;
      _maxTokens = widget.persona.maxTokens;
      _repeatPenalty = widget.persona.repeatPenalty;
    }
  }

  MockPersona _buildPersona() {
    final name = _name.text.trim();
    final initials = name.length >= 2
        ? name.substring(0, 2).toUpperCase()
        : (name.isEmpty ? '??' : name.toUpperCase());
    final meta = 'TEMP ${_temperature.toStringAsFixed(1)} · $_maxTokens MAX';
    return widget.persona.copyWith(
      name: name.isEmpty ? widget.persona.name : name,
      initials: initials,
      meta: meta,
      builtIn: false,
      systemPrompt: _system.text,
      stopSequences: _stop.text,
      temperature: _temperature,
      topP: _topP,
      maxTokens: _maxTokens,
      repeatPenalty: _repeatPenalty,
    );
  }

  Future<void> _save() async {
    final p = _buildPersona();
    final saved = await PersonaService.instance.save(p);
    String message = 'Persona saved';
    if (_shareToOrg && mounted) {
      try {
        await AppScope.of(context).sharePersonaToOrg(saved.effectiveId);
        message = 'Persona saved and shared';
      } catch (error) {
        message = 'Persona saved locally. Sharing failed: $error';
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: Duration(seconds: 2)),
      );
    }
    widget.onSaved?.call(saved);
  }

  Future<void> _duplicate() async {
    final base = _buildPersona();
    final p = base.copyWith(
      id: null,
      name: '${base.name} copy',
      initials: base.initials,
      builtIn: false,
    );
    final saved = await PersonaService.instance.save(p);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Persona duplicated'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    widget.onSaved?.call(saved);
  }

  Future<void> _delete() async {
    if (widget.persona.builtIn) return;
    await PersonaService.instance.delete(widget.persona.effectiveId);
    if (mounted) {
      if (widget.showBack) Navigator.of(context).pop();
      widget.onDeleted?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Row(
      children: [
        if (widget.showBack) ...[
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: const Icon(
              Symbols.arrow_back,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.persona.name, style: AppText.screenTitle()),
              const SizedBox(height: 4),
              Text(
                widget.persona.builtIn
                    ? 'BUILT-IN PRESET · EDITS SAVE AS A COPY'
                    : 'YOUR PERSONA',
                style: AppText.mono(11, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        AccentChip(
          AppScope.of(context).selectedPersonaId == widget.persona.effectiveId
              ? 'IN USE'
              : 'USE IN CHAT',
          icon: Symbols.chat,
          onTap: () => AppScope.of(
            context,
          ).selectPersona(widget.persona.name, id: widget.persona.effectiveId),
        ),
        GhostButton('DUPLICATE', icon: Symbols.content_copy, onTap: _duplicate),
        if (!widget.persona.builtIn)
          DangerGhostButton('DELETE', icon: Symbols.delete, onTap: _delete)
        else
          const SizedBox.shrink(),
      ],
    );
    final header = widget.wide
        ? Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 12),
              actions,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );

    final fields = <Widget>[
      const _FieldLabel('NAME'),
      const SizedBox(height: 7),
      _TextFieldBox(controller: _name, bold: true),
      const SizedBox(height: 14),
      const _FieldLabel('SYSTEM PROMPT'),
      const SizedBox(height: 7),
    ];

    final tail = <Widget>[
      const SizedBox(height: 14),
      const _FieldLabel('STOP SEQUENCES'),
      const SizedBox(height: 7),
      _TextFieldBox(controller: _stop, mono: true),
    ];

    final samplingColumn = <Widget>[
      const _FieldLabel('SAMPLING'),
      const SizedBox(height: 7),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Column(
          children: [
            SamplerSlider(
              label: 'Temperature',
              min: 0,
              max: 2,
              value: _temperature,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => setState(() => _temperature = v),
            ),
            const SizedBox(height: 18),
            SamplerSlider(
              label: 'Top P',
              min: 0,
              max: 1,
              value: _topP,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => setState(() => _topP = v),
            ),
            const SizedBox(height: 18),
            SamplerSlider(
              label: 'Max tokens',
              min: 64,
              max: 4096,
              value: _maxTokens.toDouble(),
              format: (v) => v.round().toString(),
              onChanged: (v) => setState(() => _maxTokens = v.round()),
            ),
            const SizedBox(height: 18),
            SamplerSlider(
              label: 'Repeat penalty',
              min: 1,
              max: 1.3,
              value: _repeatPenalty,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => setState(() => _repeatPenalty = v),
            ),
          ],
        ),
      ),
      if (OrgState.sharedFeaturesAvailable) ...[
        const SizedBox(height: 14),
        _ShareCard(
          value: _shareToOrg,
          onChanged: (value) => setState(() => _shareToOrg = value),
        ),
      ],
      const SizedBox(height: 14),
      PrimaryCta('SAVE PERSONA', onTap: _save),
    ];

    if (widget.wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 20),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...fields,
                        Expanded(
                          child: _TextFieldBox(
                            controller: _system,
                            mono: true,
                            expand: true,
                            hint:
                                'No system prompt — the model answers as itself.',
                          ),
                        ),
                        ...tail,
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 320,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: samplingColumn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      children: [
        header,
        const SizedBox(height: 20),
        ...fields,
        _TextFieldBox(
          controller: _system,
          mono: true,
          minHeight: 150,
          hint: 'No system prompt — the model answers as itself.',
        ),
        ...tail,
        const SizedBox(height: 20),
        ...samplingColumn,
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: AppText.mono(
        10.5,
        weight: FontWeight.w600,
        color: AppColors.textMuted,
        lsEm: 0.12,
      ),
    );
  }
}

class _TextFieldBox extends StatelessWidget {
  const _TextFieldBox({
    required this.controller,
    this.mono = false,
    this.bold = false,
    this.expand = false,
    this.minHeight,
    this.hint,
  });

  final TextEditingController controller;
  final bool mono;
  final bool bold;
  final bool expand;
  final double? minHeight;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: minHeight != null
          ? BoxConstraints(minHeight: minHeight!)
          : null,
      padding: mono && (expand || minHeight != null)
          ? const EdgeInsets.all(14)
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(11),
      ),
      child: TextField(
        controller: controller,
        expands: expand,
        maxLines: expand ? null : (minHeight != null ? null : 1),
        style: mono
            ? AppText.mono(12.5, color: AppColors.textTertiary, height: 1.65)
            : AppText.grotesk(
                14,
                weight: bold ? FontWeight.w500 : FontWeight.w400,
                color: AppColors.textPrimary,
              ),
        cursorColor: AppColors.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: mono
              ? AppText.mono(12.5, color: AppColors.textMuted)
              : AppText.grotesk(14, color: AppColors.textMuted),
        ),
      ),
    );
  }
}

class _ShareCard extends StatelessWidget {
  const _ShareCard({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(13),
      ),
      child: app.signedIn
          ? Row(
              children: [
                const Icon(
                  Symbols.apartment,
                  size: 18,
                  color: AppColors.orgPurple,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.selectedOrg == null
                            ? 'Choose an organization to share'
                            : 'Share to ${app.selectedOrg!.name}',
                        style: AppText.grotesk(13, weight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Members can use this persona on org nodes.',
                        style: AppText.grotesk(11, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                EreToggle(
                  value: value,
                  disabled: app.selectedOrg == null,
                  onChanged: app.selectedOrg == null ? null : onChanged,
                ),
              ],
            )
          : Row(
              children: [
                const Icon(Symbols.lock, size: 18, color: AppColors.textMuted),
                const SizedBox(width: 11),
                Expanded(
                  child: GestureDetector(
                    onTap: () => openSignIn(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Share to workspace',
                          style: AppText.grotesk(
                            13,
                            weight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Sign in to share personas with your org.',
                          style: AppText.grotesk(
                            11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const EreToggle(value: false, disabled: true),
              ],
            ),
    );
  }
}
