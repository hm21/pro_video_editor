import 'dart:typed_data';

import 'corner_detector.dart';
import 'lucas_kanade_tracker.dart';
import 'luma_pyramid.dart';
import 'similarity_estimator.dart';
import 'similarity_transform.dart';

/// The global motion between two consecutive frames.
class FrameMotion {
  /// Creates a frame motion.
  const FrameMotion(this.transform, {this.inliers = 0, this.tracked = 0});

  /// Maps coordinates of the earlier frame onto the later one, in pixels
  /// centered on the frame, or null when the frames gave no reliable answer
  /// (a flat wall, heavy motion blur, a cut).
  final SimilarityTransform? transform;

  /// How many tracked points agree with [transform].
  final int inliers;

  /// How many points survived tracking.
  final int tracked;
}

/// Estimates the dominant motion between consecutive luma frames.
///
/// Corners found in each frame are tracked into the next one with
/// [LucasKanadeTracker], checked by tracking them back, and a similarity
/// transform is fitted to them with RANSAC. Points on a subject that moves
/// against the background disagree with the camera motion and drop out as
/// outliers, as long as the background covers more of the frame.
class FrameMotionEstimator {
  /// Creates an estimator for frames of [width] × [height] pixels.
  FrameMotionEstimator({
    required this.width,
    required this.height,
    this.pyramidLevels = 4,
    this.forwardBackwardThreshold = 0.7,
    this.ransacThreshold = 1.0,
    this.minInlierRatio = 0.3,
  });

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// Pyramid depth. Each level doubles the motion the tracker can follow.
  final int pyramidLevels;

  /// A point whose backward track misses its start by more pixels than this
  /// is dropped. A negative value skips the backward track.
  final double forwardBackwardThreshold;

  /// Pixel distance within which a point counts as following the fitted
  /// motion.
  final double ransacThreshold;

  /// The share of tracked points that must follow the fitted motion. Below
  /// it the frames gave no clear answer and the motion is reported as
  /// unreliable rather than guessed.
  final double minInlierRatio;

  final LucasKanadeTracker _tracker = LucasKanadeTracker();
  LumaPyramid? _previous;
  SimilarityTransform? _lastMotion;

  /// Adds the next frame, a row-major 8-bit luma buffer of [width] ×
  /// [height], and returns the motion from the previous frame. Returns null
  /// for the first frame.
  FrameMotion? addFrame(Uint8List luma) {
    final pyramid = LumaPyramid.fromLuma(
      luma,
      width,
      height,
      levelCount: pyramidLevels,
    );
    final previous = _previous;
    _previous = pyramid;
    if (previous == null) return null;
    final motion = _estimate(previous, pyramid);
    _lastMotion = motion.transform;
    return motion;
  }

  FrameMotion _estimate(LumaPyramid previous, LumaPyramid next) {
    final points = detectCorners(previous.levels.first);
    final count = points.length >> 1;
    if (count < 8) return const FrameMotion(null);

    final cx = (width - 1) / 2;
    final cy = (height - 1) / 2;
    // Start each point where the previous frame pair's motion would carry
    // it, so a steady pan converges in fewer iterations.
    final last = _lastMotion;
    final forward = Float32List(points.length);
    final forwardOk = _tracker.track(
      previous,
      next,
      points,
      forward,
      guess: last == null ? null : _mapPoints(points, last, cx, cy),
    );
    var ok = forwardOk;
    if (forwardBackwardThreshold >= 0) {
      final back = Float32List(points.length);
      final backOk = _tracker.track(
        next,
        previous,
        forward,
        back,
        guess: last == null
            ? null
            : _mapPoints(forward, last.inverse(), cx, cy),
      );
      ok = Uint8List(count);
      final limit = forwardBackwardThreshold * forwardBackwardThreshold;
      for (var i = 0; i < count; i++) {
        if (forwardOk[i] == 0 || backOk[i] == 0) continue;
        final ex = back[2 * i] - points[2 * i];
        final ey = back[2 * i + 1] - points[2 * i + 1];
        if (ex * ex + ey * ey < limit) ok[i] = 1;
      }
    }

    var tracked = 0;
    for (var i = 0; i < count; i++) {
      tracked += ok[i];
    }
    final src = Float32List(2 * tracked);
    final dst = Float32List(2 * tracked);
    var k = 0;
    for (var i = 0; i < count; i++) {
      if (ok[i] == 0) continue;
      src[2 * k] = points[2 * i] - cx;
      src[2 * k + 1] = points[2 * i + 1] - cy;
      dst[2 * k] = forward[2 * i] - cx;
      dst[2 * k + 1] = forward[2 * i + 1] - cy;
      k++;
    }
    final fit = fitSimilarityRansac(
      src,
      dst,
      tracked,
      threshold: ransacThreshold,
    );
    if (fit == null || fit.inliers < minInlierRatio * tracked) {
      return FrameMotion(null, tracked: tracked);
    }
    return FrameMotion(fit.transform, inliers: fit.inliers, tracked: tracked);
  }

  static Float32List _mapPoints(
    Float32List points,
    SimilarityTransform transform,
    double cx,
    double cy,
  ) {
    final out = Float32List(points.length);
    for (var i = 0; i < points.length; i += 2) {
      final x = points[i] - cx;
      final y = points[i + 1] - cy;
      out[i] = transform.mapX(x, y) + cx;
      out[i + 1] = transform.mapY(x, y) + cy;
    }
    return out;
  }
}
