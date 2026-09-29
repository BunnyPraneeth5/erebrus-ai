import 'package:erebrus_ai/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    String data, {
    ValueChanged<int>? onCitationTap,
    Widget? trailing,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(
              data: data,
              onCitationTap: onCitationTap,
              trailing: trailing,
            ),
          ),
        ),
      ),
    );
  }

  /// All visible text, joined, as the user would read it.
  String visibleText(WidgetTester tester) => tester
      .widgetList<RichText>(find.byType(RichText))
      .map((text) => text.text.toPlainText())
      .join('\n');

  TextStyle? styleOf(WidgetTester tester, String fragment) {
    TextStyle? found;
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == fragment) {
          found = span.style;
          return false;
        }
        return true;
      });
    }
    return found;
  }

  testWidgets('formats emphasis without leaving markup symbols', (
    tester,
  ) async {
    await pump(
      tester,
      '# Moon landing\n\nApollo 11 landed on **July 20, 1969**, '
      'an *extraordinary* ~~rumour~~ fact with `code`.',
    );
    final text = visibleText(tester);
    expect(text, contains('Moon landing'));
    expect(text, contains('July 20, 1969'));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('#')));
    expect(text, isNot(contains('~~')));
    expect(text, isNot(contains('`')));
    expect(styleOf(tester, 'July 20, 1969')?.fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'extraordinary')?.fontStyle, FontStyle.italic);
    expect(styleOf(tester, 'rumour')?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('renders bullet, numbered and task lists', (tester) async {
    await pump(
      tester,
      '- alpha\n- **beta**\n\n3. three\n4. four\n\n- [x] done\n- [ ] todo',
    );
    final text = visibleText(tester);
    expect(text, contains('•'));
    expect(text, contains('3.'));
    expect(text, contains('4.'));
    expect(text, isNot(contains('- ')));
    expect(text, isNot(contains('[x]')));
    expect(text, contains('done'));
  });

  testWidgets('renders fenced code with language label and copy', (
    tester,
  ) async {
    await pump(tester, '```dart\nvoid main() => print("hi");\n```');
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('void main() => print("hi");'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(visibleText(tester), isNot(contains('```')));
  });

  testWidgets('an unclosed fence while streaming still renders as code', (
    tester,
  ) async {
    await pump(
      tester,
      'Here:\n\n```python\nprint(1)\nprint(',
      trailing: const SizedBox(key: ValueKey('cursor'), width: 8, height: 12),
    );
    expect(find.text('python'), findsOneWidget);
    expect(find.textContaining('print(1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('cursor')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders tables without pipe characters', (tester) async {
    await pump(
      tester,
      '| Model | Size |\n|---|---|\n| Qwen3 | 0.6B |\n| Llama | 8B |',
    );
    expect(find.byType(Table), findsOneWidget);
    final text = visibleText(tester);
    expect(text, contains('Qwen3'));
    expect(text, isNot(contains('|')));
    expect(styleOf(tester, 'Model')?.fontWeight, FontWeight.w600);
  });

  testWidgets('citations are tappable and plain text otherwise', (
    tester,
  ) async {
    final tapped = <int>[];
    await pump(
      tester,
      'Flutter 3.47.5 is current [2].',
      onCitationTap: tapped.add,
    );
    expect(visibleText(tester), contains('[2]'));
    final citation = tester.widgetList<RichText>(find.byType(RichText)).expand((
      rich,
    ) {
      final spans = <TextSpan>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == '[2]') spans.add(span);
        return true;
      });
      return spans;
    }).single;
    (citation.recognizer! as dynamic).onTap();
    expect(tapped, [2]);
  });

  testWidgets('blockquotes and rules render', (tester) async {
    await pump(tester, '> quoted *text*\n\n---\n\nafter');
    final text = visibleText(tester);
    expect(text, contains('quoted'));
    expect(text, isNot(contains('>')));
    expect(find.byType(Divider), findsOneWidget);
  });
}
