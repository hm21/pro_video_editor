import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// 2 s at 30 fps, every frame a flat gray that alternates between dark and
/// bright, so a blended frame shows as a gray in between.
const _flash = 'assets/tests/flash_30fps.mp4';

/// 1 s at 30 fps, flat and darker than the flash clip's dark frames.
const _dark = 'assets/tests/dark_30fps.mp4';

/// `VideoSegment.frameBlending`: a slowed-down segment shows mixes of its
/// neighbouring source frames instead of holding each one.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final flash = EditorVideo.asset(_flash);
  const source = Duration(seconds: 1);

  Future<List<LumaFrame>> renderFrames(List<VideoSegment> segments) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        outputFormat: VideoOutputFormat.mp4,
        videoSegments: segments,
      ),
    );
    expect(bytes.lengthInBytes, greaterThan(1000));
    return pve
        .getLumaFrameStream(
          LumaFrameConfigs(
            video: EditorVideo.memory(bytes),
            outputSize: const Size(32, 32),
          ),
        )
        .toList();
  }

  double mean(Uint8List bytes, int width, int height, {int? from, int? to}) {
    var sum = 0;
    var count = 0;
    for (var y = 0; y < height; y++) {
      for (var x = from ?? 0; x < (to ?? width); x++) {
        sum += bytes[y * width + x];
        count++;
      }
    }
    return sum / count;
  }

  /// Each frame's brightness between the flash clip's dark (0) and bright
  /// (1) frames.
  List<double> levels(List<double> means) {
    final low = means.reduce((a, b) => a < b ? a : b);
    final high = means.reduce((a, b) => a > b ? a : b);
    return [for (final m in means) (m - low) / (high - low)];
  }

  List<double> frameLevels(List<LumaFrame> frames) =>
      levels([for (final f in frames) mean(f.bytes, f.width, f.height)]);

  int near(List<double> levels, double level) =>
      levels.where((l) => (l - level).abs() < 0.1).length;

  /// Frames clearly between the dark and the bright frame.
  int mixed(List<double> levels) =>
      levels.where((l) => l > 0.15 && l < 0.85).length;

  VideoSegment flashSegment({
    double? speed,
    VideoSpeedRamp? ramp,
    bool blend = true,
    ClipTransition? transition,
  }) => VideoSegment(
    video: flash,
    startTime: const Duration(milliseconds: 300),
    endTime: const Duration(milliseconds: 300) + source,
    playbackSpeed: speed,
    speedRamp: ramp,
    frameBlending: blend,
    transition: transition,
  );

  group('Frame blending', () {
    testWidgets('at 0.5x puts a half mix between every two source frames', (
      _,
    ) async {
      final frames = await renderFrames([flashSegment(speed: 0.5)]);
      final l = frameLevels(frames);

      // Twice the source frames, at the source's frame rate.
      expect(frames.length, inInclusiveRange(58, 61));
      expect(near(l, 0.5), inInclusiveRange(27, 31), reason: '$l');
      expect(near(l, 0) + near(l, 1), inInclusiveRange(28, 31));
    });

    testWidgets('at 0.5x without it holds every source frame', (_) async {
      final l = frameLevels(
        await renderFrames([flashSegment(speed: 0.5, blend: false)]),
      );

      expect(mixed(l), 0, reason: '$l');
    });

    testWidgets('at 0.25x mixes in quarter steps', (_) async {
      final frames = await renderFrames([flashSegment(speed: 0.25)]);
      final l = frameLevels(frames);

      expect(frames.length, inInclusiveRange(116, 121));
      expect(near(l, 0.25), inInclusiveRange(26, 31), reason: '$l');
      expect(near(l, 0.5), inInclusiveRange(26, 31), reason: '$l');
      expect(near(l, 0.75), inInclusiveRange(26, 31), reason: '$l');
    });

    testWidgets('leaves a segment at its own speed as it is', (_) async {
      final frames = await renderFrames([flashSegment()]);
      final l = frameLevels(frames);

      expect(frames.length, inInclusiveRange(29, 31));
      expect(near(l, 0) + near(l, 1), frames.length, reason: '$l');
    });

    testWidgets('blends only the slowed-down stretch of a speed ramp', (
      _,
    ) async {
      final frames = await renderFrames([
        flashSegment(
          ramp: const VideoSpeedRamp([
            VideoSpeedRampPoint(position: 0, speed: 2),
            VideoSpeedRampPoint(position: 0.45, speed: 2),
            VideoSpeedRampPoint(position: 0.55, speed: 0.5),
            VideoSpeedRampPoint(position: 1, speed: 0.5),
          ]),
        ),
      ]);
      final l = frameLevels(frames);
      final fast = l.take(6).toList();
      final slow = l.skip(l.length - 20).toList();

      expect(mixed(fast), 0, reason: 'sped up: $fast');
      expect(near(slow, 0.5), inInclusiveRange(8, 11), reason: 'slowed: $slow');
    });

    testWidgets('blends a slowed-down side of an overlap transition', (
      _,
    ) async {
      // A wipe from the flash clip into a darker clip: the edge it reveals
      // last keeps showing the flash clip's tail through the first half.
      const wipe = ClipTransition(
        type: ClipTransitionType.wipe,
        duration: Duration(milliseconds: 600),
      );
      Future<List<double>> tailLevels({required bool blend}) async {
        final frames = await renderFrames([
          flashSegment(speed: 0.5, blend: blend, transition: wipe),
          VideoSegment(video: EditorVideo.asset(_dark)),
        ]);
        // The wipe starts 600 ms before the flash clip's 2 s end.
        final transition = frames.where((f) {
          final ms = f.time.inMilliseconds;
          return ms >= 1400 && ms < 1650;
        });
        final edges = [
          for (final f in transition)
            [
              mean(f.bytes, f.width, f.height, to: 4),
              mean(f.bytes, f.width, f.height, from: f.width - 4),
            ].reduce((a, b) => a > b ? a : b),
        ];
        // The flash clip's own extremes, from before the transition.
        final before = [
          for (final f in frames.take(30)) mean(f.bytes, f.width, f.height),
        ];
        final low = before.reduce((a, b) => a < b ? a : b);
        final high = before.reduce((a, b) => a > b ? a : b);
        return [for (final e in edges) (e - low) / (high - low)];
      }

      final blended = await tailLevels(blend: true);
      final held = await tailLevels(blend: false);

      // The tail plays at 0.5x, so about every second frame lies between
      // two source frames, by a share that varies across the blend.
      expect(blended.length, greaterThanOrEqualTo(6));
      expect(mixed(blended), greaterThanOrEqualTo(2), reason: '$blended');
      expect(mixed(held), 0, reason: '$held');
    });
  });
}
