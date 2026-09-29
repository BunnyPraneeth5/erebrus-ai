import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Renders assistant Markdown (GitHub-flavored) with the app's typography:
/// headings, emphasis, lists (incl. tasks), quotes, rules, tables, inline and
/// fenced code (with copy), links, and `[n]` citation chips.
///
/// Parsing is tolerant, so partially streamed text renders sensibly: an
/// unclosed code fence shows as a code block, and unmatched `**` stays
/// literal until its closing pair arrives.
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.data,
    this.trailing,
    this.onCitationTap,
    this.baseStyle,
  });

  final String data;

  /// Inline widget appended after the last text (e.g. a streaming cursor).
  final Widget? trailing;

  /// Called with n for a `[n]` citation; null renders citations as plain.
  final ValueChanged<int>? onCitationTap;
  final TextStyle? baseStyle;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final List<TapGestureRecognizer> _recognizers = [];

  // Parsing is cheap for chat-sized text; cache by input to skip rebuilds
  // triggered by unrelated state.
  String? _parsedFor;
  List<md.Node> _nodes = const [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  List<md.Node> _parse(String data) {
    if (_parsedFor == data) return _nodes;
    _parsedFor = data;
    _nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parse(data);
    return _nodes;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final base =
        widget.baseStyle ??
        AppText.grotesk(14, color: AppColors.textBody, height: 1.6);
    final nodes = _parse(widget.data);
    final blocks = <Widget>[];
    // Code blocks, tables, quotes and rules can't host an inline trailing
    // widget; it then goes on its own line after them.
    final lastNode = nodes.lastOrNull;
    final trailingInline =
        lastNode is md.Text ||
        (lastNode is md.Element && !_standaloneTags.contains(lastNode.tag));
    for (var i = 0; i < nodes.length; i++) {
      final last = i == nodes.length - 1;
      blocks.add(
        _block(
          nodes[i],
          base,
          trailing: last && trailingInline ? widget.trailing : null,
        ),
      );
    }
    if (widget.trailing != null && (blocks.isEmpty || !trailingInline)) {
      blocks.add(
        Text.rich(
          TextSpan(children: [_trailingSpan(widget.trailing!)]),
          style: base,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _spaced(blocks, 10),
    );
  }

  static List<Widget> _spaced(List<Widget> children, double gap) => [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) SizedBox(height: gap),
      children[i],
    ],
  ];

  InlineSpan _trailingSpan(Widget trailing) => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(padding: const EdgeInsets.only(left: 3), child: trailing),
  );

  // ─── Blocks ──────────────────────────────────────────────────────────────

  Widget _block(md.Node node, TextStyle base, {Widget? trailing}) {
    if (node is md.Text) {
      return _paragraph([node], base, trailing: trailing);
    }
    if (node is! md.Element) return const SizedBox.shrink();
    switch (node.tag) {
      case 'p':
        return _paragraph(node.children ?? const [], base, trailing: trailing);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final size = switch (node.tag) {
          'h1' => 20.0,
          'h2' => 18.0,
          'h3' => 16.0,
          _ => 14.5,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _paragraph(
            node.children ?? const [],
            base.merge(
              AppText.grotesk(
                size,
                weight: FontWeight.w600,
                color: AppColors.textPrimary,
                height: 1.35,
              ),
            ),
            trailing: trailing,
          ),
        );
      case 'ul' || 'ol':
        return _list(node, base, trailing: trailing);
      case 'pre':
        return _codeBlock(node);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.strokeHi, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _spaced([
              for (final child in node.children ?? const <md.Node>[])
                _block(child, base.copyWith(color: AppColors.textSecondary)),
            ], 8),
          ),
        );
      case 'hr':
        return const Divider(height: 12, thickness: 1, color: AppColors.stroke);
      case 'table':
        return _table(node, base);
      default:
        final children = node.children ?? const <md.Node>[];
        if (children.every(_isInline)) {
          return _paragraph(children, base, trailing: trailing);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _spaced([
            for (final child in children) _block(child, base),
          ], 8),
        );
    }
  }

  static const _standaloneTags = {'pre', 'table', 'hr', 'blockquote'};

  static const _blockTags = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'pre', //
    'blockquote', 'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
  };

  static bool _isInline(md.Node node) =>
      node is md.Text || (node is md.Element && !_blockTags.contains(node.tag));

  Widget _paragraph(
    List<md.Node> inlines,
    TextStyle style, {
    Widget? trailing,
  }) {
    return Text.rich(
      TextSpan(
        children: [
          ..._inlines(inlines, style),
          if (trailing != null) _trailingSpan(trailing),
        ],
      ),
      style: style,
    );
  }

  Widget _list(md.Element list, TextStyle base, {Widget? trailing}) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = (list.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((item) => item.tag == 'li')
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _spaced([
        for (var i = 0; i < items.length; i++)
          _listItem(
            items[i],
            base,
            marker: ordered ? '${start + i}.' : '•',
            ordered: ordered,
            trailing: i == items.length - 1 ? trailing : null,
          ),
      ], 4),
    );
  }

  Widget _listItem(
    md.Element item,
    TextStyle base, {
    required String marker,
    required bool ordered,
    Widget? trailing,
  }) {
    var children = item.children ?? const <md.Node>[];
    // GFM task list: a leading checkbox input.
    bool? checked;
    final first = children.firstOrNull;
    if (first is md.Element && first.tag == 'input') {
      checked = first.attributes.containsKey('checked');
      children = children.skip(1).toList();
    }
    final Widget body;
    if (children.every(_isInline)) {
      body = _paragraph(children, base, trailing: trailing);
    } else {
      final groups = <Widget>[];
      final pending = <md.Node>[];
      void flush() {
        if (pending.isEmpty) return;
        groups.add(_paragraph(List.of(pending), base));
        pending.clear();
      }

      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        if (_isInline(child)) {
          pending.add(child);
        } else {
          flush();
          groups.add(
            _block(
              child,
              base,
              trailing: i == children.length - 1 ? trailing : null,
            ),
          );
        }
      }
      flush();
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _spaced(groups, 6),
      );
    }
    final lineHeight = (base.fontSize ?? 14) * (base.height ?? 1.4);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: ordered ? 24 : 16,
          height: lineHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: checked != null
                ? Icon(
                    checked
                        ? Symbols.check_box
                        : Symbols.check_box_outline_blank,
                    fill: checked ? 1 : 0,
                    size: 16,
                    color: checked ? AppColors.accent : AppColors.textMuted,
                  )
                : Text(
                    marker,
                    style: base.copyWith(
                      color: ordered
                          ? AppColors.textSecondary
                          : AppColors.accent,
                      fontWeight: ordered ? FontWeight.w500 : FontWeight.w700,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: body),
      ],
    );
  }

  Widget _codeBlock(md.Element pre) {
    final code = pre.children?.whereType<md.Element>().firstOrNull;
    final language = (code?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    final text = (code?.textContent ?? pre.textContent).replaceFirst(
      RegExp(r'\n$'),
      '',
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.strokeSoft)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: AppText.mono(10.5, color: AppColors.textMuted),
                  ),
                ),
                _CopyCodeButton(text: text),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Text(
              text,
              softWrap: false,
              style: AppText.mono(
                12.5,
                color: AppColors.textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(md.Element table, TextStyle base) {
    final rows = <(bool, List<md.Element>)>[];
    for (final section
        in (table.children ?? const []).whereType<md.Element>()) {
      final header = section.tag == 'thead';
      for (final row
          in (section.children ?? const []).whereType<md.Element>()) {
        rows.add((
          header,
          (row.children ?? const []).whereType<md.Element>().toList(),
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows
        .map((row) => row.$2.length)
        .reduce((a, b) => a > b ? a : b);
    final cellStyle = base.copyWith(fontSize: 13, height: 1.45);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.stroke),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: const TableBorder(
            horizontalInside: BorderSide(color: AppColors.strokeSoft),
            verticalInside: BorderSide(color: AppColors.strokeSoft),
          ),
          children: [
            for (final (header, cells) in rows)
              TableRow(
                decoration: header
                    ? const BoxDecoration(color: AppColors.surface2)
                    : null,
                children: [
                  for (var c = 0; c < columns; c++)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: c < cells.length
                            ? _paragraph(
                                cells[c].children ?? const [],
                                header
                                    ? cellStyle.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                      )
                                    : cellStyle,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ─── Inlines ─────────────────────────────────────────────────────────────

  static final _citation = RegExp(r'\[(\d{1,3})\]');

  List<InlineSpan> _inlines(List<md.Node> nodes, TextStyle style) => [
    for (final node in nodes) ..._inline(node, style),
  ];

  List<InlineSpan> _inline(md.Node node, TextStyle style) {
    if (node is md.Text) return _text(node.text, style);
    if (node is! md.Element) return const [];
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'strong' || 'b':
        return _inlines(
          children,
          style.copyWith(
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            color: AppColors.textPrimary,
          ),
        );
      case 'em' || 'i':
        return _inlines(children, style.copyWith(fontStyle: FontStyle.italic));
      case 'del' || 's':
        return _inlines(
          children,
          style.copyWith(decoration: TextDecoration.lineThrough),
        );
      case 'code':
        return [
          TextSpan(
            text: ' ${node.textContent} ',
            style: AppText.mono(
              (style.fontSize ?? 14) - 1.5,
              color: AppColors.accentHi,
            ).copyWith(backgroundColor: AppColors.accent.withA(0.1)),
          ),
        ];
      case 'br':
        return const [TextSpan(text: '\n')];
      case 'a':
        final href = node.attributes['href'] ?? '';
        final uri = Uri.tryParse(href);
        final recognizer = uri == null || !uri.hasScheme
            ? null
            : (TapGestureRecognizer()
                ..onTap = () =>
                    launchUrl(uri, mode: LaunchMode.externalApplication));
        if (recognizer != null) _recognizers.add(recognizer);
        return [
          TextSpan(
            children: _inlines(children, style),
            style: style.copyWith(
              color: AppColors.accentHi,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.accentHi.withA(0.5),
            ),
            recognizer: recognizer,
            mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
          ),
        ];
      case 'img':
        final alt = node.attributes['alt'] ?? '';
        return [
          TextSpan(
            text: alt.isEmpty ? '[image]' : '[$alt]',
            style: style.copyWith(color: AppColors.textMuted),
          ),
        ];
      default:
        return _inlines(children, style);
    }
  }

  /// Plain text, with `[n]` citations turned into small accent references.
  List<InlineSpan> _text(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _citation.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: style),
        );
      }
      final number = int.parse(match.group(1)!);
      final onTap = widget.onCitationTap;
      final recognizer = onTap == null
          ? null
          : (TapGestureRecognizer()..onTap = () => onTap(number));
      if (recognizer != null) _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: '[$number]',
          style: AppText.mono(
            (style.fontSize ?? 14) - 3,
            weight: FontWeight.w600,
            color: AppColors.accentHi,
          ).copyWith(backgroundColor: AppColors.accent.withA(0.12)),
          recognizer: recognizer,
          mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return spans;
  }
}

class _CopyCodeButton extends StatefulWidget {
  const _CopyCodeButton({required this.text});

  final String text;

  @override
  State<_CopyCodeButton> createState() => _CopyCodeButtonState();
}

class _CopyCodeButtonState extends State<_CopyCodeButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _copy,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: Icon(_copied ? Symbols.check : Symbols.content_copy, size: 14),
      label: Text(
        _copied ? 'Copied' : 'Copy',
        style: AppText.mono(10.5, color: AppColors.textSecondary),
      ),
    );
  }
}
