import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '/core/models/image/layer_audio_visualizer_model.dart';
import 'audio_visualizer_shapes.dart';

/// Paints a [LayerAudioVisualizer] in a box, the shapes the export draws.
///
/// Use it to preview a visualizer layer in an editor: give it the levels at
/// the moment the preview shows, from [LayerAudioVisualizer.levelsAt], and
/// size the [CustomPaint] like the layer's box. Every shape is measured in
/// that box, so the preview matches the export at any size.
///
/// ```dart
/// CustomPaint(
///   size: layerSize,
///   painter: AudioVisualizerPainter.at(visualizer, position),
/// );
/// ```
class AudioVisualizerPainter extends CustomPainter {
  /// Creates a painter that draws [levels], one per band from 0 to 1, in
  /// [style].
  AudioVisualizerPainter({
    required this.style,
    required this.color,
    required this.levels,
    this.barFill,
    super.repaint,
  });

  /// Creates a painter that draws [visualizer] as it is at [time] on the
  /// rendered video.
  factory AudioVisualizerPainter.at(
    LayerAudioVisualizer visualizer,
    Duration time, {
    Listenable? repaint,
  }) => AudioVisualizerPainter(
    style: visualizer.style,
    color: visualizer.color,
    levels: visualizer.levelsAt(time),
    barFill: visualizer.barFill,
    repaint: repaint,
  );

  /// How the levels are drawn.
  final AudioVisualizerStyle style;

  /// The color every shape is filled with.
  final Color color;

  /// The level of every band, from 0 to 1.
  final List<double> levels;

  /// How much of its share a bar fills; see [LayerAudioVisualizer.barFill].
  final double? barFill;

  @override
  void paint(Canvas canvas, Size size) {
    final shapes = audioVisualizerShapes(
      style: style,
      width: size.width,
      height: size.height,
      levels: levels,
      barFill: barFill,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final bar in shapes.bars) {
      final rect = RRect.fromLTRBR(
        bar.left,
        bar.top,
        bar.right,
        bar.bottom,
        Radius.circular(bar.radius),
      );
      if (bar.rotation == 0 && bar.pivotX == 0 && bar.pivotY == 0) {
        canvas.drawRRect(rect, paint);
        continue;
      }
      canvas
        ..save()
        ..translate(bar.pivotX, bar.pivotY)
        ..rotate(bar.rotation)
        ..drawRRect(rect, paint)
        ..restore();
    }
    final wave = shapes.wave;
    if (wave != null) {
      final path = Path()..moveTo(wave[0], wave[1]);
      for (var i = 2; i + 5 < wave.length; i += 6) {
        path.cubicTo(
          wave[i],
          wave[i + 1],
          wave[i + 2],
          wave[i + 3],
          wave[i + 4],
          wave[i + 5],
        );
      }
      canvas.drawPath(path..close(), paint);
    }
  }

  @override
  bool shouldRepaint(AudioVisualizerPainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.color != color ||
      oldDelegate.barFill != barFill ||
      !listEquals(oldDelegate.levels, levels);
}
