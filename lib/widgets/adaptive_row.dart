import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays out [leading] (usually a label) and [trailing] (a control) on one
/// line, with the control right-aligned, whenever the control's natural width
/// leaves the label at least [minLeadingWidth]. Otherwise the control moves
/// under the label, aligned per [stackedAlignment].
///
/// Unlike a width breakpoint, the decision uses the control's measured size,
/// so a toggle or short button stays inline on a phone while a wide dropdown
/// drops below — and neither is ever squeezed into wrapping its text.
class AdaptiveRow extends MultiChildRenderObjectWidget {
  AdaptiveRow({
    super.key,
    required Widget leading,
    required Widget trailing,
    this.gap = 16,
    this.stackedGap = 10,
    this.minLeadingWidth = 150,
    this.minLeadingFraction = 0,
    this.stackedAlignment = AlignmentDirectional.centerStart,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  }) : super(children: [leading, trailing]);

  final double gap;
  final double stackedGap;
  final double minLeadingWidth;

  /// The label must also keep at least this fraction of the row, so long
  /// descriptions are never squeezed into a tall narrow column.
  final double minLeadingFraction;
  final AlignmentDirectional stackedAlignment;

  /// Vertical alignment of the two children when laid out inline.
  final CrossAxisAlignment crossAxisAlignment;

  @override
  RenderAdaptiveRow createRenderObject(BuildContext context) =>
      RenderAdaptiveRow(
        gap: gap,
        stackedGap: stackedGap,
        minLeadingWidth: minLeadingWidth,
        minLeadingFraction: minLeadingFraction,
        stackedAlignment: stackedAlignment,
        crossAxisAlignment: crossAxisAlignment,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAdaptiveRow renderObject,
  ) {
    renderObject
      ..gap = gap
      ..stackedGap = stackedGap
      ..minLeadingWidth = minLeadingWidth
      ..minLeadingFraction = minLeadingFraction
      ..stackedAlignment = stackedAlignment
      ..crossAxisAlignment = crossAxisAlignment
      ..textDirection = Directionality.of(context);
  }
}

class _AdaptiveRowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderAdaptiveRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _AdaptiveRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _AdaptiveRowParentData> {
  RenderAdaptiveRow({
    required this._gap,
    required this._stackedGap,
    required this._minLeadingWidth,
    required this._minLeadingFraction,
    required this._stackedAlignment,
    required this._crossAxisAlignment,
    required this._textDirection,
  });

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _stackedGap;
  set stackedGap(double value) {
    if (value == _stackedGap) return;
    _stackedGap = value;
    markNeedsLayout();
  }

  double _minLeadingWidth;
  set minLeadingWidth(double value) {
    if (value == _minLeadingWidth) return;
    _minLeadingWidth = value;
    markNeedsLayout();
  }

  double _minLeadingFraction;
  set minLeadingFraction(double value) {
    if (value == _minLeadingFraction) return;
    _minLeadingFraction = value;
    markNeedsLayout();
  }

  AlignmentDirectional _stackedAlignment;
  set stackedAlignment(AlignmentDirectional value) {
    if (value == _stackedAlignment) return;
    _stackedAlignment = value;
    markNeedsLayout();
  }

  CrossAxisAlignment _crossAxisAlignment;
  set crossAxisAlignment(CrossAxisAlignment value) {
    if (value == _crossAxisAlignment) return;
    _crossAxisAlignment = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Whether the last layout put the control under the label.
  bool stacked = false;

  RenderBox get _leading => firstChild!;
  RenderBox get _trailing => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AdaptiveRowParentData) {
      child.parentData = _AdaptiveRowParentData();
    }
  }

  bool _fitsInline(double width) {
    final natural = _trailing.getMaxIntrinsicWidth(double.infinity);
    final minimum = math.max(_minLeadingWidth, width * _minLeadingFraction);
    return width - natural - _gap >= minimum;
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _leading.getMinIntrinsicWidth(height),
    _trailing.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _leading.getMaxIntrinsicWidth(height) +
      _gap +
      _trailing.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => _heightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightFor(width);

  double _heightFor(double width) {
    if (!width.isFinite) {
      return math.max(
        _leading.getMaxIntrinsicHeight(width),
        _trailing.getMaxIntrinsicHeight(width),
      );
    }
    if (_fitsInline(width)) {
      final trailingWidth = math.min(
        _trailing.getMaxIntrinsicWidth(double.infinity),
        width,
      );
      return math.max(
        _leading.getMaxIntrinsicHeight(width - trailingWidth - _gap),
        _trailing.getMaxIntrinsicHeight(trailingWidth),
      );
    }
    return _leading.getMaxIntrinsicHeight(width) +
        _stackedGap +
        _trailing.getMaxIntrinsicHeight(width);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    if (!width.isFinite) {
      final leading = _leading.getDryLayout(const BoxConstraints());
      final trailing = _trailing.getDryLayout(const BoxConstraints());
      return constraints.constrain(
        Size(
          leading.width + _gap + trailing.width,
          math.max(leading.height, trailing.height),
        ),
      );
    }
    if (_fitsInline(width)) {
      final trailing = _trailing.getDryLayout(BoxConstraints(maxWidth: width));
      final leading = _leading.getDryLayout(
        BoxConstraints.tightFor(width: width - trailing.width - _gap),
      );
      return constraints.constrain(
        Size(width, math.max(leading.height, trailing.height)),
      );
    }
    final leading = _leading.getDryLayout(
      BoxConstraints.tightFor(width: width),
    );
    final trailing = _trailing.getDryLayout(BoxConstraints(maxWidth: width));
    return constraints.constrain(
      Size(width, leading.height + _stackedGap + trailing.height),
    );
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final leadingData = _leading.parentData! as _AdaptiveRowParentData;
    final trailingData = _trailing.parentData! as _AdaptiveRowParentData;
    final rtl = _textDirection == TextDirection.rtl;

    if (!width.isFinite) {
      // Unbounded (e.g. inside a horizontal scroller): plain row.
      _leading.layout(const BoxConstraints(), parentUsesSize: true);
      _trailing.layout(const BoxConstraints(), parentUsesSize: true);
      final height = math.max(_leading.size.height, _trailing.size.height);
      leadingData.offset = Offset(0, (height - _leading.size.height) / 2);
      trailingData.offset = Offset(
        _leading.size.width + _gap,
        (height - _trailing.size.height) / 2,
      );
      stacked = false;
      size = constraints.constrain(
        Size(_leading.size.width + _gap + _trailing.size.width, height),
      );
      return;
    }

    stacked = !_fitsInline(width);
    if (!stacked) {
      _trailing.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
      final leadingWidth = math.max(0.0, width - _trailing.size.width - _gap);
      _leading.layout(
        BoxConstraints.tightFor(width: leadingWidth),
        parentUsesSize: true,
      );
      final height = math.max(_leading.size.height, _trailing.size.height);
      double dy(RenderBox child) => switch (_crossAxisAlignment) {
        CrossAxisAlignment.start => 0,
        CrossAxisAlignment.end => height - child.size.height,
        _ => (height - child.size.height) / 2,
      };
      leadingData.offset = Offset(rtl ? width - leadingWidth : 0, dy(_leading));
      trailingData.offset = Offset(
        rtl ? 0 : width - _trailing.size.width,
        dy(_trailing),
      );
      size = constraints.constrain(Size(width, height));
      return;
    }

    _leading.layout(
      BoxConstraints.tightFor(width: width),
      parentUsesSize: true,
    );
    _trailing.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    leadingData.offset = Offset.zero;
    final free = width - _trailing.size.width;
    final alignment = _stackedAlignment.resolve(_textDirection);
    trailingData.offset = Offset(
      free * (alignment.x + 1) / 2,
      _leading.size.height + _stackedGap,
    );
    size = constraints.constrain(
      Size(width, _leading.size.height + _stackedGap + _trailing.size.height),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
