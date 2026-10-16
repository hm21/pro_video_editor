import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/analysis/similarity_transform.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'synthetic_scene.dart';

void main() {
  const width = 240;
  const height = 136;
  const fps = 30;
  final scene = SyntheticScene(width: width, height: height);

  Duration frameTime(int frame) =>
      Duration(microseconds: (frame * 1e6 / fps).round());

  /// The region drawn tightly around the object at [pose], grown by
  /// [margin] (a fraction of its size) on every side.
  Rect regionAround(ScenePose pose, {double margin = 0}) => Rect.fromCenter(
    center: Offset(pose.x / width, pose.y / height),
    width: scene.objectWidth * pose.scale * (1 + 2 * margin) / width,
    height: scene.objectHeight * pose.scale * (1 + 2 * margin) / height,
  );

  /// Tracks the object through [poses], one frame each, and returns the
  /// sample of every frame (null where the tracker found nothing).
  List<ObjectTrackSample?> track(
    List<ScenePose> poses, {
    List<SimilarityTransform>? cameras,
    Set<int> flatFrames = const {},
    double margin = 0,
    VideoObjectTracker? tracker,
  }) {
    final t =
        tracker ??
        VideoObjectTracker(
          width: width,
          height: height,
          region: regionAround(poses.first, margin: margin),
        );
    return [
      for (var i = 0; i < poses.length; i++)
        t.addFrame(
          scene.render(
            poses[i],
            camera: cameras?[i] ?? SimilarityTransform.identity,
            flat: flatFrames.contains(i),
          ),
          frameTime(i),
        ),
    ];
  }

  /// Asserts that [sample] has the object's middle within [tolerancePx] of
  /// [pose].
  void expectAt(
    ObjectTrackSample? sample,
    ScenePose pose, {
    double tolerancePx = 0.75,
    String? reason,
  }) {
    expect(sample, isNotNull, reason: reason);
    expect(
      sample!.center.dx * width,
      closeTo(pose.x, tolerancePx),
      reason: 'x ${reason ?? ''}',
    );
    expect(
      sample.center.dy * height,
      closeTo(pose.y, tolerancePx),
      reason: 'y ${reason ?? ''}',
    );
  }

  group(VideoObjectTracker, () {
    test('starts on the marked region', () {
      final pose = ScenePose(80, 60);
      final samples = track([pose]);
      expectAt(samples.single, pose, tolerancePx: 1e-6);
      expect(samples.single!.scale, 1);
      expect(samples.single!.rotation, 0);
      expect(samples.single!.region, regionAround(pose));
      expect(samples.single!.time, Duration.zero);
    });

    test('follows an object moving across a still background', () {
      final poses = [
        for (var i = 0; i < 30; i++) ScenePose(60 + 4 * i, 70 - 0.6 * i),
      ];
      final samples = track(poses);
      for (var i = 0; i < poses.length; i++) {
        expectAt(samples[i], poses[i], reason: 'frame $i');
      }
    });

    test('follows the object, not the background panning the other way', () {
      final poses = [
        for (var i = 0; i < 30; i++) ScenePose(70 + 3 * i, 68 + 0.5 * i),
      ];
      final cameras = [
        for (var i = 0; i < 30; i++)
          SimilarityTransform.fromParams(tx: -2.0 * i, ty: 0.4 * i),
      ];
      // Drawn loosely, so some of the background is inside the region.
      final samples = track(poses, cameras: cameras, margin: 0.15);
      for (var i = 0; i < poses.length; i++) {
        expectAt(samples[i], poses[i], tolerancePx: 1, reason: 'frame $i');
      }
    });

    test('measures how much the object grows', () {
      final poses = [
        for (var i = 0; i < 30; i++)
          ScenePose(120, 68, scale: 1 + 0.3 * i / 29),
      ];
      final samples = track(poses);
      expect(samples.last!.scale, closeTo(1.3, 0.03));
      expect(
        samples.last!.size.width * width,
        closeTo(scene.objectWidth * 1.3, 1.5),
      );
      expectAt(samples.last, poses.last);
    });

    test('measures how far the object turns', () {
      final poses = [
        for (var i = 0; i < 30; i++)
          ScenePose(120, 68, rotation: 15 * pi / 180 * i / 29),
      ];
      final samples = track(poses);
      expect(samples.last!.rotation * 180 / pi, closeTo(15, 1.5));
      expectAt(samples.last, poses.last);
    });

    test('keeps following through a frame it cannot read', () {
      final poses = [for (var i = 0; i < 20; i++) ScenePose(60 + 3 * i, 68)];
      final tracker = VideoObjectTracker(
        width: width,
        height: height,
        region: regionAround(poses.first),
      );
      final samples = track(poses, flatFrames: {8, 9}, tracker: tracker);
      expect(samples[8], isNull);
      expect(samples[9], isNull);
      expect(tracker.isLost, isFalse);
      for (final i in [7, 10, 19]) {
        expectAt(samples[i], poses[i], reason: 'frame $i');
      }
    });

    test('runs backward in time as well', () {
      final poses = [
        for (var i = 0; i < 20; i++) ScenePose(180 - 4 * i, 60 + i),
      ];
      final tracker = VideoObjectTracker(
        width: width,
        height: height,
        region: regionAround(poses.first),
      );
      for (var i = 0; i < poses.length; i++) {
        final sample = tracker.addFrame(
          scene.render(poses[i]),
          frameTime(poses.length - i),
        );
        expectAt(sample, poses[i], reason: 'frame $i');
      }
    });

    test('loses the object once it leaves the frame', () {
      final poses = [for (var i = 0; i < 30; i++) ScenePose(160 + 6 * i, 68)];
      final tracker = VideoObjectTracker(
        width: width,
        height: height,
        region: regionAround(poses.first),
      );
      final samples = track(poses, tracker: tracker);
      expect(tracker.isLost, isTrue);
      // The middle crosses the right edge after frame 13.
      for (var i = 0; i < 10; i++) {
        expectAt(samples[i], poses[i], reason: 'frame $i');
      }
      expect(samples.sublist(16), everyElement(isNull));
    });

    test('loses a region without detail after the skipped frames', () {
      final flat = Uint8List(width * height)..fillRange(0, width * height, 90);
      final tracker = VideoObjectTracker(
        width: width,
        height: height,
        region: const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2),
        maxSkippedFrames: 2,
      );
      expect(tracker.addFrame(flat, Duration.zero), isNotNull);
      for (var i = 1; i <= 3; i++) {
        expect(tracker.addFrame(flat, frameTime(i)), isNull);
      }
      expect(tracker.isLost, isTrue);
    });

    test('rejects a frame of the wrong size', () {
      final tracker = VideoObjectTracker(
        width: width,
        height: height,
        region: const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2),
      );
      expect(
        () => tracker.addFrame(Uint8List(10), Duration.zero),
        throwsArgumentError,
      );
    });
  });
}
