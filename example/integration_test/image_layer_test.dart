import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hevcVideo = EditorVideo.asset(kVideoEditorExampleHevcPath);
  final h264Video = EditorVideo.asset(kVideoEditorExampleH264Path);
  final inputVideo = h264Video;

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

  group('Image overlay layers', () {
    late EditorLayerImage overlayImage;

    setUp(() async {
      final bytes = await createTestOverlayImage(width: 200, height: 100);
      overlayImage = EditorLayerImage.memory(bytes);
    });

    testWidgets('single image layer for full duration', (_) async {
      await testRender(
        description: 'Single image layer (full duration)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(image: overlayImage, startTime: Duration.zero),
          ],
        ),
      );
    });

    testWidgets('single image layer with time range', (_) async {
      await testRender(
        description: 'Single image layer (1s-4s)',
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

    testWidgets('multiple image layers with different time ranges', (_) async {
      final overlay2 = EditorLayerImage.memory(
        await createTestOverlayImage(width: 150, height: 80),
      );
      await testRender(
        description: 'Multiple image layers',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
            ),
            ImageLayer(
              image: overlay2,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      );
    });

    testWidgets('overlapping image layers', (_) async {
      final overlay2 = EditorLayerImage.memory(
        await createTestOverlayImage(width: 150, height: 80),
      );
      await testRender(
        description: 'Overlapping image layers',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 5),
            ),
            ImageLayer(
              image: overlay2,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 7),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with rotation', (_) async {
      await testRender(
        description: 'Image layer + rotation',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(rotateTurns: 1),
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

    testWidgets('image layer with flip', (_) async {
      await testRender(
        description: 'Image layer + flip',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true, flipY: true),
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

    testWidgets('image layer with crop', (_) async {
      await testRender(
        description: 'Image layer + crop',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(
            x: 100,
            y: 100,
            width: 500,
            height: 400,
          ),
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

    testWidgets('image layer with color filter', (_) async {
      await testRender(
        description: 'Image layer + color filter',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
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

    testWidgets('image layer with blur', (_) async {
      await testRender(
        description: 'Image layer + blur',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 3,
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

    testWidgets('image layer combined with multiple effects', (_) async {
      await testRender(
        description: 'Image layer + multiple effects',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true),
          colorFilters: kBasicFilterMatrix,
          endTime: const Duration(seconds: 20),
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

    testWidgets('image layer on h264 video', (_) async {
      await testRender(
        description: 'Image layer on HEVC',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer on HEVC video', (_) async {
      await testRender(
        description: 'Image layer on HEVC',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with offset (top left)', (_) async {
      await testRender(
        description: 'Image layer with offset (top left)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
              offset: const ui.Offset(0, 0),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with offset (center)', (_) async {
      await testRender(
        description: 'Image layer with offset (center)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
              offset: const ui.Offset(250, 150),
            ),
          ],
        ),
      );
    });

    testWidgets('image layer with offset (bottom right)', (_) async {
      await testRender(
        description: 'Image layer with offset (bottom right)',
        renderModel: VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            ImageLayer(
              image: overlayImage,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
              offset: const ui.Offset(400, 300),
            ),
          ],
        ),
      );
    });
  });
}
