import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';
import 'package:pro_video_editor_example/core/constants/example_filters.dart';

/// Creates a simple semi-transparent PNG overlay image for testing.
Future<Uint8List> createTestOverlayImage({
  int width = 200,
  int height = 100,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  final paint = ui.Paint()
    ..color = const ui.Color.fromARGB(128, 255, 0, 0)
    ..style = ui.PaintingStyle.fill;

  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    paint,
  );

  final borderPaint = ui.Paint()
    ..color = const ui.Color.fromARGB(255, 255, 255, 255)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 4;

  canvas.drawRect(ui.Rect.fromLTWH(2, 2, width - 4, height - 4), borderPaint);

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

  return byteData!.buffer.asUint8List();
}

/// Copies a Flutter asset to a temporary file and returns the path.
Future<String> copyAssetToTempFile(String assetPath) async {
  final byteData = await rootBundle.load(assetPath);
  final tempDir = await getTemporaryDirectory();
  final ext = assetPath.split('.').last;
  final tempFile = File(
    '${tempDir.path}/test_audio_${DateTime.now().millisecondsSinceEpoch}.$ext',
  );
  await tempFile.writeAsBytes(byteData.buffer.asUint8List());
  return tempFile.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final h264Video = EditorVideo.asset(kVideoEditorExampleH264Path);
  final inputVideo = h264Video;

  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
  final isAndroid = !kIsWeb && Platform.isAndroid;
  final isApple = isIOS || isMacOS;

  Future<VideoMetadata> testRender({
    required String description,
    required VideoRenderData renderModel,
  }) async {
    final result = await ProVideoEditor.instance.renderVideo(renderModel);
    expect(result, isNotNull, reason: '$description failed — result is null');
    expect(
      result.lengthInBytes,
      greaterThan(100000),
      reason: '$description failed — video is too small',
    );

    final meta = await ProVideoEditor.instance.getMetadata(
      EditorVideo.memory(result),
    );
    expect(
      meta.extension,
      equals(renderModel.outputFormat.name),
      reason: '$description — wrong format',
    );

    return meta;
  }

  // ───────────────────────────────────────────────────────────
  // Timeline-based Color Filters
  // ───────────────────────────────────────────────────────────
  group('Timeline-based color filters', () {
    testWidgets('single timed color filter (2s–5s)', (_) async {
      await testRender(
        description: 'Single timed color filter',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 5),
            ),
          ],
        ),
      );
    });

    testWidgets('multiple non-overlapping timed color filters', (_) async {
      await testRender(
        description: 'Multiple non-overlapping timed filters',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix[0].matrix,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
            ),
            ColorFilter(
              matrix: kComplexFilterMatrix[1].matrix,
              startTime: const Duration(seconds: 5),
              endTime: const Duration(seconds: 8),
            ),
          ],
        ),
      );
    });

    testWidgets('overlapping timed color filters', (_) async {
      await testRender(
        description: 'Overlapping timed color filters',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix[0].matrix,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 6),
            ),
            ColorFilter(
              matrix: kComplexFilterMatrix[1].matrix,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 9),
            ),
          ],
        ),
      );
    });

    testWidgets('color filter without time range (full duration)', (_) async {
      await testRender(
        description: 'Color filter full duration',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kComplexFilterMatrix,
        ),
      );
    });

    testWidgets('timed color filter combined with blur', (_) async {
      await testRender(
        description: 'Timed color filter + blur',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 3,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      );
    });

    testWidgets('timed color filter combined with crop and flip', (_) async {
      await testRender(
        description: 'Timed color filter + crop + flip',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(
            flipX: true,
            x: 100,
            y: 100,
            width: 600,
            height: 400,
          ),
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
            ),
          ],
        ),
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Per-clip volume
  // ───────────────────────────────────────────────────────────
  group('Per-clip volume', () {
    testWidgets('single clip with reduced volume (0.3)', (_) async {
      await testRender(
        description: 'Single clip volume 0.3',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo, volume: 0.3)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
    });

    testWidgets('single clip muted (volume 0.0)', (_) async {
      await testRender(
        description: 'Single clip muted',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo, volume: 0.0)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
    });

    testWidgets('merged clips with different volumes', (_) async {
      final meta = await testRender(
        description: 'Merged clips different volumes',
        renderModel: VideoRenderData(
          videoSegments: [
            VideoSegment(video: inputVideo, volume: 0.2),
            VideoSegment(video: inputVideo, volume: 0.8),
          ],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      final originalMeta = await ProVideoEditor.instance.getMetadata(
        inputVideo,
      );
      expect(
        meta.duration.inSeconds,
        closeTo(originalMeta.duration.inSeconds * 2, 1),
        reason: 'Duration should be sum of both clips',
      );
    });

    testWidgets('per-clip volume with trim', (_) async {
      await testRender(
        description: 'Per-clip volume with trim',
        renderModel: VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 5),
              endTime: const Duration(seconds: 15),
              volume: 0.5,
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
    });

    testWidgets('per-clip volume with color filter', (_) async {
      await testRender(
        description: 'Per-clip volume + color filter',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo, volume: 0.4)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
        ),
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Multi-track audio (AudioTrack)
  // ───────────────────────────────────────────────────────────
  group('Multi-track audio', () {
    late String audioPath1;
    late String audioPath2;

    setUp(() async {
      audioPath1 = await copyAssetToTempFile(kVideoEditorExampleAudio1Path);
      audioPath2 = await copyAssetToTempFile(kVideoEditorExampleAudio2Path);
    });

    tearDown(() async {
      try {
        await File(audioPath1).delete();
      } catch (_) {}
      try {
        await File(audioPath2).delete();
      } catch (_) {}
    });

    testWidgets('single audio track for full duration', (_) async {
      await testRender(
        description: 'Single audio track full duration',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [VideoAudioTrack(path: audioPath1)],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('single audio track with time range', (_) async {
      await testRender(
        description: 'Audio track timed (2s–8s)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [
            VideoAudioTrack(
              path: audioPath1,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 8),
            ),
          ],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('single audio track with custom volume', (_) async {
      await testRender(
        description: 'Audio track volume 0.5',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [VideoAudioTrack(path: audioPath1, volume: 0.5)],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('single audio track with loop', (_) async {
      await testRender(
        description: 'Audio track looped',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [VideoAudioTrack(path: audioPath1, loop: true)],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('two audio tracks simultaneously', (_) async {
      await testRender(
        description: 'Two simultaneous audio tracks',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [
            VideoAudioTrack(path: audioPath1, volume: 0.7),
            VideoAudioTrack(path: audioPath2, volume: 0.3),
          ],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('two audio tracks with different time ranges', (_) async {
      await testRender(
        description: 'Two audio tracks different time ranges',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [
            VideoAudioTrack(
              path: audioPath1,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 5),
            ),
            VideoAudioTrack(
              path: audioPath2,
              startTime: const Duration(seconds: 6),
              endTime: const Duration(seconds: 10),
            ),
          ],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('audio track with audioStartTime offset', (_) async {
      await testRender(
        description: 'Audio track with audioStartTime',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [
            VideoAudioTrack(
              path: audioPath1,
              audioStartTime: const Duration(seconds: 3),
            ),
          ],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('audio track combined with per-clip volume', (_) async {
      await testRender(
        description: 'Audio track + per-clip volume',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo, volume: 0.3)],
          outputFormat: VideoOutputFormat.mp4,
          audioTracks: [VideoAudioTrack(path: audioPath1, volume: 0.8)],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('audio track with original audio disabled', (_) async {
      await testRender(
        description: 'Audio track with enableAudio=false',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
          audioTracks: [VideoAudioTrack(path: audioPath1)],
        ),
      );
    }, skip: !isApple && !isAndroid);
  });

  // ───────────────────────────────────────────────────────────
  // Image Layer with nullable offset (stretch vs position)
  // ───────────────────────────────────────────────────────────
  group('Image layer offset modes', () {
    late EditorLayerImage overlayImage;

    setUp(() async {
      final bytes = await createTestOverlayImage(width: 200, height: 100);
      overlayImage = EditorLayerImage.memory(bytes);
    });

    testWidgets('image layer without offset (stretch to fill)', (_) async {
      await testRender(
        description: 'Image layer stretch (no offset)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with offset (positioned)', (_) async {
      await testRender(
        description: 'Image layer positioned at (50, 80)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
              offset: const Offset(50, 80),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with zero offset (top-left, original size)', (
      _,
    ) async {
      await testRender(
        description: 'Image layer at origin (0, 0)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
              offset: Offset.zero,
            ),
          ],
        ),
      );
    });

    testWidgets('mixed offset modes: one stretched, one positioned', (_) async {
      final overlay2 = EditorLayerImage.memory(
        await createTestOverlayImage(width: 100, height: 50),
      );
      await testRender(
        description: 'Mixed offset modes',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
              // no offset → stretch
            ),
            ImageLayer(
              image: overlay2,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 6),
              offset: const Offset(100, 200),
            ),
          ],
        ),
      );
    });
  });

  // ───────────────────────────────────────────────────────────
  // Combined timeline features
  // ───────────────────────────────────────────────────────────
  group('Combined timeline features', () {
    late EditorLayerImage overlayImage;
    late String audioPath;

    setUp(() async {
      final bytes = await createTestOverlayImage(width: 200, height: 100);
      overlayImage = EditorLayerImage.memory(bytes);
      audioPath = await copyAssetToTempFile(kVideoEditorExampleAudio1Path);
    });

    tearDown(() async {
      try {
        await File(audioPath).delete();
      } catch (_) {}
    });

    testWidgets('timed filter + timed image layer', (_) async {
      await testRender(
        description: 'Timed filter + timed image layer',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 8),
            ),
          ],
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 7),
              offset: const Offset(50, 50),
            ),
          ],
        ),
      );
    });

    testWidgets('timed filter + audio track + per-clip volume', (_) async {
      await testRender(
        description: 'Filter + audio + per-clip volume',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo, volume: 0.4)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 6),
            ),
          ],
          audioTracks: [VideoAudioTrack(path: audioPath, volume: 0.6)],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('all timeline features combined', (_) async {
      await testRender(
        description: 'All timeline features combined',
        renderModel: VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 15),
              volume: 0.5,
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true),
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix[0].matrix,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 5),
            ),
            ColorFilter(
              matrix: kComplexFilterMatrix[1].matrix,
              startTime: const Duration(seconds: 7),
              endTime: const Duration(seconds: 10),
            ),
          ],
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 6),
              offset: const Offset(30, 40),
            ),
          ],
          audioTracks: [
            VideoAudioTrack(
              path: audioPath,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 10),
              volume: 0.7,
            ),
          ],
        ),
      );
    }, skip: !isApple && !isAndroid);

    testWidgets('merged clips with different volumes + timed filters', (
      _,
    ) async {
      final meta = await testRender(
        description: 'Merged clips + timed filters',
        renderModel: VideoRenderData(
          videoSegments: [
            VideoSegment(video: inputVideo, volume: 0.2),
            VideoSegment(video: inputVideo, volume: 1.0),
          ],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: kComplexFilterMatrix.first.matrix,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 8),
            ),
          ],
        ),
      );

      final originalMeta = await ProVideoEditor.instance.getMetadata(
        inputVideo,
      );
      expect(
        meta.duration.inSeconds,
        closeTo(originalMeta.duration.inSeconds * 2, 1),
        reason: 'Duration should be sum of both clips',
      );
    });
  });
}
