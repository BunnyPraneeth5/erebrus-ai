import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Pill toggle — 46×27 track, 21px knob, on = accent, off = surface3.
class EreToggle extends StatelessWidget {
  const EreToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.disabled = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final toggle = GestureDetector(
      onTap: disabled || onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 46,
        height: 27,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? AppColors.accent : AppColors.surface3,
          borderRadius: BorderRadius.circular(14),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: value ? Colors.white : AppColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
    return disabled ? Opacity(opacity: 0.5, child: toggle) : toggle;
  }
}

/// Segmented control — surface bg, 4px padding r13; active segment accent r10.
class EreSegmented extends StatelessWidget {
  const EreSegmented({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.accent : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    items[i],
                    style: AppText.mono(
                      12,
                      weight: FontWeight.w600,
                      color: i == index
                          ? AppColors.onAccent
                          : AppColors.textSecondary,
                      lsEm: 0.05,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Primary CTA — accent bg, onAccent mono 600 uppercase, optional glow.
class PrimaryCta extends StatelessWidget {
  const PrimaryCta(
    this.label, {
    super.key,
    this.onTap,
    this.fontSize = 13,
    this.radius = 12,
    this.padding = const EdgeInsets.all(13),
    this.glow = true,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final double fontSize;
  final double radius;
  final EdgeInsets padding;
  final bool glow;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cta = Semantics(
      button: true,
      enabled: enabled && onTap != null,
      label: label,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: ExcludeSemantics(
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: glow && enabled
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withA(0.55),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                        spreadRadius: -10,
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: AppText.mono(
                fontSize,
                weight: FontWeight.w600,
                color: AppColors.onAccent,
                lsEm: 0.05,
              ),
            ),
          ),
        ),
      ),
    );
    return enabled ? cta : Opacity(opacity: 0.5, child: cta);
  }
}

/// Ghost button — surface2 bg, strokeHi border, mono textSecondary.
class GhostButton extends StatelessWidget {
  const GhostButton(
    this.label, {
    super.key,
    this.icon,
    this.onTap,
    this.color = AppColors.textSecondary,
    this.background = AppColors.surface2,
    this.borderColor = AppColors.strokeHi,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color color;
  final Color background;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: background,
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: AppText.mono(
                    11,
                    weight: FontWeight.w500,
                    color: color,
                    lsEm: 0.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Danger-tinted ghost button (DELETE).
class DangerGhostButton extends StatelessWidget {
  const DangerGhostButton(this.label, {super.key, this.icon, this.onTap});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GhostButton(
      label,
      icon: icon,
      onTap: onTap,
      color: AppColors.danger,
      background: AppColors.danger.withA(0.08),
      borderColor: AppColors.danger.withA(0.3),
    );
  }
}

/// Accent-tinted chip/button — accent 14% bg, accent 30% border, accent text.
class AccentChip extends StatelessWidget {
  const AccentChip(
    this.label, {
    super.key,
    this.icon,
    this.onTap,
    this.fontSize = 11,
    this.iconSize = 15,
    this.radius = 8,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double fontSize;
  final double iconSize;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: AppColors.accent.withA(0.14),
              border: Border.all(color: AppColors.accent.withA(0.3)),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: iconSize, color: AppColors.accent),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: AppText.mono(
                    fontSize,
                    weight: FontWeight.w600,
                    color: AppColors.accent,
                    lsEm: 0.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Status badge with dot — e.g. ONLINE / LOADED (success 12% bg).
class StatusBadge extends StatelessWidget {
  const StatusBadge(
    this.label, {
    super.key,
    this.color = AppColors.success,
    this.dot = true,
  });

  final String label;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withA(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: AppText.mono(
              10,
              weight: FontWeight.w600,
              color: color,
              lsEm: 0.08,
            ),
          ),
        ],
      ),
    );
  }
}

/// Glowing status dot (e.g. next to "Serving on LAN").
class GlowDot extends StatelessWidget {
  const GlowDot({
    super.key,
    this.size = 7,
    this.color = AppColors.success,
    this.glow = true,
  });

  final double size;
  final Color color;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? [BoxShadow(color: color.withA(0.8), blurRadius: 8)]
            : null,
      ),
    );
  }
}

/// Letter avatar tile used for models/personas.
class LetterTile extends StatelessWidget {
  const LetterTile(
    this.letter, {
    super.key,
    this.size = 30,
    this.radius = 8,
    this.fontSize = 12,
    this.accent = false,
  });

  final String letter;
  final double size;
  final double radius;
  final double fontSize;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent ? AppColors.accent.withA(0.16) : AppColors.surface3,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: AppText.mono(
          fontSize,
          weight: FontWeight.w600,
          color: accent ? AppColors.accent : AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// Thin progress bar (downloads, storage meter).
class EreProgressBar extends StatelessWidget {
  const EreProgressBar({super.key, required this.value, this.height = 5});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2 + 0.5),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Colors.white.withA(0.1))),
            FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: const ColoredBox(color: AppColors.accent),
            ),
          ],
        ),
      ),
    );
  }
}
