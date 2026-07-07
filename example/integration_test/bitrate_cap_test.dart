import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';
import 'package:pro_video_editor_example/core/constants/example_filters.dart';

/// Verifies that `VideoQualityConfig.bitrate` is enforced as a real maximum:
/// sources above the cap are re-encoded down to it, while compliant sources
/// keep the lossless fast path (Android transmux / Darwin passthrough).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// ~1 Mbit/s H.264 720p — well below any cap used here.
  final lowBitrateVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// ~12.5 Mbit/s HEVC 1080p — well above the 8 Mbit/s cap.
  final highBitrateVideo = EditorVideo.asset(kVideoEditorExampleHevcPath);

  /// Short H.264 clip with a 5.1 surround audio track.
  final surroundVideo = EditorVideo.asset(kVideoEditorExampleSurround51Path);

  const cap = 8000000; // 8 Mbit/s
  const capTolerance = 1.2; // Must match the native BitrateCapPolicy.
  const maxAllowed = cap * capTolerance; // 9.6 Mbit/s

  final pve = ProVideoEditor.instance;

  testWidgets('no-edit export of over-cap source honors the cap', (_) async {
    final sourceMeta = await pve.getMetadata(highBitrateVideo);
    expect(
      sourceMeta.bitrate,
      greaterThan(maxAllowed),
      reason: 'Test precondition: source must exceed cap × tolerance',
    );

    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: highBitrateVideo)],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: cap,
      ),
    );

    final meta = await pve.getMetadata(EditorVideo.memory(result));
    expect(
      meta.bitrate,
      lessThanOrEqualTo(maxAllowed),
      reason:
          'Over-cap source must be re-encoded down to the cap '
          '(got ${meta.bitrate} bps)',
    );
    expect(
      meta.duration.inMilliseconds,
      closeTo(sourceMeta.duration.inMilliseconds, 500),
      reason: 'Re-encode must preserve duration',
    );
  });

  testWidgets('no-edit export of compliant source stays lossless', (_) async {
    final sourceBytes = await rootBundle.load(kVideoEditorExampleH264Path);
    final sourceMeta = await pve.getMetadata(lowBitrateVideo);
    expect(
      sourceMeta.bitrate,
      lessThan(maxAllowed),
      reason: 'Test precondition: source must be within cap × tolerance',
    );

    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: lowBitrateVideo)],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: cap,
      ),
    );

    // A lossless remux (Android transmux / Darwin passthrough) copies the
    // source samples verbatim, so the output stays ~the source size. A
    // re-encode at the 8 Mbit/s cap would blow the ~1 Mbit/s source up by
    // several multiples, so this catches a fast-path regression.
    expect(
      result.lengthInBytes,
      closeTo(sourceBytes.lengthInBytes, sourceBytes.lengthInBytes * 0.15),
      reason: 'Compliant source must be remuxed losslessly, not re-encoded',
    );

    final meta = await pve.getMetadata(EditorVideo.memory(result));
    expect(
      meta.duration.inMilliseconds,
      closeTo(sourceMeta.duration.inMilliseconds, 500),
    );
  });

  testWidgets('cap is honored together with a trim', (_) async {
    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: highBitrateVideo,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
          ),
        ],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: cap,
      ),
    );

    final meta = await pve.getMetadata(EditorVideo.memory(result));
    expect(meta.bitrate, lessThanOrEqualTo(maxAllowed));
    expect(meta.duration.inMilliseconds, closeTo(2000, 700));
  });

  testWidgets('compliant source with trim keeps duration accurate', (_) async {
    // A compliant source with a trim may stay on the fast path (Android
    // transmux); the trim must remain as accurate as a re-encoded one.
    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: lowBitrateVideo,
            startTime: const Duration(seconds: 7),
            endTime: const Duration(seconds: 20),
          ),
        ],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: cap,
      ),
    );

    final meta = await pve.getMetadata(EditorVideo.memory(result));
    expect(meta.duration.inMilliseconds, closeTo(13000, 300));
    expect(meta.bitrate, lessThanOrEqualTo(maxAllowed));
  });

  testWidgets('cap is honored together with effects', (_) async {
    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: highBitrateVideo)],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: cap,
        colorFilters: kBasicFilterMatrix,
        blur: 2,
      ),
    );

    expect(result.lengthInBytes, greaterThan(50000));
    final meta = await pve.getMetadata(EditorVideo.memory(result));
    expect(meta.bitrate, lessThanOrEqualTo(maxAllowed));
  });

  group('5.1 surround source', () {
    // A multichannel source must survive a bitrate-capped export on every
    // platform. On Darwin the capped AVAssetWriter path downmixes it to
    // stereo; a regression there previously risked a failed export.

    testWidgets('renders through the capped re-encode path (with effect)', (
      _,
    ) async {
      // A color filter defeats the passthrough/transmux fast path, so the
      // render always goes through the capped encoder (where the audio
      // downmix happens on Darwin).
      final result = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: surroundVideo)],
          outputFormat: VideoOutputFormat.mp4,
          bitrate: cap,
          colorFilters: kBasicFilterMatrix,
        ),
      );

      expect(result.lengthInBytes, greaterThan(20000));
      final meta = await pve.getMetadata(EditorVideo.memory(result));
      expect(
        meta.audioDuration,
        isNotNull,
        reason: 'Audio must survive the downmix/re-encode',
      );
      expect(meta.duration.inMilliseconds, closeTo(2000, 400));
      expect(meta.bitrate, lessThanOrEqualTo(maxAllowed));
    });

    testWidgets('renders on the no-edit fast path', (_) async {
      // No edits + a low-bitrate source: Darwin passthrough / Android
      // transmux. The 5.1 audio must not break the fast path either.
      final result = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: surroundVideo)],
          outputFormat: VideoOutputFormat.mp4,
          bitrate: cap,
        ),
      );

      expect(result.lengthInBytes, greaterThan(20000));
      final meta = await pve.getMetadata(EditorVideo.memory(result));
      expect(meta.audioDuration, isNotNull);
      expect(meta.duration.inMilliseconds, closeTo(2000, 400));
    });
  });

  testWidgets('null bitrate keeps previous behavior', (_) async {
    final result = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: lowBitrateVideo)],
        outputFormat: VideoOutputFormat.mp4,
      ),
    );

    expect(result, isNotNull);
    expect(result.lengthInBytes, greaterThan(100000));
  });

  testWidgets('capped render reports progress and completes', (_) async {
    final progressValues = <double>[];
    final task = VideoRenderData(
      videoSegments: [VideoSegment(video: highBitrateVideo)],
      outputFormat: VideoOutputFormat.mp4,
      bitrate: cap,
    );
    final sub = task.progressStream.listen((p) {
      progressValues.add(p.progress);
    });

    final result = await pve.renderVideo(task);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    expect(result.lengthInBytes, greaterThan(50000));
    expect(progressValues, isNotEmpty);
    expect(progressValues.last, 1.0);
    expect(
      List.of(progressValues)..sort(),
      progressValues,
      reason: 'Progress should be monotonically increasing',
    );
  }, skip: kIsWeb);
}
