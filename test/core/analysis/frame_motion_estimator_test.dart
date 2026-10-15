import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/analysis/frame_motion_estimator.dart';
import 'package:pro_video_editor/core/analysis/similarity_transform.dart';

import 'synthetic_frames.dart';

void main() {
  const width = 240;
  const height = 136;
  final texture = SyntheticTexture();

  /// Estimates the motion that turns a frame seen through [from] into one
  /// seen through [to].
  FrameMotion estimate(
    SimilarityTransform from,
    SimilarityTransform to, {
    (double, double, double, double)? occluder,
    SimilarityTransform? occluderTo,
  }) {
    final estimator = FrameMotionEstimator(width: width, height: height);
    expect(
      estimator.addFrame(
        texture.render(
          width,
          height,
          from,
          occluder: occluder,
          occluderView: from,
        ),
      ),
      isNull,
    );
    return estimator.addFrame(
      texture.render(
        width,
        height,
        to,
        occluder: occluder,
        occluderView: occluderTo,
      ),
    )!;
  }

  /// Asserts that [actual] moves points across the frame like [expected].
  void expectSameMotion(
    SimilarityTransform? actual,
    SimilarityTransform expected, {
    double tolerancePx = 0.15,
  }) {
    expect(actual, isNotNull);
    for (final (x, y) in [
      (-width / 2.0, -height / 2.0),
      (width / 2.0, -height / 2.0),
      (-width / 2.0, height / 2.0),
      (width / 2.0, height / 2.0),
      (0.0, 0.0),
    ]) {
      expect(
        actual!.mapX(x, y),
        closeTo(expected.mapX(x, y), tolerancePx),
        reason: 'x at ($x, $y)',
      );
      expect(
        actual.mapY(x, y),
        closeTo(expected.mapY(x, y), tolerancePx),
        reason: 'y at ($x, $y)',
      );
    }
  }

  group(FrameMotionEstimator, () {
    test('recovers a sub-pixel shift, a small turn and a zoom', () {
      final to = SimilarityTransform.fromParams(
        tx: 3.4,
        ty: -2.1,
        angle: 0.8 * pi / 180,
        logScale: log(1.01),
      );
      final motion = estimate(SimilarityTransform.identity, to);
      expectSameMotion(motion.transform, to);
      expect(motion.inliers, greaterThan(50));
    });

    test('follows a fast jump beyond the tracking window', () {
      final to = SimilarityTransform.fromParams(tx: -22, ty: 15);
      expectSameMotion(
        estimate(SimilarityTransform.identity, to).transform,
        to,
      );
    });

    test('reports the camera, not a subject moving against it', () {
      final camera = SimilarityTransform.fromParams(tx: 2.5, ty: 1.5);
      // A subject covering a quarter of the frame walks the other way.
      final motion = estimate(
        SimilarityTransform.identity,
        camera,
        occluder: (-60, -34, 60, 34),
        occluderTo: SimilarityTransform.fromParams(tx: -6, ty: 3),
      );
      expectSameMotion(motion.transform, camera, tolerancePx: 0.3);
    });

    test('gives no motion for a featureless frame', () {
      final estimator = FrameMotionEstimator(width: width, height: height);
      final flat = Uint8List(width * height)..fillRange(0, width * height, 90);
      estimator.addFrame(flat);
      final motion = estimator.addFrame(flat)!;
      expect(motion.transform, isNull);
    });
  });
}
