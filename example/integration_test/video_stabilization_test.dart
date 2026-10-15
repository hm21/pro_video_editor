import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/core/analysis/frame_motion_estimator.dart';
import 'package:pro_video_editor/core/analysis/similarity_transform.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// A 540x960 clip with synthetic handheld shake: 2–9 Hz jitter of about
/// 1.2 % of the width and 0.6° on top of a slow pan.
const _shaky = 'assets/tests/test_shaky.mp4';

/// End to end: analyze a shaky clip, render it with the result, and measure
/// the rendered video again. A keyframe applied to the wrong frame — off by
/// one, mirrored, turned the wrong way — makes the result shakier, not
/// steadier, so this checks the time mapping and the conventions on each
/// platform.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  const box = ui.Size(320, 320);

  /// RMS frame-to-frame acceleration of the picture, as a share of its
  /// width, over [range] of [video].
  Future<double> jitter(
    EditorVideo video, {
    Duration? startTime,
    Duration? endTime,
  }) async {
    FrameMotionEstimator? estimator;
    var width = 1;
    final path = <SimilarityTransform>[SimilarityTransform.identity];
    await for (final frame in pve.getLumaFrameStream(
      LumaFrameConfigs(
        video: video,
        outputSize: box,
        startTime: startTime,
        endTime: endTime,
      ),
    )) {
      width = frame.width;
      estimator ??= FrameMotionEstimator(
        width: frame.width,
        height: frame.height,
      );
      final motion = estimator.addFrame(frame.bytes);
      if (motion == null) continue;
      path.add(
        path.last.then(motion.transform ?? SimilarityTransform.identity),
      );
    }
    var sum = 0.0;
    for (var t = 1; t < path.length - 1; t++) {
      final ax = path[t + 1].tx - 2 * path[t].tx + path[t - 1].tx;
      final ay = path[t + 1].ty - 2 * path[t].ty + path[t - 1].ty;
      sum += ax * ax + ay * ay;
    }
    return sqrt(sum / (path.length - 2)) / width;
  }

  group('VideoSegment.stabilization', () {
    late VideoStabilization stabilization;
    final shaky = EditorVideo.asset(_shaky);

    setUpAll(() async {
      final progress = <double>[];
      stabilization = await VideoStabilizationAnalyzer.analyzeVideo(
        shaky,
        onProgress: progress.add,
      );
      expect(stabilization.keyframes, hasLength(90));
      expect(progress.last, closeTo(1, 1e-3));
    });

    testWidgets('steadies the rendered video', (_) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: shaky, stabilization: stabilization),
          ],
        ),
      );

      final before = await jitter(shaky);
      final after = await jitter(EditorVideo.memory(bytes));
      // ignore: avoid_print
      print(
        'stabilization render: jitter ${(before * 100).toStringAsFixed(3)} % '
        '-> ${(after * 100).toStringAsFixed(3)} %, '
        'zoom ${stabilization.zoom.toStringAsFixed(3)}',
      );
      expect(after, lessThan(before * 0.25));
    });

    testWidgets('interpolates the frames a frame rate cap skipped', (_) async {
      // Every second frame is analyzed, so every gap between two keyframes
      // is the same; the frame in each one still needs its own correction.
      // 15 fps cannot follow the clip's fastest shake, so the render only
      // gets a little steadier. Holding the previous keyframe over the
      // skipped frame instead made it shakier than the source (1.69 % ->
      // 1.93 %).
      final capped = await VideoStabilizationAnalyzer.analyzeVideo(
        shaky,
        maxFrameRate: 15,
      );
      expect(capped.keyframes, hasLength(45));
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: shaky, stabilization: capped)],
        ),
      );

      final before = await jitter(shaky);
      final after = await jitter(EditorVideo.memory(bytes));
      // ignore: avoid_print
      print(
        'capped stabilization render: jitter '
        '${(before * 100).toStringAsFixed(3)} % -> '
        '${(after * 100).toStringAsFixed(3)} %',
      );
      expect(after, lessThan(before * 0.97));
    });

    testWidgets('stops the analysis when cancelled', (_) async {
      const id = 'stabilization-cancel';
      final analysis = VideoStabilizationAnalyzer.analyzeVideo(
        shaky,
        id: id,
        onProgress: (_) => unawaited(pve.cancel(id)),
      );
      await expectLater(analysis, throwsA(isA<RenderCanceledException>()));
    });

    testWidgets('keeps each keyframe on its frame in a trimmed clip', (
      _,
    ) async {
      // Starts between two frames, so the first frame shown is not the first
      // one of the file.
      const start = Duration(milliseconds: 515);
      const end = Duration(milliseconds: 2500);
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: shaky,
              startTime: start,
              endTime: end,
              stabilization: stabilization,
            ),
          ],
        ),
      );

      final before = await jitter(shaky, startTime: start, endTime: end);
      final after = await jitter(EditorVideo.memory(bytes));
      // ignore: avoid_print
      print(
        'trimmed stabilization render: jitter '
        '${(before * 100).toStringAsFixed(3)} % -> '
        '${(after * 100).toStringAsFixed(3)} %',
      );
      expect(after, lessThan(before * 0.25));
    });
  });
}
