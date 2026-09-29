import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'adaptive_row.dart';

/// Building blocks for the sectioned Settings surface: a page header, titled
/// groups, and label/description rows with a right-aligned control that
/// stacks under the text on narrow widths.

const _kStackBreakpoint = 560.0;

/// Width [text] needs on one line in [style], honoring the user's text scale.
/// Rows use it so a control only sits inline when the label fits unwrapped.
double singleLineTextWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width.ceilToDouble() + 1;
}

const _kControlWidth = 264.0;

class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onBack,
    this.breadcrumb,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onBack;

  /// Shown instead of the title row, e.g. `Connections • New`.
  final List<String>? breadcrumb;

  @override
  Widget build(BuildContext context) {
    final crumbs = breadcrumb;
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (onBack != null) ...[
          SettingsIconButton(
            icon: Symbols.arrow_back,
            tooltip: 'Back',
            onTap: onBack!,
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: crumbs != null
              ? Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < crumbs.length; i++) ...[
                      if (i > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Container(
                            width: 3,
                            height: 3,
                            decoration: const BoxDecoration(
                              color: AppColors.textMuted,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      Text(
                        crumbs[i],
                        style: AppText.grotesk(
                          13.5,
                          weight: FontWeight.w500,
                          color: i == crumbs.length - 1
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                )
              : Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.screenTitle(size: 21),
                ),
        ),
      ],
    );
    final titleStyle = AppText.screenTitle(size: 21);
    // Actions stay beside the title when it fits unclipped; otherwise they
    // move under it so the title is never cut to "Connectio…".
    final Widget titleRow = trailing == null
        ? header
        : AdaptiveRow(
            leading: header,
            trailing: trailing!,
            gap: 12,
            minLeadingWidth:
                (crumbs == null
                    ? singleLineTextWidth(context, title, titleStyle)
                    : 0) +
                (onBack == null ? 0 : 44),
            stackedAlignment: AlignmentDirectional.centerEnd,
          );
    // The subtitle spans the full width under the title row so trailing
    // actions never squeeze it into a narrow column.
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          titleRow,
          if (crumbs == null && subtitle != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.only(left: onBack == null ? 0 : 44),
              child: Text(
                subtitle!,
                style: AppText.grotesk(
                  13,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A titled cluster of [SettingItem]s ("Dictation", "Read aloud", …).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.description,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title!,
                          style: AppText.grotesk(16, weight: FontWeight.w600),
                        ),
                        if (description != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            description!,
                            style: AppText.grotesk(
                              12.5,
                              color: AppColors.textMuted,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// One setting: title + description on the left, control on the right.
class SettingItem extends StatelessWidget {
  const SettingItem({
    super.key,
    required this.title,
    this.description,
    this.control,
    this.below,
    this.titleColor = AppColors.textPrimary,
    this.controlWidth,
    this.onTap,
  });

  final String title;
  final String? description;
  final Widget? control;

  /// Extra content under the control column (e.g. download status row).
  final Widget? below;
  final Color titleColor;

  /// Fixed control column width; null sizes the control to its content.
  final double? controlWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final titleStyle = AppText.grotesk(
      14.5,
      weight: FontWeight.w500,
      color: titleColor,
    );
    final descriptionStyle = AppText.grotesk(
      12.5,
      color: AppColors.textMuted,
      height: 1.4,
    );
    // The control stays inline only if the title — and a short, label-like
    // description such as a path or status — still fit on one line.
    final description = this.description;
    final minTextWidth = [
      140.0,
      singleLineTextWidth(context, title, titleStyle),
      if (description != null && description.length <= 40)
        singleLineTextWidth(context, description, descriptionStyle),
    ].reduce((a, b) => a > b ? a : b);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: titleStyle),
        if (description != null) ...[
          const SizedBox(height: 3),
          Text(description, style: descriptionStyle),
        ],
      ],
    );
    final controlColumn = control == null && below == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              ?control,
              if (below != null) ...[const SizedBox(height: 8), below!],
            ],
          );
    // The control sits right-aligned beside the text when it fits, and moves
    // under the text (still right-aligned) only when it would squeeze it.
    final Widget content = controlColumn == null
        ? text
        : AdaptiveRow(
            leading: text,
            trailing: controlWidth == null
                ? ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _kControlWidth + 40,
                    ),
                    child: controlColumn,
                  )
                : SizedBox(width: controlWidth, child: controlColumn),
            gap: 20,
            minLeadingWidth: minTextWidth,
            minLeadingFraction: 0.55,
            stackedAlignment: AlignmentDirectional.centerEnd,
          );
    final padded = Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: content,
    );
    if (onTap == null) return padded;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: padded,
      ),
    );
  }
}

/// A dropdown option for [EreSelect].
class SelectOption<T> {
  const SelectOption(
    this.value,
    this.label, {
    this.description,
    this.icon,
    this.trailing,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? description;
  final IconData? icon;
  final String? trailing;
  final bool enabled;
}

/// Pill-shaped dropdown: current label + chevron, opens an anchored menu.
class EreSelect<T> extends StatelessWidget {
  const EreSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = _kControlWidth,
    this.leading,
    this.placeholder = 'Select…',
  });

  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T>? onChanged;
  final double? width;
  final Widget? leading;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final selected = options
        .where((option) => option.value == value)
        .firstOrNull;
    final enabled = onChanged != null;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppColors.surface2),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(
          BorderSide(color: AppColors.strokeHi),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        maximumSize: const WidgetStatePropertyAll(Size(420, 420)),
      ),
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            onPressed: option.enabled && enabled
                ? () => onChanged!(option.value)
                : null,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              backgroundColor: WidgetStatePropertyAll(
                option.value == value ? AppColors.surface3 : null,
              ),
              overlayColor: const WidgetStatePropertyAll(AppColors.surface3),
            ),
            leadingIcon: option.icon == null
                ? null
                : Icon(option.icon, size: 17, color: AppColors.textSecondary),
            trailingIcon: option.value == value
                ? const Icon(Symbols.check, size: 16, color: AppColors.accent)
                : option.trailing == null
                ? null
                : Text(
                    option.trailing!,
                    style: AppText.mono(10.5, color: AppColors.textMuted),
                  ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // Menu rows match the field, within readable bounds.
                minWidth: ((width ?? _kControlWidth) - 60).clamp(160, 320),
                maxWidth: 320,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: AppText.grotesk(
                      13.5,
                      weight: FontWeight.w500,
                      color: option.enabled
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  if (option.description != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        option.description!,
                        style: AppText.grotesk(
                          11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, controller, _) {
        final field = Container(
          height: 40,
          padding: const EdgeInsets.only(left: 14, right: 10),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(
              color: controller.isOpen ? AppColors.accent : AppColors.strokeHi,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 8)],
              Flexible(
                fit: width == null ? FlexFit.loose : FlexFit.tight,
                child: Text(
                  selected?.label ?? placeholder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.grotesk(
                    13.5,
                    weight: FontWeight.w500,
                    color: selected == null
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                controller.isOpen ? Symbols.expand_less : Symbols.expand_more,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        );
        return Semantics(
          button: true,
          enabled: enabled,
          label: selected?.label ?? placeholder,
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: enabled
                  ? () => controller.isOpen
                        ? controller.close()
                        : controller.open()
                  : null,
              child: Opacity(
                opacity: enabled ? 1 : 0.55,
                child: width == null
                    ? field
                    : SizedBox(width: width, child: field),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum PillTone { neutral, primary, danger, subtle }

/// Rounded button used across settings ("Download", "Manage", "Add
/// connection"). Shows a spinner in place of the icon while [busy].
class PillButton extends StatelessWidget {
  const PillButton(
    this.label, {
    super.key,
    this.icon,
    this.onTap,
    this.tone = PillTone.neutral,
    this.busy = false,
    this.compact = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final PillTone tone;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final (bg, border, fg) = switch (tone) {
      PillTone.primary => (
        AppColors.accent,
        AppColors.accent,
        AppColors.onAccent,
      ),
      PillTone.danger => (
        AppColors.danger.withA(0.08),
        AppColors.danger.withA(0.35),
        AppColors.danger,
      ),
      PillTone.subtle => (
        Colors.transparent,
        Colors.transparent,
        AppColors.textSecondary,
      ),
      PillTone.neutral => (
        AppColors.surface2,
        AppColors.strokeHi,
        AppColors.textPrimary,
      ),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: ExcludeSemantics(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: onTap == null ? 0.5 : 1,
              child: Container(
                height: compact ? 32 : 38,
                padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
                decoration: BoxDecoration(
                  color: bg,
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: fg,
                        ),
                      )
                    else if (icon != null)
                      Icon(icon, size: compact ? 15 : 17, color: fg),
                    if (busy || icon != null) const SizedBox(width: 7),
                    Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: AppText.grotesk(
                        compact ? 12.5 : 13.5,
                        weight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsIconButton extends StatelessWidget {
  const SettingsIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = AppColors.textSecondary,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, size: 19, color: color),
        ),
      ),
    );
  }
}

/// Rounded single- or multi-line input matching [EreSelect].
class EreTextField extends StatelessWidget {
  const EreTextField({
    super.key,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.mono = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.onChanged,
    this.suffix,
    this.enabled = true,
    this.errorText,
  });

  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final bool mono;
  final int maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final multiline = maxLines > 1;
    final style = mono
        ? AppText.mono(13, color: AppColors.textPrimary)
        : AppText.grotesk(14, color: AppColors.textPrimary);
    final radius = BorderRadius.circular(multiline ? 14 : 22);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      minLines: minLines,
      enabled: enabled,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: style,
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: style.copyWith(color: AppColors.textFaint),
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: multiline ? 14 : 12,
        ),
        suffixIcon: suffix,
        errorText: errorText,
        border: border(AppColors.strokeHi),
        enabledBorder: border(AppColors.strokeHi),
        focusedBorder: border(AppColors.accent),
        disabledBorder: border(AppColors.stroke),
        errorBorder: border(AppColors.danger),
        focusedErrorBorder: border(AppColors.danger),
      ),
    );
  }
}

/// Bordered card of form rows separated by hairlines (connection editor).
class SettingsFormCard extends StatelessWidget {
  const SettingsFormCard({super.key, required this.children, this.header});

  final List<Widget> children;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 || header != null)
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.strokeSoft,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A label/description + field row inside a [SettingsFormCard].
class SettingsFormRow extends StatelessWidget {
  const SettingsFormRow({
    super.key,
    required this.title,
    this.description,
    required this.field,
    this.fieldNote,
  });

  final String title;
  final String? description;
  final Widget field;
  final Widget? fieldNote;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < _kStackBreakpoint;
          final label = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.grotesk(14.5, weight: FontWeight.w500),
              ),
              if (description != null) ...[
                const SizedBox(height: 3),
                Text(
                  description!,
                  style: AppText.grotesk(
                    12,
                    color: AppColors.textMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          );
          final right = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              field,
              if (fieldNote != null) ...[const SizedBox(height: 6), fieldNote!],
            ],
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [label, const SizedBox(height: 10), right],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 4, child: label),
              const SizedBox(width: 20),
              Expanded(flex: 5, child: right),
            ],
          );
        },
      ),
    );
  }
}

enum NoteTone { info, warn, danger, success }

/// Short inline notice text under a field or group.
class SettingsNote extends StatelessWidget {
  const SettingsNote(
    this.text, {
    super.key,
    this.tone = NoteTone.info,
    this.icon,
  });

  final String text;
  final NoteTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      NoteTone.info => AppColors.textMuted,
      NoteTone.warn => AppColors.warn,
      NoteTone.danger => AppColors.danger,
      NoteTone.success => AppColors.success,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            text,
            style: AppText.grotesk(12, color: color, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// Coloured pill for model memory state (LOADED / NOT LOADED / …).
class StatePill extends StatelessWidget {
  const StatePill(
    this.label, {
    super.key,
    required this.color,
    this.pulse = false,
  });

  final String label;
  final Color color;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withA(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulse)
            SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppText.mono(
              9.5,
              weight: FontWeight.w600,
              color: color,
              lsEm: 0.06,
            ),
          ),
        ],
      ),
    );
  }
}
