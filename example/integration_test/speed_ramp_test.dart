import 'dart:typed_data';
import 'dart:ui' show Size, instantiateImageCodec;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final inputVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  // Fast run-up, then slow motion to the end: the two halves of the source
  // take very different shares of the output, so a renderer that maps output
  // time to source time any other way lands on visibly different frames.
  const ramp = VideoSpeedRamp([
    VideoSpeedRampPoint(position: 0, speed: 3),
    VideoSpeedRampPoint(position: 0.3, speed: 3),
    VideoSpeedRampPoint(position: 0.6, speed: 0.25),
    VideoSpeedRampPoint(position: 1, speed: 0.25),
  ]);
  // Starts after the file's beginning, so a renderer that times the ramp on
  // the file instead of the segment plays the wrong stretch of it.
  const start = Duration(seconds: 2);
  const source = Duration(seconds: 3);

  Future<Uint8List> render(VideoRenderData model) async {
    final result = await pve.renderVideo(model);
    expect(result.lengthInBytes, greaterThan(10000));
    return result;
  }

  VideoSegment rampedSegment({ClipTransition? transition}) => VideoSegment(
    video: inputVideo,
    startTime: start,
    endTime: start + source,
    speedRamp: ramp,
    transition: transition,
  );

  /// The frame [video] shows at [at], small and as raw RGBA.
  Future<ByteData> frameAt(EditorVideo video, Duration at) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: const Size(96, 54),
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    expect(frames, isNotEmpty, reason: 'no frame at $at');
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    return (await image.toByteData())!;
  }

  double meanDifference(ByteData a, ByteData b) {
    final length = a.lengthInBytes < b.lengthInBytes
        ? a.lengthInBytes
        : b.lengthInBytes;
    var sum = 0;
    for (var i = 0; i < length; i++) {
      if (i % 4 == 3) continue;
      sum += (a.getUint8(i) - b.getUint8(i)).abs();
    }
    return sum / (length * 3 / 4);
  }

  group('Speed ramp', () {
    testWidgets('plays for the time VideoSpeedRamp.outputDuration reports', (
      _,
    ) async {
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [rampedSegment()],
        ),
      );
      final meta = await pve.getMetadata(EditorVideo.memory(bytes));

      final expected = ramp.outputDuration(source);
      expect(
        meta.duration.inMilliseconds,
        closeTo(expected.inMilliseconds, 120),
        reason: 'the ramp plays 3 s of source in $expected',
      );
      // The clip's sound follows the ramp instead of ending early or late.
      expect(meta.audioDuration, isNotNull);
      expect(
        meta.audioDuration!.inMilliseconds,
        closeTo(expected.inMilliseconds, 150),
      );
    });

    testWidgets('a segment without an end plays the ramp to the end of the '
        'file', (_) async {
      // Only a start: the ramp runs from there to the end of the file, not
      // along the whole file.
      final fileDuration = (await pve.getMetadata(inputVideo)).duration;
      final from = fileDuration - source;
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(video: inputVideo, startTime: from, speedRamp: ramp),
          ],
        ),
      );
      final meta = await pve.getMetadata(EditorVideo.memory(bytes));

      final expected = ramp.outputDuration(fileDuration - from);
      expect(
        meta.duration.inMilliseconds,
        closeTo(expected.inMilliseconds, 200),
        reason: 'the ramp plays the last $source of the file in $expected',
      );
    });

    testWidgets("the clip's sound plays through without dropping out", (
      _,
    ) async {
      // Its sound never falls silent, so silence in the render is a dropout.
      // AVFoundation drops tens of milliseconds around every time-scaled
      // audio edit, and a ramp scales once per step.
      final steady = EditorVideo.asset('assets/tests/test_a.mp4');
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [VideoSegment(video: steady, speedRamp: ramp)],
        ),
      );
      final waveform = await pve.getWaveform(
        WaveformConfigs(
          video: EditorVideo.memory(bytes),
          resolution: WaveformResolution.high,
        ),
      );
      final peaks = waveform.leftChannel;
      expect(peaks.length, greaterThan(200));

      // The edges hold the encoder's priming and padding.
      var run = 0;
      var longest = 0;
      for (final peak in peaks.sublist(10, peaks.length - 10)) {
        run = peak < 0.001 ? run + 1 : 0;
        if (run > longest) longest = run;
      }
      final bucket = 1000 ~/ waveform.samplesPerSecond;
      expect(longest, lessThan(3), reason: 'silent for ${longest * bucket} ms');
    });

    testWidgets('shows the source frame outputToSource maps each moment to', (
      _,
    ) async {
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [rampedSegment()],
        ),
      );
      final rendered = EditorVideo.memory(bytes);
      final output = ramp.outputDuration(source);

      var checked = 0;
      for (final share in [0.15, 0.3, 0.5]) {
        final at = output * share;
        final mapped = start + ramp.outputToSource(at, sourceDuration: source);
        // Where a constant speed would have put the same moment.
        final linear = start + source * share;
        if ((mapped - linear).abs() < const Duration(milliseconds: 600)) {
          continue;
        }
        final frame = await frameAt(rendered, at);
        final toMapped = meanDifference(
          frame,
          await frameAt(inputVideo, mapped),
        );
        final toLinear = meanDifference(
          frame,
          await frameAt(inputVideo, linear),
        );
        expect(
          toMapped,
          lessThan(toLinear),
          reason:
              'at $at the render should show source $mapped, not $linear '
              '(difference $toMapped vs $toLinear)',
        );
        checked++;
      }
      expect(checked, greaterThan(0));
    });

    testWidgets('a dissolve takes its share of the ramp from the clip edge', (
      _,
    ) async {
      const overlap = Duration(milliseconds: 600);
      const next = Duration(seconds: 2);
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            rampedSegment(
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: overlap,
              ),
            ),
            VideoSegment(
              video: inputVideo,
              startTime: const Duration(seconds: 8),
              endTime: const Duration(seconds: 8) + next,
            ),
          ],
        ),
      );
      final meta = await pve.getMetadata(EditorVideo.memory(bytes));

      final expected = ramp.outputDuration(source) + next - overlap;
      expect(
        meta.duration.inMilliseconds,
        closeTo(expected.inMilliseconds, 200),
      );
    });

    testWidgets('a loop wrap on one ramped clip takes its fast head and its '
        'slow tail', (_) async {
      const overlap = Duration(milliseconds: 500);
      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            rampedSegment(
              transition: const ClipTransition(
                type: ClipTransitionType.dissolve,
                duration: overlap,
              ),
            ),
          ],
        ),
      );
      final meta = await pve.getMetadata(EditorVideo.memory(bytes));

      final expected = ramp.outputDuration(source) - overlap;
      expect(
        meta.duration.inMilliseconds,
        closeTo(expected.inMilliseconds, 200),
      );
    });

    testWidgets('the render end is measured after the ramp', (_) async {
      const end = Duration(seconds: 4);
      expect(ramp.outputDuration(source), greaterThan(end));

      final bytes = await render(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [rampedSegment()],
          endTime: end,
        ),
      );
      final meta = await pve.getMetadata(EditorVideo.memory(bytes));

      expect(meta.duration.inMilliseconds, closeTo(end.inMilliseconds, 120));
    });
  });
}
