import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/core/analysis/frame_motion_estimator.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// A 720x1280, 30 fps, 4 s clip with plenty of texture to track.
const _clip = 'assets/tests/test_b.mp4';

/// End to end: render a clip moved by keyframes and measure, frame by frame,
/// how the rendered frame is moved against the source frame it shows. A
/// keyframe looked up at the wrong time — the output time instead of the
/// source time, before a speed change instead of after it, unmirrored in a
/// reversed clip — or a motion turned or shifted the wrong way shows up as a
/// mismatch, on each platform.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final clip = EditorVideo.asset(_clip);
  const box = ui.Size(270, 480);

  // Still at 0.8 s, then eased into a zoom, a turn and a shift by 2.4 s.
  const keyframes = [
    SegmentKeyframe(
      time: Duration(milliseconds: 800),
      curve: AnimationCurve.easeInOut,
    ),
    SegmentKeyframe(
      time: Duration(milliseconds: 2400),
      offset: ui.Offset(0.04, -0.03),
      scale: 1.25,
      rotation: 0.08,
    ),
  ];

  /// The motion [keyframes] give the source frame at [source].
  ({double scale, double rotation, double dx, double dy}) expectedAt(
    Duration source,
  ) {
    final from = keyframes.first;
    final to = keyframes.last;
    final span = (to.time - from.time).inMicroseconds;
    final linear = ((source - from.time).inMicroseconds / span).clamp(0.0, 1.0);
    // The quadratic ease-in-out both platforms ease with.
    final t = linear < 0.5
        ? 2 * linear * linear
        : -1 + (4 - 2 * linear) * linear;
    double mix(double a, double b) => a + (b - a) * t;
    return (
      scale: mix(from.scale, to.scale),
      rotation: mix(from.rotation, to.rotation),
      dx: mix(from.offset.dx, to.offset.dx),
      dy: mix(from.offset.dy, to.offset.dy),
    );
  }

  Future<List<LumaFrame>> frames(
    EditorVideo video, {
    Duration? startTime,
    Duration? endTime,
  }) => pve
      .getLumaFrameStream(
        LumaFrameConfigs(
          video: video,
          outputSize: box,
          startTime: startTime,
          endTime: endTime,
        ),
      )
      .toList();

  /// The motion from [source] onto [rendered].
  FrameMotion motionBetween(LumaFrame source, LumaFrame rendered) {
    final estimator = FrameMotionEstimator(
      width: source.width,
      height: source.height,
    )..addFrame(source.bytes);
    return estimator.addFrame(rendered.bytes)!;
  }

  /// Renders [segment] with and without its keyframes and checks every third
  /// frame: the motion from the still render's frame onto the moved one must
  /// be the one the keyframes give the source frame it shows.
  ///
  /// Which source frame that is, [sourceTimeOf] places from the time since
  /// the first rendered frame to within a few frames, and the source frame
  /// the still render shows unmoved settles it: a platform may open a
  /// reversed clip a few frames early.
  Future<void> expectMovedByKeyframes(
    VideoSegment segment,
    Duration Function(Duration elapsed) sourceTimeOf,
  ) async {
    Future<List<LumaFrame>> rendered(VideoSegment segment) async => frames(
      EditorVideo.memory(
        await pve.renderVideo(VideoRenderData(videoSegments: [segment])),
      ),
    );

    final moved = await rendered(segment);
    final still = await rendered(segment.copyWith(keyframes: const []));
    final source = await frames(segment.video);
    expect(moved, hasLength(still.length));

    /// The source frame [frame] shows, unmoved: the one it differs least
    /// from, among those around [around].
    LumaFrame? shownSource(LumaFrame frame, Duration around) {
      LumaFrame? best;
      var bestDistance = double.infinity;
      for (final candidate in source) {
        if ((candidate.time - around).abs() >
            const Duration(milliseconds: 140)) {
          continue;
        }
        final transform = motionBetween(candidate, frame).transform;
        if (transform == null) continue;
        final distance =
            transform.tx.abs() +
            transform.ty.abs() +
            100 * (transform.scale - 1).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = candidate;
        }
      }
      return best;
    }

    final rows = <String>[];
    final misses = <String>[];
    var checked = 0;
    var reliable = 0;
    for (var i = 0; i < still.length; i += 3) {
      checked++;
      final shown = shownSource(
        still[i],
        sourceTimeOf(still[i].time - still.first.time),
      );
      final motion = motionBetween(still[i], moved[i]).transform;
      if (shown == null || motion == null) continue;
      reliable++;
      final expected = expectedAt(shown.time);
      final width = moved[i].width;
      final height = moved[i].height;
      final row =
          'output ${moved[i].time}, source ${shown.time}: '
          'scale ${motion.scale.toStringAsFixed(3)}/'
          '${expected.scale.toStringAsFixed(3)}, '
          'angle ${motion.angle.toStringAsFixed(3)}/'
          '${expected.rotation.toStringAsFixed(3)}, '
          'tx ${motion.tx.toStringAsFixed(1)}/'
          '${(expected.dx * width).toStringAsFixed(1)}, '
          'ty ${motion.ty.toStringAsFixed(1)}/'
          '${(expected.dy * height).toStringAsFixed(1)}';
      rows.add(row);
      if ((motion.scale - expected.scale).abs() > 0.015 ||
          (motion.angle - expected.rotation).abs() > 0.012 ||
          (motion.tx - expected.dx * width).abs() > 1.5 ||
          (motion.ty - expected.dy * height).abs() > 1.5) {
        misses.add(row);
      }
    }
    // ignore: avoid_print
    print('measured (got/want):\n${rows.join('\n')}');
    expect(checked, greaterThan(10));
    expect(reliable, greaterThanOrEqualTo((checked * 0.8).floor()));
    expect(misses, isEmpty);
  }

  group('VideoSegment.keyframes', () {
    testWidgets('moves each frame of a trimmed clip by its source time', (
      _,
    ) async {
      await expectMovedByKeyframes(
        VideoSegment(
          video: clip,
          // Starts between two frames, so the first frame shown is the one
          // at 533 ms rather than the start of the file.
          startTime: const Duration(milliseconds: 515),
          endTime: const Duration(milliseconds: 3000),
          keyframes: keyframes,
        ),
        (elapsed) => const Duration(milliseconds: 533) + elapsed,
      );
    });

    testWidgets('keeps the motion on its frames at double speed', (_) async {
      await expectMovedByKeyframes(
        VideoSegment(video: clip, playbackSpeed: 2, keyframes: keyframes),
        (elapsed) => elapsed * 2,
      );
    });

    testWidgets('plays the motion backwards in a reversed clip', (_) async {
      await expectMovedByKeyframes(
        VideoSegment(
          video: clip,
          startTime: const Duration(milliseconds: 500),
          endTime: const Duration(milliseconds: 3000),
          reverseVideo: true,
          keyframes: keyframes,
        ),
        // About the last frame before the end.
        (elapsed) => const Duration(microseconds: 2966667) - elapsed,
      );
    });

    testWidgets('moves a clip stored with a rotation flag upright', (_) async {
      await expectMovedByKeyframes(
        VideoSegment(
          // 640x360 stored, flagged -90°: shown as 360x640, 30 fps, 2 s.
          video: EditorVideo.asset('assets/tests/test_g.mp4'),
          keyframes: keyframes,
        ),
        (elapsed) => elapsed,
      );
    });

    testWidgets('moves a clip inside an overlap transition', (_) async {
      /// The mean luma of the four corners of the frame at [time].
      Future<double> cornerLuma(Uint8List rendered, Duration time) async {
        final frame = (await frames(
          EditorVideo.memory(rendered),
          startTime: time,
          endTime: time + const Duration(milliseconds: 60),
        )).first;
        var sum = 0;
        var count = 0;
        for (final (cx, cy) in [
          (0.05, 0.05),
          (0.95, 0.05),
          (0.05, 0.95),
          (0.95, 0.95),
        ]) {
          final x0 = (cx * frame.width).round();
          final y0 = (cy * frame.height).round();
          for (var y = y0 - 3; y <= y0 + 3; y++) {
            for (var x = x0 - 3; x <= x0 + 3; x++) {
              sum += frame.bytes[y * frame.width + x];
              count++;
            }
          }
        }
        return sum / count;
      }

      Future<Uint8List> render(List<SegmentKeyframe> incoming) =>
          pve.renderVideo(
            VideoRenderData(
              videoSegments: [
                VideoSegment(
                  video: clip,
                  endTime: const Duration(seconds: 2),
                  transition: const ClipTransition(
                    type: ClipTransitionType.dissolve,
                    duration: Duration(milliseconds: 500),
                  ),
                ),
                VideoSegment(
                  video: clip,
                  startTime: const Duration(seconds: 1),
                  endTime: const Duration(milliseconds: 3500),
                  keyframes: incoming,
                ),
              ],
            ),
          );

      // Shrunk to half its size, the incoming clip leaves the corners black,
      // from the end of the blend on.
      final moved = await render(const [
        SegmentKeyframe(time: Duration.zero, scale: 0.5),
      ]);
      final still = await render(const []);

      const inBlend = Duration(milliseconds: 1900);
      const afterBlend = Duration(milliseconds: 2500);
      final movedInBlend = await cornerLuma(moved, inBlend);
      final stillInBlend = await cornerLuma(still, inBlend);
      // ignore: avoid_print
      print(
        'transition corners: in blend $movedInBlend vs $stillInBlend, '
        'after ${await cornerLuma(moved, afterBlend)}',
      );
      expect(movedInBlend, lessThan(max(stillInBlend * 0.5, 40)));
      expect(await cornerLuma(moved, afterBlend), lessThan(30));
      expect(await cornerLuma(still, afterBlend), greaterThan(40));
    });
  });
}
