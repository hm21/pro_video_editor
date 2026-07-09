import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_image_editor/plugins/mime/mime.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final testVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  const formatMimeMap = {
    ThumbnailFormat.jpeg: 'image/jpeg',
    ThumbnailFormat.png: 'image/png',
    ThumbnailFormat.webp: 'image/webp', // Android only
  };

  /// Respect the aspect ratio from the input video for basic tests.
  const outputWidth = 160.0;
  const outputHeight = 90.0;

  final isAndroid = defaultTargetPlatform == TargetPlatform.android;

  for (final format in ThumbnailFormat.values) {
    testWidgets(
      'getThumbnails with $format returns correct mime and size',
      (tester) async {
        final thumbnails = await ProVideoEditor.instance.getThumbnails(
          ThumbnailConfigs(
            video: testVideo,
            outputFormat: format,
            timestamps: List.generate(5, (i) => Duration(seconds: (i + 1) * 2)),
            outputSize: const Size(outputWidth, outputHeight),
            boxFit: ThumbnailBoxFit.cover,
          ),
        );

        expect(thumbnails.length, equals(5));

        for (final thumb in thumbnails) {
          expect(thumb, isNotNull);
          expect(thumb.lengthInBytes, greaterThan(100));

          /// Check output mime type is correct.
          final mime = lookupMimeType('', headerBytes: thumb);
          expect(mime, equals(formatMimeMap[format]));

          /// Check output size is correct.
          final image = await decodeImageFromList(thumb);
          expect(image, isNotNull, reason: 'Failed to decode thumbnail');
          expect(image.width, equals(outputWidth));
          expect(image.height, equals(outputHeight));
        }
      },
      skip: format == ThumbnailFormat.webp && !isAndroid,
    );

    testWidgets(
      'getKeyFrames with $format returns correct mime and size',
      (tester) async {
        final thumbnails = await ProVideoEditor.instance.getKeyFrames(
          KeyFramesConfigs(
            video: testVideo,
            outputFormat: format,
            maxOutputFrames: 3,
            outputSize: const Size(outputWidth, outputHeight),
            boxFit: ThumbnailBoxFit.cover,
          ),
        );

        expect(thumbnails.length, equals(3));

        for (final thumb in thumbnails) {
          expect(thumb, isNotNull);
          expect(thumb.lengthInBytes, greaterThan(100));

          /// Check output mime type is correct.
          final mime = lookupMimeType('', headerBytes: thumb);
          expect(mime, equals(formatMimeMap[format]));

          /// Check output size is correct.
          final image = await decodeImageFromList(thumb);
          expect(image, isNotNull, reason: 'Failed to decode thumbnail');
          expect(image.width, equals(outputWidth));
          expect(image.height, equals(outputHeight));
        }
      },
      skip: format == ThumbnailFormat.webp && !isAndroid,
    );
  }

  Future<void> testProgressEmission({
    required Future<void> Function() action,
    required Stream<ProgressModel> progressStream,
    String? reasonPrefix,
  }) async {
    final progressValues = <double>[];

    final sub = progressStream.listen((event) {
      progressValues.add(event.progress);
    });

    await action();

    /// Give the stream time to emit the final progress value on iOS/macOS.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    reasonPrefix ??= 'Progress';

    expect(
      progressValues,
      isNotEmpty,
      reason: '$reasonPrefix: no updates received',
    );
    expect(
      progressValues.first,
      lessThanOrEqualTo(0.1),
      reason: '$reasonPrefix: did not start low',
    );
    expect(
      progressValues.last,
      closeTo(1.0, 0.05),
      reason: '$reasonPrefix: did not reach 1.0',
    );
    expect(
      progressValues,
      isA<List<double>>(),
      reason: '$reasonPrefix: wrong type',
    );

    final sorted = List.of(progressValues)..sort();
    expect(
      progressValues,
      sorted,
      reason: '$reasonPrefix: not monotonically increasing',
    );
  }

  testWidgets('getThumbnails emits progress', (tester) async {
    final task = ThumbnailConfigs(
      video: testVideo,
      outputFormat: ThumbnailFormat.jpeg,
      timestamps: List.generate(3, (i) => Duration(seconds: i * 2)),
      outputSize: const Size(50, 50),
      boxFit: ThumbnailBoxFit.cover,
    );

    await testProgressEmission(
      action: () => ProVideoEditor.instance.getThumbnails(task),
      progressStream: task.progressStream,
      reasonPrefix: 'Thumbnails',
    );
  });

  testWidgets('getKeyFrames emits progress', (tester) async {
    final task = KeyFramesConfigs(
      video: testVideo,
      outputFormat: ThumbnailFormat.jpeg,
      maxOutputFrames: 3,
      outputSize: const Size(50, 50),
      boxFit: ThumbnailBoxFit.cover,
    );

    await testProgressEmission(
      action: () => ProVideoEditor.instance.getKeyFrames(task),
      progressStream: task.progressStream,
      reasonPrefix: 'KeyFrames',
    );
  });

  Future<void> expectThumbnailRespectsBoxFit({
    required ThumbnailBoxFit fit,
    required Size outputSize,
    required EditorVideo video,
    double aspectRatioTolerance = 0.05,
  }) async {
    final meta = await ProVideoEditor.instance.getMetadata(video);
    final originalAspectRatio = meta.resolution.aspectRatio;

    final thumb = (await ProVideoEditor.instance.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.jpeg,
        timestamps: const [Duration(seconds: 2)],
        outputSize: outputSize,
        boxFit: fit,
      ),
    )).first;

    final decoded = await decodeImageFromList(thumb);
    expect(decoded, isNotNull);

    final decodedW = decoded.width;
    final decodedH = decoded.height;
    final inputW = outputSize.width.toInt();
    final inputH = outputSize.height.toInt();

    final actualAspectRatio = decodedW / decodedH;

    expect(
      actualAspectRatio,
      closeTo(originalAspectRatio, aspectRatioTolerance),
      reason: 'Aspect ratio was not preserved for $fit mode',
    );

    if (fit == ThumbnailBoxFit.cover) {
      expect(
        (decodedW == inputW && decodedH >= inputH) ||
            (decodedW >= inputW && decodedH == inputH),
        isTrue,
        reason: 'BoxFit.cover must fill at least the target bounds',
      );
    } else if (fit == ThumbnailBoxFit.contain) {
      expect(
        (decodedW == inputW && decodedH <= inputH) ||
            (decodedW <= inputW && decodedH == inputH),
        isTrue,
        reason: 'BoxFit.contain must fit entirely within the target bounds',
      );
    }
  }

  testWidgets(
    'ThumbnailBoxFit.cover size is correct and respects aspect ratio',
    (tester) async {
      await expectThumbnailRespectsBoxFit(
        fit: ThumbnailBoxFit.cover,
        outputSize: const Size(100, 100),
        video: testVideo,
      );
    },
  );

  testWidgets(
    'ThumbnailBoxFit.contain size is correct and respects aspect ratio',
    (tester) async {
      await expectThumbnailRespectsBoxFit(
        fit: ThumbnailBoxFit.contain,
        outputSize: const Size(100, 100),
        video: testVideo,
      );
    },
  );

  group('getSingleThumbnail', () {
    for (final position in ThumbnailPosition.values) {
      testWidgets('extracts the ${position.name} frame', (tester) async {
        final thumb = await ProVideoEditor.instance.getSingleThumbnail(
          SingleThumbnailConfigs(
            video: testVideo,
            outputFormat: ThumbnailFormat.jpeg,
            outputSize: const Size(outputWidth, outputHeight),
            boxFit: ThumbnailBoxFit.cover,
            position: position,
          ),
        );

        expect(thumb, isNotNull);
        expect(thumb!.lengthInBytes, greaterThan(100));

        final mime = lookupMimeType('', headerBytes: thumb);
        expect(mime, equals(formatMimeMap[ThumbnailFormat.jpeg]));

        final image = await decodeImageFromList(thumb);
        expect(image.width, equals(outputWidth));
        expect(image.height, equals(outputHeight));
      });
    }

    testWidgets('last frame uses an explicit videoDuration', (tester) async {
      final meta = await ProVideoEditor.instance.getMetadata(testVideo);

      final thumb = await ProVideoEditor.instance.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: testVideo,
          outputFormat: ThumbnailFormat.jpeg,
          outputSize: const Size(outputWidth, outputHeight),
          boxFit: ThumbnailBoxFit.cover,
          position: ThumbnailPosition.last,
          videoDuration: meta.duration,
        ),
      );

      expect(thumb, isNotNull);
      expect(thumb!.lengthInBytes, greaterThan(100));
    });

    testWidgets('honors the png output format', (tester) async {
      final thumb = await ProVideoEditor.instance.getSingleThumbnail(
        SingleThumbnailConfigs(
          video: testVideo,
          outputFormat: ThumbnailFormat.png,
          outputSize: const Size(outputWidth, outputHeight),
          boxFit: ThumbnailBoxFit.cover,
          position: ThumbnailPosition.first,
        ),
      );

      expect(thumb, isNotNull);
      final mime = lookupMimeType('', headerBytes: thumb!);
      expect(mime, equals(formatMimeMap[ThumbnailFormat.png]));
    });
  });

  // Regression coverage for the native thumbnail wedge: a large batch of
  // timestamps whose decoder callbacks could arrive concurrently / out of order
  // (iOS 26.5). The batch must always complete (no hang), return exactly the
  // requested count with no dropped frames, and stay index-for-index aligned
  // with the requested timestamps regardless of request order.
  group('large-batch timestamp alignment (wedge regression)', () {
    /// Decodes an encoded thumbnail to raw RGBA bytes so two runs of the same
    /// timestamp can be compared deterministically (independent of encoder
    /// metadata).
    Future<Uint8List> rawRgba(Uint8List encoded) async {
      final ui.Image image = await decodeImageFromList(encoded);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!.buffer.asUint8List();
    }

    bool bytesEqual(Uint8List a, Uint8List b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    testWidgets('45 shuffled timestamps stay aligned and complete', (
      tester,
    ) async {
      final meta = await ProVideoEditor.instance.getMetadata(testVideo);
      final durationMs = meta.duration.inMilliseconds;
      expect(durationMs, greaterThan(1000), reason: 'need a real duration');

      // Evenly spread inside the video, away from the very start/end.
      const count = 45;
      final base = List.generate(count, (i) {
        final fraction = (i + 1) / (count + 1);
        return Duration(milliseconds: (durationMs * fraction).round());
      });

      Future<List<Uint8List>> run(List<Duration> timestamps) {
        return ProVideoEditor.instance
            .getThumbnails(
              ThumbnailConfigs(
                id: 'wedge-align-${DateTime.now().microsecondsSinceEpoch}',
                video: testVideo,
                outputFormat: ThumbnailFormat.png,
                timestamps: timestamps,
                outputSize: const Size(48, 27),
                boxFit: ThumbnailBoxFit.contain,
              ),
            )
            // A wedge used to hang this Future forever.
            .timeout(const Duration(seconds: 60));
      }

      // Sorted reference run: build timestamp -> decoded frame.
      final sorted = await run(base);
      expect(sorted.length, count, reason: 'count must equal request');
      for (var i = 0; i < sorted.length; i++) {
        expect(
          sorted[i].lengthInBytes,
          greaterThan(50),
          reason: 'frame $i must not be empty/dropped',
        );
      }

      final referenceByTimestamp = <int, Uint8List>{};
      for (var i = 0; i < base.length; i++) {
        referenceByTimestamp[base[i].inMilliseconds] = await rawRgba(sorted[i]);
      }

      // The video must actually vary, otherwise the alignment check is vacuous.
      expect(
        bytesEqual(
          referenceByTimestamp[base.first.inMilliseconds]!,
          referenceByTimestamp[base.last.inMilliseconds]!,
        ),
        isFalse,
        reason: 'first and last frames should differ in a real video',
      );

      // Shuffled run: result[i] must be the frame for shuffled[i], proving the
      // output maps by requested timestamp and not by completion order.
      final shuffled = List.of(base)..shuffle(Random(7));
      final out = await run(shuffled);
      expect(out.length, count, reason: 'shuffled count must equal request');

      for (var i = 0; i < shuffled.length; i++) {
        expect(
          out[i].lengthInBytes,
          greaterThan(50),
          reason: 'shuffled frame $i must not be empty/dropped',
        );
        final actual = await rawRgba(out[i]);
        final expected = referenceByTimestamp[shuffled[i].inMilliseconds]!;
        expect(
          bytesEqual(actual, expected),
          isTrue,
          reason:
              'frame $i (t=${shuffled[i].inMilliseconds}ms) is not aligned to '
              'its requested timestamp',
        );
      }
    });

    testWidgets('many sequential batches never wedge', (tester) async {
      // One wedged call used to block thumbnail generation for every later
      // batch for the rest of the session. Each batch here must complete on its
      // own.
      const batches = 8;
      const perBatch = 24;

      for (var batch = 0; batch < batches; batch++) {
        final result = await ProVideoEditor.instance
            .getThumbnails(
              ThumbnailConfigs(
                id: 'wedge-seq-$batch-${DateTime.now().microsecondsSinceEpoch}',
                video: testVideo,
                outputFormat: ThumbnailFormat.jpeg,
                timestamps: List.generate(
                  perBatch,
                  (i) => Duration(milliseconds: 300 + i * 900),
                ),
                outputSize: const Size(48, 27),
                boxFit: ThumbnailBoxFit.cover,
              ),
            )
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () =>
                  throw StateError('batch $batch wedged (never completed)'),
            );

        expect(
          result.length,
          perBatch,
          reason: 'batch $batch returned the wrong count',
        );
        expect(
          result.every((frame) => frame.lengthInBytes > 50),
          isTrue,
          reason: 'batch $batch dropped a frame',
        );
      }
    });
  }, skip: kIsWeb);
}
