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
}
