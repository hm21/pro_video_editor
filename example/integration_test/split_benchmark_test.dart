// Uses print() instead of debugPrint(): on Android, debugPrint rate-throttles
// and silently drops lines, which would swallow the BENCH output this benchmark
// exists to read.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Measures and compares how long [ProVideoEditor.splitVideo] takes.
///
/// Every split re-encodes both halves (see [SplitVideoModel]), so the wall
/// clock is dominated by encode cost. This benchmark isolates that cost along
/// four axes so their impact can be compared side by side:
///
///   1. codec / resolution — H264 720p vs HEVC 1080p vs 4K60
///   2. audio on vs off     — the overhead of carrying the audio track
///   3. split position      — cut near start vs middle vs end (mid-asset
///      re-encode from a non-keyframe start is the #166 suspect)
///   4. bitrate / quality   — default vs explicit bitrate vs quality preset
///
/// Each split prints a `BENCH[split:<label>] runN: <ms> ms` line, and each
/// group prints a `BENCH-COMPARE[<group>]` table sorted fastest-first with a
/// relative factor, so the comparison is readable in one place.
///
/// Run with:
/// `flutter test integration_test/split_benchmark_test.dart -d <device>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  /// Splitting is implemented on Android, iOS, and macOS only.
  final skipPlatform = kIsWeb || isWindows || isLinux;

  Future<String> tempPath(String suffix) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/splitbench_${stamp}_$suffix.mp4';
  }

  Future<void> cleanUp(List<String> paths) async {
    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  /// Splits [video] at [splitPosition] [runs] times, prints one `BENCH` line
  /// per run and returns the best (minimum) elapsed time. Outputs are deleted
  /// after every run so disk pressure never skews the next measurement.
  Future<Duration> benchSplit({
    required String label,
    required EditorVideo video,
    required Duration splitPosition,
    bool enableAudio = true,
    int? bitrate,
    VideoQualityConfig? qualityConfig,
    int runs = 2,
  }) async {
    var best = const Duration(days: 1);
    for (var run = 1; run <= runs; run++) {
      final startPath = await tempPath('${label}_${run}_start');
      final endPath = await tempPath('${label}_${run}_end');

      final sw = Stopwatch()..start();
      final paths = await pve.splitVideo(
        SplitVideoModel(
          video: video,
          splitPosition: splitPosition,
          startOutputPath: startPath,
          endOutputPath: endPath,
          enableAudio: enableAudio,
          bitrate: bitrate,
          qualityConfig: qualityConfig,
        ),
      );
      sw.stop();

      expect(paths.length, 2);
      expect(await File(paths[0]).exists(), isTrue);
      expect(await File(paths[1]).exists(), isTrue);

      if (sw.elapsed < best) best = sw.elapsed;
      print('BENCH[split:$label] run$run: ${sw.elapsedMilliseconds} ms');

      await cleanUp([startPath, endPath]);
    }
    return best;
  }

  /// Prints a fastest-first comparison table with a relative slowdown factor.
  void printComparison(String group, Map<String, Duration> results) {
    final entries = results.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final fastestMs = entries.first.value.inMilliseconds;

    final buffer = StringBuffer('BENCH-COMPARE[$group] (best run each)\n');
    for (final e in entries) {
      final ms = e.value.inMilliseconds;
      final rel = fastestMs == 0 ? 1.0 : ms / fastestMs;
      buffer.writeln(
        '  ${e.key.padRight(18)}'
        '${ms.toString().padLeft(7)} ms'
        '  (${rel.toStringAsFixed(2)}x)',
      );
    }
    print(buffer.toString());
  }

  // 1) Codec / resolution: how much re-encode cost depends on the source.
  //    4K60 is expensive, so a single measured run keeps the total bounded.
  testWidgets(
    'split benchmark: codec / resolution',
    (tester) async {
      const clips = [
        (label: 'h264-720p', path: kVideoEditorExampleH264Path),
        (label: 'hevc-1080p', path: kVideoEditorExampleHevcPath),
        (label: '4k60', path: 'assets/tests/test_4k_a.mp4'),
      ];

      final results = <String, Duration>{};
      for (final clip in clips) {
        final video = EditorVideo.asset(clip.path);
        final meta = await pve.getMetadata(video);
        results[clip.label] = await benchSplit(
          label: clip.label,
          video: video,
          splitPosition: meta.duration ~/ 2,
          runs: 1,
        );
      }

      printComparison('codec/resolution', results);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipPlatform,
  );

  // 2) Audio on vs off: the overhead of carrying the source audio track.
  testWidgets(
    'split benchmark: audio on vs off',
    (tester) async {
      final video = EditorVideo.asset(kVideoEditorExampleH264Path);
      final meta = await pve.getMetadata(video);
      final mid = meta.duration ~/ 2;

      final results = <String, Duration>{
        'audio-on': await benchSplit(
          label: 'audio-on',
          video: video,
          splitPosition: mid,
        ),
        'audio-off': await benchSplit(
          label: 'audio-off',
          video: video,
          splitPosition: mid,
          enableAudio: false,
        ),
      };

      printComparison('audio on/off', results);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipPlatform,
  );

  // 3) Split position: a mid-asset cut re-encodes from a non-keyframe start,
  //    which the #166 investigation flagged as the slow/stall-prone case.
  testWidgets(
    'split benchmark: split position',
    (tester) async {
      final video = EditorVideo.asset(kVideoEditorExampleH264Path);
      final meta = await pve.getMetadata(video);
      final total = meta.duration;

      final positions = <String, Duration>{
        'pos-10pct': total * 0.1,
        'pos-50pct': total * 0.5,
        'pos-90pct': total * 0.9,
      };

      final results = <String, Duration>{};
      for (final entry in positions.entries) {
        results[entry.key] = await benchSplit(
          label: entry.key,
          video: video,
          splitPosition: entry.value,
        );
      }

      printComparison('split position', results);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipPlatform,
  );

  // 4) Bitrate / quality: encode cost per target quality.
  //    NOTE macOS/iOS: an exact bitrate cannot be set; the closest export
  //    preset is chosen, so the absolute numbers there reflect the preset, not
  //    the requested bits — the relative ordering is still meaningful.
  testWidgets(
    'split benchmark: bitrate / quality',
    (tester) async {
      final video = EditorVideo.asset(kVideoEditorExampleH264Path);
      final meta = await pve.getMetadata(video);
      final mid = meta.duration ~/ 2;

      final results = <String, Duration>{
        'default': await benchSplit(
          label: 'q-default',
          video: video,
          splitPosition: mid,
        ),
        'bitrate-1mbps': await benchSplit(
          label: 'q-1mbps',
          video: video,
          splitPosition: mid,
          bitrate: 1000000,
        ),
        'bitrate-8mbps': await benchSplit(
          label: 'q-8mbps',
          video: video,
          splitPosition: mid,
          bitrate: 8000000,
        ),
        'preset-low': await benchSplit(
          label: 'q-preset-low',
          video: video,
          splitPosition: mid,
          qualityConfig: VideoQualityConfig.fromPreset(VideoQualityPreset.low),
        ),
      };

      printComparison('bitrate/quality', results);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipPlatform,
  );
}
