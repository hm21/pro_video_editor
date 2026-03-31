import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  // Draw a semi-transparent red rectangle with a border
  final paint = ui.Paint()
    ..color =
        const ui.Color.fromARGB(128, 255, 0, 0) // Semi-transparent red
    ..style = ui.PaintingStyle.fill;

  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    paint,
  );

  // Draw border
  final borderPaint = ui.Paint()
    ..color =
        const ui.Color.fromARGB(255, 255, 255, 255) // White border
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

  /// HEVC 10-bit HDR video (problematic codec from Samsung Galaxy S26)
  final hevcVideo = EditorVideo.asset(kVideoEditorExampleHevcPath);

  /// Standard H.264 video (normal codec)
  final h264Video = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// Default input video for general tests - using H.264 for stability
  final inputVideo = h264Video;

  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
  final supportsCancel =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

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

    // Optionally validate resulting metadata
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

  Future<void> testFormat({
    required VideoOutputFormat format,
    required String description,
  }) async {
    final result = await ProVideoEditor.instance.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: format,
      ),
    );

    expect(result, isNotNull, reason: '$description failed — result is null');
    expect(
      result.lengthInBytes,
      greaterThan(100000),
      reason: '$description failed — video too small',
    );
  }

  testWidgets('Export in mp4', (_) async {
    await testFormat(format: VideoOutputFormat.mp4, description: 'mp4 export');
  });

  /* testWidgets('Export in webm (Android)', (_) async {
    await testFormat(
        format: VideoOutputFormat.webm, description: 'Android webm export');
  }, skip: !isAndroid); */

  testWidgets('Export in mov (Apple)', (_) async {
    await testFormat(
      format: VideoOutputFormat.mov,
      description: 'iOS/macOS mov export',
    );
  }, skip: !isIOS && !isMacOS);

  testWidgets('rotate 90°', (tester) async {
    final originalMeta = await ProVideoEditor.instance.getMetadata(inputVideo);
    var meta = await testRender(
      description: 'Rotate 90°',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        transform: const ExportTransform(rotateTurns: 1),
      ),
    );

    if (meta.rotation != 0) {
      expect(meta.rotation, 90);
    } else {
      expect(meta.resolution, originalMeta.resolution.flipped);
    }
  });

  testWidgets('flip horizontally and vertically', (tester) async {
    await testRender(
      description: 'Flip X/Y',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        transform: const ExportTransform(flipX: true, flipY: true),
      ),
    );
  });

  testWidgets('crop video', (tester) async {
    var size = const Size(700, 300);
    var meta = await testRender(
      description: 'Crop (700x300)',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        transform: ExportTransform(
          x: 100,
          y: 250,
          width: size.width.toInt(),
          height: size.height.toInt(),
        ),
      ),
    );
    expect(meta.resolution, size);
  });

  testWidgets('scale video down', (tester) async {
    const factor = 5.0;

    final originalMeta = await ProVideoEditor.instance.getMetadata(inputVideo);
    var meta = await testRender(
      description: 'Scale 0.2x',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        transform: const ExportTransform(
          scaleX: 1 / factor,
          scaleY: 1 / factor,
        ),
      ),
    );
    expect(originalMeta.resolution / factor, meta.resolution);
  });

  // Note: This test uses h264Video (demo.mp4, ~30s) since hevcVideo
  // is only ~2.5s
  testWidgets('trim video (7s - 20s)', (tester) async {
    var meta = await testRender(
      description: 'Trim 7s to 20s',
      renderModel: VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: h264Video,
            startTime: const Duration(seconds: 7),
            endTime: const Duration(seconds: 20),
          ),
        ],
        outputFormat: VideoOutputFormat.mp4,
      ),
    );
    expect(meta.duration.inMilliseconds, 13000);
  });

  testWidgets('change speed to 2x and 0.8x', (tester) async {
    final originalMeta = await ProVideoEditor.instance.getMetadata(inputVideo);

    Future<void> testSpeed(double speed) async {
      final renderModel = VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        playbackSpeed: speed,
      );
      final meta = await testRender(
        description: 'Speed x$speed',
        renderModel: renderModel,
      );

      expect(
        meta.duration.inSeconds,
        (originalMeta.duration.inSeconds / speed).floor(),
        reason: 'Duration should be adjusted by x$speed',
      );
    }

    await testSpeed(2.0); // Speed up
    await testSpeed(0.8); // Slow down
  });

  testWidgets('remove audio', (tester) async {
    await testRender(
      description: 'Audio removed',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        enableAudio: false,
      ),
    );
  });

  testWidgets('apply color matrix', (tester) async {
    await testRender(
      description: 'Color filter applied',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        colorFilters: kComplexFilterMatrix,
      ),
    );
  });

  testWidgets('apply blur', (tester) async {
    await testRender(
      description: 'Apply blur',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        blur: 5,
      ),
    );
  });

  testWidgets('Bitrate is applied correctly (2.5 Mbps)', (tester) async {
    const expectedBitrate = 2500000; // 2.5 Mbps
    const tolerance = 0.42; // ±42% Important if CBR isn't supported

    var meta = await testRender(
      description: 'Bitrate set to 2.5 Mbps',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: inputVideo)],
        outputFormat: VideoOutputFormat.mp4,
        bitrate: expectedBitrate,
      ),
    );

    final actualBitrate = meta.bitrate; // in bits per second
    const minBitrate = expectedBitrate * (1 - tolerance);
    const maxBitrate = expectedBitrate * (1 + tolerance);

    final bitrateValid =
        actualBitrate >= minBitrate && actualBitrate <= maxBitrate;

    expect(
      bitrateValid,
      isTrue,
      reason: 'Bitrate validation failed. The Bitrate is $actualBitrate.',
    );
  });

  // Note: This test uses h264Video (demo.mp4, ~30s) since hevcVideo
  // is only ~2.5s
  testWidgets('combine multiple changes', (tester) async {
    await testRender(
      description: 'Multiple transformations',
      renderModel: VideoRenderData(
        videoSegments: [VideoSegment(video: h264Video)],
        outputFormat: VideoOutputFormat.mp4,
        transform: const ExportTransform(flipX: true),
        colorFilters: kBasicFilterMatrix,
        enableAudio: false,
        endTime: const Duration(seconds: 20),
      ),
    );
  });

  testWidgets('progress stream updates during rendering', (tester) async {
    final List<double> progressValues = [];

    var task = VideoRenderData(
      videoSegments: [VideoSegment(video: inputVideo)],
      outputFormat: VideoOutputFormat.mp4,
      // Using blur to ensure rendering takes time with consistent progress
      blur: 3.0,
    );

    final sub = task.progressStream.listen((progress) {
      progressValues.add(progress.progress);
    });

    await ProVideoEditor.instance.renderVideo(task);

    // Wait for final progress event to be processed (stream events are async)
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await sub.cancel();

    expect(progressValues, isNotEmpty, reason: 'No progress updates received');
    // Progress might not start at exactly 0, check first value is low
    if (progressValues.isNotEmpty) {
      expect(
        progressValues.first,
        lessThanOrEqualTo(0.5),
        reason: "Progress didn't start at low value",
      );
    }
    // 100% progress is guaranteed to be reported before completion
    expect(
      progressValues.last,
      equals(1.0),
      reason: 'Final progress should be exactly 100%',
    );
    expect(
      List.from(progressValues)..sort(),
      progressValues,
      reason: 'Progress should be monotonically increasing',
    );
  });

  group('cancel render task', () {
    // Pre-resolve asset to file so toAsyncMap() doesn't need I/O,
    // eliminating the delay between renderVideo() call and native
    // task registration.
    late EditorVideo cancelVideo;
    setUp(() async {
      cancelVideo = EditorVideo.file(await inputVideo.safeFilePath());
    });

    testWidgets('cancel renderVideo throws RenderCanceledException', (_) async {
      final taskId = 'cancel-test-${DateTime.now().millisecondsSinceEpoch}';

      final task = VideoRenderData(
        id: taskId,
        videoSegments: List<VideoSegment>.generate(
          10,
          (_) => VideoSegment(video: cancelVideo),
        ),
        outputFormat: VideoOutputFormat.mp4,
        blur: 10,
      );

      // Start rendering in a non-blocking way
      final renderFuture = ProVideoEditor.instance.renderVideo(task);

      // Capture error before cancel to prevent unhandled async exception
      final capturedError = renderFuture.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      // Small delay — toAsyncMap() is instant now since file is pre-resolved
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Cancel the task
      await ProVideoEditor.instance.cancel(taskId);

      // Expect the render to throw RenderCanceledException
      expect(await capturedError, isA<RenderCanceledException>());
    }, skip: !supportsCancel);

    testWidgets(
      'cancel renderVideoToFile throws RenderCanceledException',
      (_) async {
        final taskId =
            'cancel-file-test-${DateTime.now().millisecondsSinceEpoch}';
        final tempDir = await Directory.systemTemp.createTemp('render_test_');
        final outputPath = '${tempDir.path}/cancelled_video.mp4';

        final task = VideoRenderData(
          id: taskId,
          videoSegments: List<VideoSegment>.generate(
            10,
            (_) => VideoSegment(video: cancelVideo),
          ),
          outputFormat: VideoOutputFormat.mp4,
          blur: 10,
        );

        // Start rendering to file in a non-blocking way
        final renderFuture = ProVideoEditor.instance.renderVideoToFile(
          outputPath,
          task,
        );

        // Capture error before cancel to prevent unhandled async exception
        final capturedError = renderFuture.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );

        // Small delay — toAsyncMap() is instant now since file is pre-resolved
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Cancel the task
        await ProVideoEditor.instance.cancel(taskId);

        // Expect the render to throw RenderCanceledException
        expect(await capturedError, isA<RenderCanceledException>());

        // Clean up temp directory
        await tempDir.delete(recursive: true);
      },
      skip: !supportsCancel,
    );
    testWidgets('progress stream stops after cancel', (_) async {
      final taskId =
          'cancel-progress-test-${DateTime.now().millisecondsSinceEpoch}';
      final List<double> progressValues = [];

      final task = VideoRenderData(
        id: taskId,
        videoSegments: List<VideoSegment>.generate(
          10,
          (_) => VideoSegment(video: cancelVideo),
        ),
        outputFormat: VideoOutputFormat.mp4,
        blur: 10,
      );

      final subscription = task.progressStream.listen((progress) {
        progressValues.add(progress.progress);
      });

      // Start rendering
      final renderFuture = ProVideoEditor.instance.renderVideo(task);

      // Capture error before cancel to prevent unhandled async exception
      final capturedError = renderFuture.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      // Small delay — toAsyncMap() is instant now since file is pre-resolved
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Cancel the task
      await ProVideoEditor.instance.cancel(taskId);

      // Expect the render to be cancelled
      expect(await capturedError, isA<RenderCanceledException>());

      await subscription.cancel();

      // Progress should not have reached 100%
      if (progressValues.isNotEmpty) {
        expect(
          progressValues.last,
          lessThan(1.0),
          reason: 'Progress should not reach 100% after cancel',
        );
      }
    }, skip: !supportsCancel);

    testWidgets('cancel with invalid taskId throws PlatformException', (
      _,
    ) async {
      // Cancelling a non-existent task should throw a PlatformException with
      // code 'TASK_NOT_FOUND'
      await expectLater(
        ProVideoEditor.instance.cancel('non-existent-task-id'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'TASK_NOT_FOUND',
          ),
        ),
      );
    }, skip: !supportsCancel);

    testWidgets('cancel with empty taskId throws ArgumentError', (_) async {
      await expectLater(
        ProVideoEditor.instance.cancel(''),
        throwsA(isA<ArgumentError>()),
      );
    }, skip: !supportsCancel);
  });

  // ===========================================================================
  // HEVC 10-bit HDR Video Tests (Samsung Galaxy S26 compatibility)
  // ===========================================================================
  group('HEVC 10-bit HDR video', () {
    testWidgets('basic export to mp4', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC export failed');
      expect(
        result.lengthInBytes,
        greaterThan(100000),
        reason: 'HEVC export too small',
      );
    });

    testWidgets('export with color filter', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kComplexFilterMatrix,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with filter failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with blur effect', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 5,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with blur failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with rotation', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(rotateTurns: 1),
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with rotation failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with flip', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true, flipY: true),
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with flip failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with crop', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(
            x: 100,
            y: 100,
            width: 500,
            height: 400,
          ),
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with crop failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('export with scale', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(scaleX: 0.5, scaleY: 0.5),
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with scale failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('trim video', (_) async {
      // hevc.mp4 is ~2.5s, so trim from 0-2s for ~2s output
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC trim failed');
      expect(result.lengthInBytes, greaterThan(50000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(2, 1),
        reason: 'HEVC trim duration incorrect',
      );
    });

    testWidgets('export with speed change 2x', (_) async {
      final originalMeta = await ProVideoEditor.instance.getMetadata(hevcVideo);
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          playbackSpeed: 2.0,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with speed change failed');
      expect(result.lengthInBytes, greaterThan(50000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(originalMeta.duration.inSeconds / 2, 1),
        reason: 'HEVC speed 2x duration incorrect',
      );
    });

    testWidgets('export with speed change 0.5x', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
          playbackSpeed: 0.5,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with slow motion failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('remove audio', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC remove audio failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with combined effects', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
          blur: 3,
          transform: const ExportTransform(flipX: true, rotateTurns: 1),
          enableAudio: false,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC with combined effects failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    // Note: hevc.mp4 is only ~2.5s, so use 0-1s and 1-2s segments
    testWidgets('merge two HEVC videos', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'HEVC merge failed');
      expect(result.lengthInBytes, greaterThan(50000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(2, 1),
        reason: 'HEVC merge duration incorrect',
      );
    });

    // Note: hevc.mp4 is only ~2.5s, so use 0-1s and 1-2s segments
    testWidgets('merge HEVC with effects', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'HEVC merge with effects failed');
      expect(result.lengthInBytes, greaterThan(30000));
    });

    testWidgets('export to mov (Apple)', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mov,
        ),
      );
      expect(result, isNotNull, reason: 'HEVC to MOV failed');
      expect(result.lengthInBytes, greaterThan(100000));
    }, skip: !isIOS && !isMacOS);
  });

  // ===========================================================================
  // Standard H.264 Video Tests (demo.mp4)
  // ===========================================================================
  group('Standard H.264 video (demo.mp4)', () {
    testWidgets('basic export to mp4', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 export failed');
      expect(
        result.lengthInBytes,
        greaterThan(100000),
        reason: 'H.264 export too small',
      );
    });

    testWidgets('export with color filter', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kComplexFilterMatrix,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with filter failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with blur effect', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 5,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with blur failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with rotation', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(rotateTurns: 1),
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with rotation failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with flip', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true, flipY: true),
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with flip failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with crop', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(
            x: 100,
            y: 100,
            width: 500,
            height: 400,
          ),
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with crop failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('export with scale', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(scaleX: 0.5, scaleY: 0.5),
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with scale failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('trim video', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 4),
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 trim failed');
      expect(result.lengthInBytes, greaterThan(50000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(3, 1),
        reason: 'H.264 trim duration incorrect',
      );
    });

    testWidgets('export with speed change 2x', (_) async {
      final originalMeta = await ProVideoEditor.instance.getMetadata(h264Video);
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          playbackSpeed: 2.0,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with speed change failed');
      expect(result.lengthInBytes, greaterThan(50000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(originalMeta.duration.inSeconds / 2, 1),
        reason: 'H.264 speed 2x duration incorrect',
      );
    });

    testWidgets('export with speed change 0.5x', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
          playbackSpeed: 0.5,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with slow motion failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('remove audio', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 remove audio failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('export with combined effects', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
          blur: 3,
          transform: const ExportTransform(flipX: true, rotateTurns: 1),
          enableAudio: false,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 with combined effects failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('merge two H.264 videos', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 5),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'H.264 merge failed');
      expect(result.lengthInBytes, greaterThan(100000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(4, 1),
        reason: 'H.264 merge duration incorrect',
      );
    });

    testWidgets('merge H.264 with effects', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 5),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'H.264 merge with effects failed');
      expect(result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('export to mov (Apple)', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mov,
        ),
      );
      expect(result, isNotNull, reason: 'H.264 to MOV failed');
      expect(result.lengthInBytes, greaterThan(100000));
    }, skip: !isIOS && !isMacOS);
  });

  // ===========================================================================
  // Codec Comparison Tests
  // ===========================================================================
  group('Codec comparison (HEVC vs H.264)', () {
    testWidgets('both codecs produce valid output', (_) async {
      final hevcResult = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      final h264Result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      expect(hevcResult, isNotNull, reason: 'HEVC result is null');
      expect(h264Result, isNotNull, reason: 'H.264 result is null');
      expect(
        hevcResult.lengthInBytes,
        greaterThan(100000),
        reason: 'HEVC output too small',
      );
      expect(
        h264Result.lengthInBytes,
        greaterThan(100000),
        reason: 'H.264 output too small',
      );
    });

    testWidgets('both codecs work with GPU effects', (_) async {
      Future<Uint8List> renderWithEffects(EditorVideo video) async {
        return ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            videoSegments: [VideoSegment(video: video)],
            outputFormat: VideoOutputFormat.mp4,
            colorFilters: kComplexFilterMatrix,
            blur: 5,
          ),
        );
      }

      final hevcResult = await renderWithEffects(hevcVideo);
      final h264Result = await renderWithEffects(h264Video);

      expect(hevcResult, isNotNull, reason: 'HEVC with effects failed');
      expect(h264Result, isNotNull, reason: 'H.264 with effects failed');
      expect(hevcResult.lengthInBytes, greaterThan(50000));
      expect(h264Result.lengthInBytes, greaterThan(50000));
    });

    testWidgets('metadata can be extracted from both codecs', (_) async {
      final hevcMeta = await ProVideoEditor.instance.getMetadata(hevcVideo);
      final h264Meta = await ProVideoEditor.instance.getMetadata(h264Video);

      expect(
        hevcMeta.duration,
        greaterThan(Duration.zero),
        reason: 'HEVC metadata invalid',
      );
      expect(
        h264Meta.duration,
        greaterThan(Duration.zero),
        reason: 'H.264 metadata invalid',
      );
      expect(
        hevcMeta.resolution.width,
        greaterThan(0),
        reason: 'HEVC resolution invalid',
      );
      expect(
        h264Meta.resolution.width,
        greaterThan(0),
        reason: 'H.264 resolution invalid',
      );
    });

    testWidgets('merge HEVC with H.264 video (mixed codecs)', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'Mixed codec merge failed');
      expect(result.lengthInBytes, greaterThan(100000));

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inSeconds,
        closeTo(4, 1),
        reason: 'Mixed codec merge duration incorrect',
      );
    });

    testWidgets('merge H.264 with HEVC video (reverse order)', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      expect(result, isNotNull, reason: 'Reverse mixed codec merge failed');
      expect(result.lengthInBytes, greaterThan(100000));
    });

    testWidgets('merge mixed codecs with effects', (_) async {
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: kBasicFilterMatrix,
          blur: 2,
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
            ),
            VideoSegment(
              video: h264Video,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      expect(
        result,
        isNotNull,
        reason: 'Mixed codec merge with effects failed',
      );
      expect(result.lengthInBytes, greaterThan(50000));
    });

    // Note: hevc.mp4 is only ~2.5s, so use 0-1.5s for HEVC
    testWidgets('both codecs work with trim', (_) async {
      Future<VideoMetadata> trimVideo(
        EditorVideo video, {
        Duration start = const Duration(milliseconds: 500),
        Duration end = const Duration(milliseconds: 2000),
      }) async {
        final result = await ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            videoSegments: [
              VideoSegment(video: video, startTime: start, endTime: end),
            ],
            outputFormat: VideoOutputFormat.mp4,
          ),
        );
        return ProVideoEditor.instance.getMetadata(EditorVideo.memory(result));
      }

      final hevcMeta = await trimVideo(hevcVideo);
      final h264Meta = await trimVideo(
        h264Video,
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 3),
      );

      expect(
        hevcMeta.duration.inMilliseconds,
        closeTo(1500, 500),
        reason: 'HEVC trim duration incorrect',
      );
      expect(
        h264Meta.duration.inSeconds,
        closeTo(2, 1),
        reason: 'H.264 trim duration incorrect',
      );
    });

    // Note: hevc.mp4 is only ~2.5s, so use 0-2s for HEVC
    testWidgets('both codecs work with speed change', (_) async {
      Future<Uint8List> speedUpVideo(
        EditorVideo video, {
        Duration end = const Duration(seconds: 2),
      }) async {
        return ProVideoEditor.instance.renderVideo(
          VideoRenderData(
            videoSegments: [
              VideoSegment(
                video: video,
                startTime: Duration.zero,
                endTime: end,
              ),
            ],
            outputFormat: VideoOutputFormat.mp4,
            playbackSpeed: 2.0,
          ),
        );
      }

      final hevcResult = await speedUpVideo(hevcVideo);
      final h264Result = await speedUpVideo(
        h264Video,
        end: const Duration(seconds: 4),
      );

      expect(hevcResult, isNotNull, reason: 'HEVC speed change failed');
      expect(h264Result, isNotNull, reason: 'H.264 speed change failed');
      expect(hevcResult.lengthInBytes, greaterThan(20000));
      expect(h264Result.lengthInBytes, greaterThan(50000));
    });
  });

  // ===========================================================================
  // Comprehensive All-Operations Tests (without speed change)
  // ===========================================================================
  group('Comprehensive all-operations tests', () {
    testWidgets('HEVC: apply ALL operations at once', (_) async {
      // Create overlay image
      final overlayImage = await createTestOverlayImage(
        width: 200,
        height: 100,
      );

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          // Overlay
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(overlayImage)),
          ],
          // Color filter + Blur
          colorFilters: kBasicFilterMatrix,
          blur: 2,
          // Transform: rotate, flip, scale
          transform: const ExportTransform(
            rotateTurns: 1,
            flipX: true,
            scaleX: 0.8,
            scaleY: 0.8,
          ),
          // Disable audio
          enableAudio: false,
          // Merge multiple trimmed segments (hevc.mp4 is ~2.5s)
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(milliseconds: 800),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(milliseconds: 1000),
              endTime: const Duration(milliseconds: 1800),
            ),
          ],
        ),
      );

      expect(result, isNotNull, reason: 'HEVC all-operations test failed');
      expect(
        result.lengthInBytes,
        greaterThan(50000),
        reason: 'Output video too small',
      );

      // Verify metadata
      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration,
        greaterThan(Duration.zero),
        reason: 'Output duration should be positive',
      );
    });

    testWidgets('H.264: apply ALL operations at once', (_) async {
      // Create overlay image
      final overlayImage = await createTestOverlayImage(
        width: 200,
        height: 100,
      );

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          // Overlay
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(overlayImage)),
          ],
          // Color filter + Blur
          colorFilters: kBasicFilterMatrix,
          blur: 2,
          // Transform: rotate, flip, scale
          transform: const ExportTransform(
            rotateTurns: 1,
            flipX: true,
            scaleX: 0.8,
            scaleY: 0.8,
          ),
          // Disable audio
          enableAudio: false,
          // Merge multiple trimmed segments
          videoSegments: [
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      );

      expect(result, isNotNull, reason: 'H.264 all-operations test failed');
      expect(
        result.lengthInBytes,
        greaterThan(50000),
        reason: 'Output video too small',
      );

      // Verify metadata
      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration,
        greaterThan(Duration.zero),
        reason: 'Output duration should be positive',
      );
    });

    testWidgets('Mixed codecs: apply ALL operations at once', (_) async {
      // Create overlay image
      final overlayImage = await createTestOverlayImage(
        width: 200,
        height: 100,
      );

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          // Overlay
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(overlayImage)),
          ],
          // Color filter + Blur
          colorFilters: kComplexFilterMatrix,
          blur: 3,
          // Transform: rotate, flip, crop
          transform: const ExportTransform(
            rotateTurns: 2, // 180°
            flipY: true,
            x: 50,
            y: 50,
            width: 600,
            height: 400,
          ),
          // Disable audio
          enableAudio: false,
          // Merge HEVC and H.264 segments (hevc.mp4 is ~2.5s)
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 4),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );

      expect(
        result,
        isNotNull,
        reason: 'Mixed codecs all-operations test failed',
      );
      expect(
        result.lengthInBytes,
        greaterThan(50000),
        reason: 'Output video too small',
      );

      // Verify metadata
      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration,
        greaterThan(Duration.zero),
        reason: 'Output duration should be positive',
      );
      expect(
        meta.resolution.width,
        equals(600),
        reason: 'Crop width not applied',
      );
      expect(
        meta.resolution.height,
        equals(400),
        reason: 'Crop height not applied',
      );
    });

    testWidgets('Single video: ALL operations without merge', (_) async {
      // Create overlay image
      final overlayImage = await createTestOverlayImage(
        width: 300,
        height: 150,
      );

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          // Overlay
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(overlayImage)),
          ],
          // Color filter + Blur
          colorFilters: kComplexFilterMatrix,
          blur: 4,
          // Transform: all transformations
          transform: const ExportTransform(
            rotateTurns: 3, // 270°
            flipX: true,
            flipY: true,
            scaleX: 0.5,
            scaleY: 0.5,
          ),
          // Trim (hevc.mp4 is ~2.5s)
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          // Disable audio
          enableAudio: false,
          // Bitrate control
          bitrate: 2000000,
        ),
      );

      expect(
        result,
        isNotNull,
        reason: 'Single video all-operations test failed',
      );
      // Note: Small file size expected due to 0.5x scale and short duration
      expect(
        result.lengthInBytes,
        greaterThan(3000),
        reason: 'Output video too small',
      );

      // Verify metadata
      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration,
        greaterThan(Duration.zero),
        reason: 'Output duration should be positive',
      );
    });

    testWidgets('Stress test: maximum complexity render', (_) async {
      // Create larger overlay image
      final overlayImage = await createTestOverlayImage(
        width: 400,
        height: 200,
      );

      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          outputFormat: VideoOutputFormat.mp4,
          // Large overlay
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(overlayImage)),
          ],
          // Complex color filter
          colorFilters: kComplexFilterMatrix,
          // Heavy blur
          blur: 8,
          // Transform
          transform: const ExportTransform(
            rotateTurns: 1,
            flipX: true,
            flipY: true,
            scaleX: 0.6,
            scaleY: 0.6,
          ),
          // Disable audio
          enableAudio: false,
          // Many segments with mixed codecs (hevc.mp4 is ~2.5s)
          videoSegments: [
            VideoSegment(
              video: hevcVideo,
              startTime: Duration.zero,
              endTime: const Duration(milliseconds: 800),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
            ),
            VideoSegment(
              video: hevcVideo,
              startTime: const Duration(milliseconds: 1000),
              endTime: const Duration(seconds: 2),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 5),
            ),
          ],
        ),
      );

      expect(result, isNotNull, reason: 'Stress test failed');
      expect(
        result.lengthInBytes,
        greaterThan(50000),
        reason: 'Output video too small',
      );

      // Verify output is valid video
      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(meta.duration, greaterThan(Duration.zero));
      expect(meta.resolution.width, greaterThan(0));
      expect(meta.resolution.height, greaterThan(0));
    });

    testWidgets('metadata is stripped after rendering', (_) async {
      // Verify the source video has GPS metadata
      final sourceMeta = await ProVideoEditor.instance.getMetadata(inputVideo);
      expect(
        sourceMeta.gpsCoordinates,
        isNotNull,
        reason: 'Source video should have GPS coordinates',
      );

      // Render the video
      final result = await ProVideoEditor.instance.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: inputVideo)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      // Check that the rendered video has no metadata
      final renderedMeta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        renderedMeta.gpsCoordinates,
        isNull,
        reason: 'GPS metadata should be stripped after rendering',
      );
      // Note: date is expected to remain — the MP4 container automatically
      // writes a creation_time in the mvhd atom during muxing.
      expect(
        renderedMeta.title,
        isEmpty,
        reason: 'Title metadata should be stripped after rendering',
      );
      expect(
        renderedMeta.artist,
        isEmpty,
        reason: 'Artist metadata should be stripped after rendering',
      );
      expect(
        renderedMeta.author,
        isEmpty,
        reason: 'Author metadata should be stripped after rendering',
      );
    }, skip: true);
  });
}
