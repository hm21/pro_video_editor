import 'dart:collection';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Timeline-strip extraction: batched `getThumbnails` versus one
/// `getThumbnailStream` per clip.
///
/// The batched shape is the one a timeline caller ends up with when the only
/// API is a whole-set call: it wants progressive fill, so it asks for a few
/// timestamps at a time — six here, centre-first so early batches span the
/// clip — and runs the calls back to back. Every batch is a separate native
/// decode pass from its first target's keyframe, so the source is decoded
/// once *per batch*. The stream asks for everything at once and decodes it
/// once.
///
/// Three moments are timed per run, all as seen by a Dart consumer:
///   * `first`  — the first frame is available;
///   * `usable` — every one-second slot of the window has a frame, i.e. the
///     strip is fully populated at a typical default zoom;
///   * `total`  — the last frame is available.
///
/// Run on a device:
/// ```
/// flutter test integration_test/thumbnail_stream_benchmark_test.dart -d <id>
/// ```
/// and read the `[bench]` lines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  // A timeline strip at 48x54 logical pixels on a 3.5x display.
  const outputSize = Size(168, 189);
  // Enough frames for a distinct one per slot at the strip's maximum zoom.
  const thumbsPerSecond = 13;
  const batchSize = 6;
  const maxFrames = 500;

  final clips = <_Clip>[
    const _Clip(
      'divine 720p30 5.7s',
      kVideoEditorExampleDivinePath,
      Duration(milliseconds: 5665),
    ),
    const _Clip(
      '1080p30 5s 1 keyframe',
      'assets/tests/test_a.mp4',
      Duration(seconds: 5),
    ),
    const _Clip(
      '720p25 6.3s of 29.5s',
      kVideoEditorExampleH264Path,
      Duration(milliseconds: 6300),
    ),
    const _Clip(
      '720p25 29.5s',
      kVideoEditorExampleH264Path,
      Duration(milliseconds: 29568),
      repeats: 1,
    ),
    const _Clip(
      '4k60 6.3s of 31.7s',
      'assets/tests/test_4k_a.mp4',
      Duration(milliseconds: 6300),
      repeats: 1,
    ),
  ];

  group('timeline strip extraction', () {
    for (final clip in clips) {
      // The batched shape alone takes ~25 s for the 29.5 s clip on a 2024
      // flagship; the default 30 s budget is for the stream's world.
      test(clip.name, timeout: const Timeout(Duration(minutes: 5)), () async {
        final video = EditorVideo.asset(clip.asset);
        // Resolve the asset to a file once so neither mode pays for the copy.
        await video.safeFilePath();
        final durationMs = clip.window.inMilliseconds;
        final count = ((durationMs / 1000) * thumbsPerSecond).ceil().clamp(
          1,
          maxFrames,
        );
        final slots = [
          for (var ms = 500; ms < durationMs; ms += 1000)
            Duration(milliseconds: ms),
        ];
        final timestamps = _stripTimestamps(
          durationMs: durationMs,
          count: count,
          priority: slots,
        );
        final buckets = _SlotBuckets(durationMs);

        final rows = <String>[];
        for (var repeat = 0; repeat < clip.repeats; repeat++) {
          final batched = await _timeBatched(
            pve,
            video,
            timestamps,
            outputSize: outputSize,
            batchSize: batchSize,
            buckets: buckets,
          );
          final stream = await _timeStream(
            pve,
            video,
            timestamps,
            outputSize: outputSize,
            buckets: buckets,
            label: 'stream',
          );
          final streamSingle = await _timeStream(
            pve,
            video,
            timestamps,
            outputSize: outputSize,
            buckets: buckets,
            maxParallelDecoders: 1,
            label: 'stream x1',
          );
          rows.addAll([batched, stream, streamSingle]);
        }

        // ignore: avoid_print
        print('[bench] ${clip.name}: ${timestamps.length} frames');
        for (final row in rows) {
          // ignore: avoid_print
          print('[bench]   $row');
        }
        expect(rows, isNotEmpty);
      });
    }
  });
}

class _Clip {
  const _Clip(this.name, this.asset, this.window, {this.repeats = 2});

  final String name;
  final String asset;
  final Duration window;
  final int repeats;
}

/// Tracks which one-second slots of the window have a frame yet.
class _SlotBuckets {
  _SlotBuckets(this.durationMs);

  final int durationMs;

  int get slotCount => (durationMs / 1000).ceil();

  int slotOf(Duration timestamp) =>
      (timestamp.inMilliseconds ~/ 1000).clamp(0, slotCount - 1);
}

/// The batched shape: `batchSize` timestamps per `getThumbnails` call, one
/// call after another.
Future<String> _timeBatched(
  ProVideoEditor pve,
  EditorVideo video,
  List<Duration> timestamps, {
  required Size outputSize,
  required int batchSize,
  required _SlotBuckets buckets,
}) async {
  final watch = Stopwatch()..start();
  int? firstMs;
  int? usableMs;
  final filled = <int>{};
  var delivered = 0;
  var calls = 0;

  for (var start = 0; start < timestamps.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, timestamps.length);
    final batch = timestamps.sublist(start, end);
    final bytes = await pve.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputSize: outputSize,
        timestamps: batch,
        jpegQuality: 75,
      ),
    );
    calls++;
    delivered += bytes.length;
    firstMs ??= watch.elapsedMilliseconds;
    for (final timestamp in batch) {
      filled.add(buckets.slotOf(timestamp));
    }
    if (usableMs == null && filled.length >= buckets.slotCount) {
      usableMs = watch.elapsedMilliseconds;
    }
  }
  watch.stop();
  return _row(
    'batched x$batchSize',
    first: firstMs,
    usable: usableMs,
    total: watch.elapsedMilliseconds,
    frames: delivered,
    extra: '$calls native calls',
  );
}

/// One `getThumbnailStream` for the whole request.
Future<String> _timeStream(
  ProVideoEditor pve,
  EditorVideo video,
  List<Duration> timestamps, {
  required Size outputSize,
  required _SlotBuckets buckets,
  required String label,
  int? maxParallelDecoders,
}) async {
  final watch = Stopwatch()..start();
  int? firstMs;
  int? usableMs;
  final filled = <int>{};
  var delivered = 0;

  await for (final frame in pve.getThumbnailStream(
    ThumbnailConfigs(
      video: video,
      outputSize: outputSize,
      timestamps: timestamps,
      jpegQuality: 75,
      maxParallelDecoders: maxParallelDecoders,
    ),
  )) {
    firstMs ??= watch.elapsedMilliseconds;
    delivered += frame.indices.length;
    for (final index in frame.indices) {
      filled.add(buckets.slotOf(timestamps[index]));
    }
    if (usableMs == null && filled.length >= buckets.slotCount) {
      usableMs = watch.elapsedMilliseconds;
    }
  }
  watch.stop();
  return _row(
    label,
    first: firstMs,
    usable: usableMs,
    total: watch.elapsedMilliseconds,
    frames: delivered,
    extra: '1 native call',
  );
}

String _row(
  String label, {
  required int? first,
  required int? usable,
  required int total,
  required int frames,
  required String extra,
}) {
  String ms(int? value) =>
      value == null ? '   n/a' : '${value.toString().padLeft(5)}ms';
  return '${label.padRight(11)} first ${ms(first)}  usable ${ms(usable)}  '
      'total ${ms(total)}  frames $frames  ($extra)';
}

/// The timeline's request order: the priority slots first, then a
/// centre-first midpoint refinement over the window so early frames cover
/// the whole clip.
List<Duration> _stripTimestamps({
  required int durationMs,
  required int count,
  required List<Duration> priority,
}) {
  final seenMs = <int>{};
  final result = <Duration>[];
  for (final timestamp in priority) {
    if (seenMs.add(timestamp.inMilliseconds)) result.add(timestamp);
  }

  final minMs = durationMs > 1 ? 1 : 0;
  final maxMs = durationMs > 1 ? durationMs - 1 : durationMs;
  final segments = Queue<(double, double)>()..add((0, durationMs.toDouble()));
  final density = <Duration>[];
  final densitySeen = <int>{};
  while (segments.isNotEmpty && density.length < count) {
    final (start, end) = segments.removeFirst();
    final width = end - start;
    if (width <= 0) continue;
    final midMs = ((start + end) / 2).round().clamp(minMs, maxMs);
    if (densitySeen.add(midMs)) density.add(Duration(milliseconds: midMs));
    if (width > 1) {
      final mid = midMs.toDouble();
      segments
        ..add((start, mid))
        ..add((mid, end));
    }
  }
  for (final timestamp in density) {
    if (seenMs.add(timestamp.inMilliseconds)) result.add(timestamp);
  }
  return result;
}
