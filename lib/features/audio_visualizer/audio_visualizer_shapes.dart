import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '/core/models/image/layer_audio_visualizer_model.dart';

/// How much of its slot a bar of [AudioVisualizerStyle.bars] and
/// [AudioVisualizerStyle.mirroredBars] fills; the rest is the gap to the
/// next bar.
const double audioVisualizerBarFill = 0.7;

/// The level a band of [AudioVisualizerStyle.wave] never drops below, so a
/// silent wave still shows as a thin line.
const double audioVisualizerWaveMinLevel = 0.04;

/// The radius of the ring of [AudioVisualizerStyle.circle], against the
/// largest circle that fits the box.
const double audioVisualizerCircleInnerRadius = 0.5;

/// How much of its share of the ring a bar of [AudioVisualizerStyle.circle]
/// fills.
const double audioVisualizerCircleBarFill = 0.6;

/// A rounded bar of a visualizer: a box with fully rounded corners of
/// [radius], turned [rotation] radians clockwise about the point
/// ([pivotX], [pivotY]) of the layer's box, its own coordinates measured
/// from that point.
@immutable
class AudioVisualizerBar {
  /// Creates a bar.
  const AudioVisualizerBar({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.radius,
    this.pivotX = 0,
    this.pivotY = 0,
    this.rotation = 0,
  });

  /// The left edge, from [pivotX].
  final double left;

  /// The top edge, from [pivotY].
  final double top;

  /// The right edge, from [pivotX].
  final double right;

  /// The bottom edge, from [pivotY].
  final double bottom;

  /// The radius of every corner.
  final double radius;

  /// Where the bar's coordinates start, and what it turns about, in the
  /// layer's box.
  final double pivotX;

  /// See [pivotX].
  final double pivotY;

  /// The clockwise turn about the pivot, in radians.
  final double rotation;

  @override
  bool operator ==(Object other) =>
      other is AudioVisualizerBar &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.radius == radius &&
      other.pivotX == pivotX &&
      other.pivotY == pivotY &&
      other.rotation == rotation;

  @override
  int get hashCode =>
      Object.hash(left, top, right, bottom, radius, pivotX, pivotY, rotation);

  @override
  String toString() =>
      'AudioVisualizerBar($left, $top, $right, $bottom, r: $radius, '
      'pivot: ($pivotX, $pivotY), rotation: $rotation)';
}

/// The shapes a visualizer fills for one set of levels: [bars], or the
/// closed outline [wave].
@immutable
class AudioVisualizerShapes {
  /// Creates the shapes of a visualizer.
  const AudioVisualizerShapes({this.bars = const [], this.wave});

  /// The bars, drawn in order.
  final List<AudioVisualizerBar> bars;

  /// The outline of a wave, or `null` for a style of bars: a start point
  /// (`x`, `y`) followed by cubic Bézier curves of six values each (first
  /// control point, second control point, end point), closed back to the
  /// start.
  final List<double>? wave;
}

/// The shapes [style] draws for [levels], one level per band from 0 to 1, in
/// a box of [width] by [height] whose top-left corner is the origin.
///
/// [barFill] is how much of its share a bar fills; see
/// [LayerAudioVisualizer.barFill]. `null` takes the style's own, as does a
/// value outside above 0 to 1, which the native renderers never receive.
///
/// The Android, iOS and macOS renderers compute the same shapes from the
/// same numbers; a change here has to be made there too.
AudioVisualizerShapes audioVisualizerShapes({
  required AudioVisualizerStyle style,
  required double width,
  required double height,
  required List<double> levels,
  double? barFill,
}) {
  final count = levels.length;
  if (count == 0 || width <= 0 || height <= 0) {
    return const AudioVisualizerShapes();
  }
  double level(int band) => audioVisualizerUnitLevel(levels[band]);
  final fill = barFill != null && barFill > 0 && barFill <= 1 ? barFill : null;

  switch (style) {
    case AudioVisualizerStyle.bars:
    case AudioVisualizerStyle.mirroredBars:
      final slot = width / count;
      final barWidth = slot * (fill ?? audioVisualizerBarFill);
      // A silent bar is a dot as wide as the bar.
      final minHeight = math.min(barWidth, height);
      return AudioVisualizerShapes(
        bars: [
          for (var band = 0; band < count; band++)
            _bar(
              left: band * slot + (slot - barWidth) / 2,
              width: barWidth,
              height: math.min(
                height,
                math.max(minHeight, level(band) * height),
              ),
              boxHeight: height,
              mirrored: style == AudioVisualizerStyle.mirroredBars,
            ),
        ],
      );
    case AudioVisualizerStyle.circle:
      final radius = math.min(width, height) / 2;
      final bars = count * 2;
      final ring = radius * audioVisualizerCircleInnerRadius;
      final barWidth = math.min(
        2 * math.pi * ring / bars * (fill ?? audioVisualizerCircleBarFill),
        (radius - ring) / 2,
      );
      final maxLength = math.max(0.0, radius - ring - barWidth);
      return AudioVisualizerShapes(
        bars: [
          for (var bar = 0; bar < bars; bar++)
            AudioVisualizerBar(
              left: -barWidth / 2,
              // The bands run from the top down both sides of the ring.
              top:
                  -(ring +
                      barWidth +
                      level(bar < count ? bar : bars - 1 - bar) * maxLength),
              right: barWidth / 2,
              bottom: -ring,
              radius: barWidth / 2,
              pivotX: width / 2,
              pivotY: height / 2,
              rotation: 2 * math.pi * (bar + 0.5) / bars,
            ),
        ],
      );
    case AudioVisualizerStyle.wave:
      return AudioVisualizerShapes(wave: _waveOutline(width, height, levels));
  }
}

/// A bar of [AudioVisualizerStyle.bars], standing on the bottom of a box of
/// [boxHeight], or of [AudioVisualizerStyle.mirroredBars], centered in it.
AudioVisualizerBar _bar({
  required double left,
  required double width,
  required double height,
  required double boxHeight,
  required bool mirrored,
}) {
  final top = mirrored ? (boxHeight - height) / 2 : boxHeight - height;
  return AudioVisualizerBar(
    left: left,
    top: top,
    right: left + width,
    bottom: top + height,
    radius: math.min(width, height) / 2,
  );
}

/// The outline of [AudioVisualizerStyle.wave]: a Catmull-Rom curve through
/// one point per band along the top, mirrored along the bottom.
List<double> _waveOutline(double width, double height, List<double> levels) {
  final count = levels.length;
  final middle = height / 2;
  // Each point's x and its distance from the middle line, with a point of
  // no height at either edge so the wave tapers there.
  final xs = List<double>.filled(count + 2, 0);
  final amplitudes = List<double>.filled(count + 2, 0);
  xs[count + 1] = width;
  for (var band = 0; band < count; band++) {
    xs[band + 1] = (band + 0.5) * width / count;
    amplitudes[band + 1] =
        math.max(
          audioVisualizerWaveMinLevel,
          audioVisualizerUnitLevel(levels[band]),
        ) *
        middle;
  }

  final last = count + 1;
  // The control points of the curve from point i to point i + 1, kept
  // between the middle line and the edge of the box, so the curve can
  // neither cross the middle line nor leave the box.
  (double, double, double, double) controls(int i) {
    final before = math.max(0, i - 1);
    final after = math.min(last, i + 2);
    return (
      xs[i] + (xs[i + 1] - xs[before]) / 6,
      (amplitudes[i] + (amplitudes[i + 1] - amplitudes[before]) / 6).clamp(
        0.0,
        middle,
      ),
      xs[i + 1] - (xs[after] - xs[i]) / 6,
      (amplitudes[i + 1] - (amplitudes[after] - amplitudes[i]) / 6).clamp(
        0.0,
        middle,
      ),
    );
  }

  final outline = <double>[0, middle];
  // Along the top, left to right.
  for (var i = 0; i < last; i++) {
    final (c1x, c1a, c2x, c2a) = controls(i);
    outline.addAll([
      c1x,
      middle - c1a,
      c2x,
      middle - c2a,
      xs[i + 1],
      middle - amplitudes[i + 1],
    ]);
  }
  // Back along the bottom, right to left, through the same control points.
  for (var i = last - 1; i >= 0; i--) {
    final (c1x, c1a, c2x, c2a) = controls(i);
    outline.addAll([
      c2x,
      middle + c2a,
      c1x,
      middle + c1a,
      xs[i],
      middle + amplitudes[i],
    ]);
  }
  return outline;
}
