import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Measures how long timestamp-based (timeline) thumbnail extraction takes.
///
/// Run with:
/// `flutter test integration_test/thumbnail_benchmark_test.dart -d <device>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> runBenchmark({
    required String label,
    required EditorVideo video,
    required int count,
  }) async {
    final meta = await ProVideoEditor.instance.getMetadata(video);
    final durationUs = meta.duration.inMicroseconds;

    /// Evenly spread positions across the video, centered in each slot,
    /// mirroring how a timeline requests its thumbnails.
    final timestamps = List.generate(
      count,
      (i) => Duration(microseconds: durationUs * (2 * i + 1) ~/ (2 * count)),
    );

    for (var run = 1; run <= 2; run++) {
      final sw = Stopwatch()..start();
      final thumbs = await ProVideoEditor.instance.getThumbnails(
        ThumbnailConfigs(
          video: video,
          outputFormat: ThumbnailFormat.jpeg,
          timestamps: timestamps,
          outputSize: const Size(160, 90),
          boxFit: ThumbnailBoxFit.cover,
        ),
      );
      sw.stop();

      debugPrint(
        'BENCH[$label] run$run: ${sw.elapsedMilliseconds} ms '
        'for ${thumbs.length}/$count thumbnails '
        '(${(sw.elapsedMilliseconds / count).toStringAsFixed(1)} ms/thumb)',
      );
      expect(thumbs.length, count);
    }
  }

  testWidgets('timeline benchmark 4k60 h264 32s', (tester) async {
    await runBenchmark(
      label: '4k60-32s',
      video: EditorVideo.asset('assets/tests/test_4k_a.mp4'),
      count: 20,
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('example page scenario h264 8 thumbs', (tester) async {
    final video = EditorVideo.asset(kVideoEditorExampleH264Path);
    final meta = await ProVideoEditor.instance.getMetadata(video);
    final timestamps = List.generate(
      8,
      (i) => Duration(
        milliseconds: (meta.duration.inMilliseconds / 8 * i).toInt(),
      ),
    );

    for (var run = 1; run <= 2; run++) {
      final sw = Stopwatch()..start();
      final thumbs = await ProVideoEditor.instance.getThumbnails(
        ThumbnailConfigs(
          video: video,
          outputFormat: ThumbnailFormat.jpeg,
          timestamps: timestamps,
          outputSize: const Size(170, 170),
          boxFit: ThumbnailBoxFit.cover,
        ),
      );
      sw.stop();
      debugPrint(
        'BENCH[example-8] run$run: ${sw.elapsedMilliseconds} ms '
        'for ${thumbs.length}/8 thumbnails',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('timeline benchmark h264 720p 29s', (tester) async {
    await runBenchmark(
      label: 'h264-720p-29s',
      video: EditorVideo.asset(kVideoEditorExampleH264Path),
      count: 20,
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('timeline benchmark hevc10bit 1080p 5s', (tester) async {
    await runBenchmark(
      label: 'hevc-1080p-5s',
      video: EditorVideo.asset(kVideoEditorExampleHevcPath),
      count: 10,
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}
