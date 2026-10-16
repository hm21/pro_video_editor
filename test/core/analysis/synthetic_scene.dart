import 'dart:math';
import 'dart:typed_data';

import 'package:pro_video_editor/core/analysis/similarity_transform.dart';

import 'synthetic_frames.dart';

/// Where the object of a [SyntheticScene] is in one frame.
class ScenePose {
  /// Creates a pose with the object's middle at ([x], [y]), in frame pixels
  /// from the top left, grown by [scale] and turned by [rotation] radians
  /// clockwise.
  ScenePose(num x, num y, {this.scale = 1, this.rotation = 0})
    : x = x.toDouble(),
      y = y.toDouble();

  /// Horizontal position of the object's middle.
  final double x;

  /// Vertical position of the object's middle.
  final double y;

  /// How much larger than its own size the object shows.
  final double scale;

  /// How far the object is turned, in radians, clockwise.
  final double rotation;
}

/// A textured rectangle moving over a textured background, both sampled
/// exactly, so each frame shows the object where its [ScenePose] says.
///
/// The object can have a part of its own, a smaller textured square that
/// moves on its own, like an arm.
class SyntheticScene {
  /// Creates a scene whose object measures [objectWidth] × [objectHeight]
  /// pixels at a scale of 1, and whose part measures [partSize] pixels
  /// square.
  SyntheticScene({
    required this.width,
    required this.height,
    this.objectWidth = 44,
    this.objectHeight = 36,
    this.partSize = 16,
  });

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// Width of the object at a scale of 1.
  final double objectWidth;

  /// Height of the object at a scale of 1.
  final double objectHeight;

  /// Width and height of the object's part.
  final double partSize;

  final SyntheticTexture _background = SyntheticTexture(seed: 11);
  final SyntheticTexture _object = SyntheticTexture(seed: 23);
  final SyntheticTexture _part = SyntheticTexture(seed: 37);

  /// Renders the frame with the object at [pose], its part with its middle
  /// at [part] when given, and the background seen through [camera], which
  /// maps texture coordinates onto centered frame pixels. A [flat] frame
  /// shows a uniform grey, like a frame lost to motion blur.
  Uint8List render(
    ScenePose pose, {
    SimilarityTransform camera = SimilarityTransform.identity,
    bool flat = false,
    Point<double>? part,
  }) {
    final out = Uint8List(width * height);
    if (flat) return out..fillRange(0, out.length, 110);
    final inverse = camera.inverse();
    final cos0 = cos(pose.rotation);
    final sin0 = sin(pose.rotation);
    final cx = (width - 1) / 2;
    final cy = (height - 1) / 2;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - pose.x;
        final dy = y - pose.y;
        final lx = (cos0 * dx + sin0 * dy) / pose.scale;
        final ly = (-sin0 * dx + cos0 * dy) / pose.scale;
        final double v;
        if (part != null &&
            (x - part.x).abs() < partSize / 2 &&
            (y - part.y).abs() < partSize / 2) {
          v = _part.sample(x - part.x, y - part.y);
        } else if (lx.abs() < objectWidth / 2 && ly.abs() < objectHeight / 2) {
          v = _object.sample(lx, ly);
        } else {
          final ox = x - cx;
          final oy = y - cy;
          v = _background.sample(inverse.mapX(ox, oy), inverse.mapY(ox, oy));
        }
        out[y * width + x] = v.round().clamp(0, 255);
      }
    }
    return out;
  }
}
