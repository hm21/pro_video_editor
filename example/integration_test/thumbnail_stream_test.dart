import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// On-device behaviour of `getThumbnailStream`: every requested timestamp is
/// delivered exactly once, a cancelled subscription stops the native decoder,
/// and concurrent streams do not tear each other down.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final clip = EditorVideo.asset(kVideoEditorExampleDivinePath);
  const outputSize = Size(168, 189);

  // Starts at 100 ms: with zero tolerance AVFoundation cannot always produce
  // the frame at t=0 (the first sample's presentation time is often not
  // exactly zero), which both APIs report as "no frame" and is not what these
  // tests are about.
  List<Duration> everyTenthOfASecond(Duration length) => [
    for (var ms = 100; ms < length.inMilliseconds; ms += 100)
      Duration(milliseconds: ms),
  ];

  group('getThumbnailStream', () {
    test('delivers every timestamp exactly once', () async {
      final timestamps = everyTenthOfASecond(const Duration(seconds: 5));
      final configs = ThumbnailConfigs(
        video: clip,
        outputSize: outputSize,
        timestamps: timestamps,
      );

      final seen = <int, int>{};
      var lastProgress = 0.0;
      await for (final frame in pve.getThumbnailStream(configs)) {
        expect(frame.bytes, isNotEmpty);
        expect(frame.indices, isNotEmpty);
        for (final index in frame.indices) {
          seen[index] = (seen[index] ?? 0) + 1;
        }
        expect(frame.progress, greaterThanOrEqualTo(lastProgress));
        lastProgress = frame.progress;
      }

      expect(
        seen.keys,
        unorderedEquals(List.generate(timestamps.length, (i) => i)),
      );
      expect(seen.values.every((count) => count == 1), isTrue);
      expect(lastProgress, 1.0);
    });

    test(
      'matches the frames getThumbnails returns for the same request',
      () async {
        final timestamps = everyTenthOfASecond(const Duration(seconds: 2));
        final configs = ThumbnailConfigs(
          video: clip,
          outputSize: outputSize,
          timestamps: timestamps,
        );

        final batch = await pve.getThumbnails(configs);
        final streamed = List<Uint8List?>.filled(timestamps.length, null);
        await for (final frame in pve.getThumbnailStream(configs)) {
          for (final index in frame.indices) {
            streamed[index] = frame.bytes;
          }
        }

        // getThumbnails is positional on Darwin (an undecodable frame is an
        // empty entry) and compacted on Android; the stream skips such a
        // frame. So compare the frames both delivered, and require that to be
        // all of them for a clip whose every frame decodes.
        final batchFrames = batch.where((b) => b.isNotEmpty).toList();
        final streamedFrames = streamed.whereType<Uint8List>().toList();
        expect(streamedFrames, hasLength(batchFrames.length));
        if (batch.length == timestamps.length) {
          for (var i = 0; i < timestamps.length; i++) {
            if (batch[i].isEmpty) continue;
            expect(streamed[i], batch[i], reason: 'frame $i differs');
          }
        }
        expect(streamedFrames, hasLength(timestamps.length));
      },
    );

    test('cancelling the subscription stops the stream', () async {
      final timestamps = everyTenthOfASecond(const Duration(seconds: 5));
      final configs = ThumbnailConfigs(
        video: clip,
        outputSize: outputSize,
        timestamps: timestamps,
      );

      final firstFrame = Completer<void>();
      var delivered = 0;
      final subscription = pve.getThumbnailStream(configs).listen((frame) {
        delivered++;
        if (!firstFrame.isCompleted) firstFrame.complete();
      });
      await firstFrame.future;
      await subscription.cancel();
      final deliveredAtCancel = delivered;

      // A stopped decoder delivers nothing more; a still-running one would
      // have decoded the rest of the clip in this window.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(delivered, deliveredAtCancel);
      expect(delivered, lessThan(timestamps.length));
    });

    test('cancel() surfaces RenderCanceledException on the stream', () async {
      final timestamps = everyTenthOfASecond(const Duration(seconds: 5));
      final configs = ThumbnailConfigs(
        video: clip,
        outputSize: outputSize,
        timestamps: timestamps,
      );

      final firstFrame = Completer<void>();
      final errors = <Object>[];
      final done = Completer<void>();
      pve
          .getThumbnailStream(configs)
          .listen(
            (_) {
              if (!firstFrame.isCompleted) firstFrame.complete();
            },
            onError: errors.add,
            onDone: done.complete,
          );
      await firstFrame.future;
      await pve.cancel(configs.id);
      await done.future.timeout(const Duration(seconds: 10));

      expect(errors, [isA<RenderCanceledException>()]);
    });

    test('two concurrent streams both complete', () async {
      final timestamps = everyTenthOfASecond(const Duration(seconds: 3));
      ThumbnailConfigs configsFor(String id) => ThumbnailConfigs(
        id: id,
        video: clip,
        outputSize: outputSize,
        timestamps: timestamps,
      );

      final results = await Future.wait([
        pve.getThumbnailStream(configsFor('concurrent-a')).toList(),
        pve.getThumbnailStream(configsFor('concurrent-b')).toList(),
      ]);

      for (final frames in results) {
        final indices = frames.expand((f) => f.indices).toList()..sort();
        expect(indices, List.generate(timestamps.length, (i) => i));
      }
    });
  });
}
