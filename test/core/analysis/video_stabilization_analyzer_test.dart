import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/analysis/similarity_transform.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'synthetic_frames.dart';

void main() {
  const width = 240;
  const height = 136;
  const fps = 30;
  final texture = SyntheticTexture(seed: 3);

  /// A handheld camera: 2–9 Hz jitter of [shakePx] and [shakeDegrees] on top
  /// of a slow pan of [panPx] across the clip.
  List<SimilarityTransform> handheld(
    int frames, {
    double shakePx = 3,
    double shakeDegrees = 0.5,
    double panPx = 20,
  }) {
    final rng = Random(5);
    final waves = [
      for (var i = 0; i < 5; i++)
        (
          f: 2 + rng.nextDouble() * 7,
          px: rng.nextDouble() * 2 * pi,
          py: rng.nextDouble() * 2 * pi,
          pr: rng.nextDouble() * 2 * pi,
        ),
    ];
    return [
      for (var t = 0; t < frames; t++)
        () {
          final s = t / fps;
          var dx = 0.0, dy = 0.0, r = 0.0;
          for (final w in waves) {
            dx += sin(2 * pi * w.f * s + w.px);
            dy += sin(2 * pi * w.f * s + w.py);
            r += sin(2 * pi * w.f * s + w.pr);
          }
          return SimilarityTransform.fromParams(
            tx: dx / waves.length * 2 * shakePx + panPx * t / frames,
            ty: dy / waves.length * 2 * shakePx,
            angle: r / waves.length * 2 * shakeDegrees * pi / 180,
          );
        }(),
    ];
  }

  VideoStabilization analyze(
    List<SimilarityTransform> views, {
    double maxZoom = 1.15,
  }) {
    final analyzer = VideoStabilizationAnalyzer(
      width: width,
      height: height,
      maxZoom: maxZoom,
    );
    for (var t = 0; t < views.length; t++) {
      analyzer.addFrame(
        texture.render(width, height, views[t]),
        Duration(microseconds: t * 1000000 ~/ fps),
      );
    }
    return analyzer.finish();
  }

  SimilarityTransform warpOf(StabilizationKeyframe k) =>
      SimilarityTransform.fromParams(
        tx: k.offset.dx * width,
        ty: k.offset.dy * height,
        angle: k.rotation,
        logScale: log(k.scale),
      );

  /// What the viewer's camera does after stabilization: each frame's view
  /// followed by its keyframe warp.
  List<SimilarityTransform> steadied(
    List<SimilarityTransform> views,
    VideoStabilization result,
  ) => [
    for (var t = 0; t < views.length; t++)
      views[t].then(warpOf(result.keyframes[t])),
  ];

  /// RMS of the frame-to-frame acceleration of the frame center, in pixels.
  double jitter(List<SimilarityTransform> path) {
    var sum = 0.0;
    for (var t = 1; t < path.length - 1; t++) {
      final ax = path[t + 1].tx - 2 * path[t].tx + path[t - 1].tx;
      final ay = path[t + 1].ty - 2 * path[t].ty + path[t - 1].ty;
      sum += ax * ax + ay * ay;
    }
    return sqrt(sum / (path.length - 2));
  }

  /// Whether the warped frame still fills the whole output.
  bool fillsOutput(StabilizationKeyframe k) {
    final inverse = warpOf(k).inverse();
    for (final (x, y) in [
      (-width / 2, -height / 2),
      (width / 2, -height / 2),
      (-width / 2, height / 2),
      (width / 2, height / 2),
    ]) {
      if (inverse.mapX(x.toDouble(), y.toDouble()).abs() > width / 2 + 1e-3 ||
          inverse.mapY(x.toDouble(), y.toDouble()).abs() > height / 2 + 1e-3) {
        return false;
      }
    }
    return true;
  }

  group(VideoStabilizationAnalyzer, () {
    test('steadies handheld shake and keeps the pan', () {
      final views = handheld(60);
      final result = analyze(views);
      final after = steadied(views, result);

      expect(result.keyframes, hasLength(views.length));
      expect(result.unreliableFrames, 0);
      expect(jitter(after), lessThan(jitter(views) * 0.1));
      // The intended pan of 20 px survives, scaled by the zoom.
      expect(after.last.tx - after.first.tx, closeTo(20 * result.zoom, 4));
      expect(result.zoom, inInclusiveRange(1.0, 1.15));
      expect(result.keyframes.every(fillsOutput), isTrue);
    });

    test('keeps a steady clip as it is', () {
      final result = analyze(List.filled(20, SimilarityTransform.identity));
      expect(result.zoom, closeTo(1, 1e-3));
      for (final k in result.keyframes) {
        expect(k.offset.distance, lessThan(1e-3));
        expect(k.rotation.abs(), lessThan(1e-4));
        expect(k.scale, closeTo(1, 1e-3));
      }
    });

    test('caps the zoom and keeps some shake when steadying needs more', () {
      final views = handheld(60, shakePx: 8, shakeDegrees: 1);
      final result = analyze(views, maxZoom: 1.1);
      expect(result.zoom, closeTo(1.1, 1e-6));
      expect(result.attenuatedFrames, greaterThan(0));
      expect(result.keyframes.every(fillsOutput), isTrue);
      // Steadier than the input, measured without the zoom's magnification,
      // though not as steady as an unlimited zoom would make it.
      expect(
        jitter(steadied(views, result)) / result.zoom,
        lessThan(jitter(views) * 0.85),
      );
    });

    test('keeps the source timestamps', () {
      final analyzer = VideoStabilizationAnalyzer(width: width, height: height);
      final frame = texture.render(width, height, SimilarityTransform.identity);
      const times = [
        Duration(milliseconds: 1000),
        Duration(milliseconds: 1033),
        Duration(milliseconds: 1071),
      ];
      for (final t in times) {
        analyzer.addFrame(frame, t);
      }
      expect(analyzer.finish().keyframes.map((k) => k.time).toList(), times);
    });

    test('rejects frames of the wrong size or out of order', () {
      final analyzer = VideoStabilizationAnalyzer(width: width, height: height);
      expect(
        () => analyzer.addFrame(Uint8List(10), Duration.zero),
        throwsArgumentError,
      );
      analyzer.addFrame(Uint8List(width * height), Duration.zero);
      expect(
        () => analyzer.addFrame(Uint8List(width * height), Duration.zero),
        throwsArgumentError,
      );
      expect(analyzer.finish, throwsStateError);
    });
  });

  group(VideoStabilization, () {
    test('survives a map round trip', () {
      const stabilization = VideoStabilization(
        zoom: 1.08,
        unreliableFrames: 2,
        attenuatedFrames: 3,
        keyframes: [
          StabilizationKeyframe(
            time: Duration(milliseconds: 40),
            offset: Offset(0.01, -0.02),
            rotation: 0.003,
            scale: 1.08,
          ),
          StabilizationKeyframe(time: Duration(milliseconds: 73)),
        ],
      );
      expect(VideoStabilization.fromMap(stabilization.toMap()), stabilization);
    });
  });
}
