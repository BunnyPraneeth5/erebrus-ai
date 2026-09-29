import 'package:erebrus_ai/widgets/adaptive_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<RenderAdaptiveRow> pumpRow(
    WidgetTester tester, {
    required double width,
    double controlWidth = 60,
    double minLeadingWidth = 150,
    double minLeadingFraction = 0,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: AdaptiveRow(
              leading: const SizedBox(key: ValueKey('label'), height: 20),
              trailing: SizedBox(
                key: const ValueKey('control'),
                width: controlWidth,
                height: 30,
              ),
              gap: 10,
              stackedGap: 8,
              minLeadingWidth: minLeadingWidth,
              minLeadingFraction: minLeadingFraction,
              stackedAlignment: AlignmentDirectional.centerEnd,
            ),
          ),
        ),
      ),
    );
    return tester.renderObject<RenderAdaptiveRow>(find.byType(AdaptiveRow));
  }

  testWidgets('keeps a small control inline, right-aligned and centered', (
    tester,
  ) async {
    final row = await pumpRow(tester, width: 300);
    expect(row.stacked, isFalse);
    expect(row.size, const Size(300, 30));
    final control = tester.getTopLeft(find.byKey(const ValueKey('control')));
    expect(control, const Offset(240, 0));
    // Label fills the rest of the row, vertically centered.
    expect(tester.getSize(find.byKey(const ValueKey('label'))).width, 230);
    expect(tester.getTopLeft(find.byKey(const ValueKey('label'))).dy, 5);
  });

  testWidgets('stacks a control that would squeeze the label', (tester) async {
    final row = await pumpRow(tester, width: 300, controlWidth: 200);
    expect(row.stacked, isTrue);
    expect(row.size, const Size(300, 20 + 8 + 30));
    expect(tester.getSize(find.byKey(const ValueKey('label'))).width, 300);
    // Still right-aligned when stacked.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('control'))),
      const Offset(100, 28),
    );
  });

  testWidgets('honors the minimum label fraction', (tester) async {
    // 300 - 60 - 10 = 230 px of label: enough for 150 px, not for 80%.
    final inline = await pumpRow(tester, width: 300, minLeadingFraction: 0.5);
    expect(inline.stacked, isFalse);
    final stacked = await pumpRow(tester, width: 300, minLeadingFraction: 0.8);
    expect(stacked.stacked, isTrue);
  });
}
