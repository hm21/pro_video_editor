import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Creates a solid-color PNG frame for testing.
Future<Uint8List> createFrame({
  int width = 320,
  int height = 240,
  ui.Color color = const ui.Color(0xFF2196F3),
}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return byteData!.buffer.asUint8List();
}

/// Builds [count] frames, cycling through a few colors so each frame differs.
Future<List<StopMotionFrame>> buildFrames(
  int count, {
  Duration? duration,
  int width = 320,
  int height = 240,
}) async {
  const colors = [
    ui.Color(0xFFE53935),
    ui.Color(0xFF43A047),
    ui.Color(0xFF1E88E5),
    ui.Color(0xFFFDD835),
  ];
  final frames = <StopMotionFrame>[];
  for (var i = 0; i < count; i++) {
    final bytes = await createFrame(
      width: width,
      height: height,
      color: colors[i % colors.length],
    );
    frames.add(
      StopMotionFrame(
        image: EditorLayerImage.memory(bytes),
        duration: duration,
      ),
    );
  }
  return frames;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isIOS = !kIsWeb && Platform.isIOS;
  final isMacOS = !kIsWeb && Platform.isMacOS;
  final isAndroid = !kIsWeb && Platform.isAndroid;
  final supportsStopMotion = isAndroid || isIOS || isMacOS;

  group('Stop-Motion', () {
    testWidgets('renders a valid mp4 with the expected duration', (_) async {
      // 10 frames at 5 fps → ~2 seconds.
      final frames = await buildFrames(10);
      final result = await ProVideoEditor.instance.renderStopMotion(
        StopMotionRenderData(frames: frames, frameRate: 5),
      );

      expect(result, isNotNull, reason: 'Stop-motion result is null');
      expect(
        result.lengthInBytes,
        greaterThan(1000),
        reason: 'Stop-motion output too small',
      );

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(meta.extension, 'mp4');
      expect(
        meta.duration.inMilliseconds,
        closeTo(2000, 800),
        reason: '10 frames at 5 fps should be ~2s',
      );
    }, skip: !supportsStopMotion);

    testWidgets('per-frame duration overrides the default', (_) async {
      // 4 frames, each held 500ms → ~2 seconds regardless of frameRate.
      final frames = await buildFrames(
        4,
        duration: const Duration(milliseconds: 500),
      );
      final result = await ProVideoEditor.instance.renderStopMotion(
        StopMotionRenderData(frames: frames, frameRate: 30),
      );

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(
        meta.duration.inMilliseconds,
        closeTo(2000, 800),
        reason: '4 frames × 500ms should be ~2s',
      );
    }, skip: !supportsStopMotion);

    testWidgets('uses the explicit output resolution', (_) async {
      final frames = await buildFrames(6, width: 640, height: 480);
      final result = await ProVideoEditor.instance.renderStopMotion(
        StopMotionRenderData(
          frames: frames,
          frameRate: 6,
          resolution: const ui.Size(320, 240),
        ),
      );

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(meta.resolution.width, closeTo(320, 16));
      expect(meta.resolution.height, closeTo(240, 16));
    }, skip: !supportsStopMotion);

    testWidgets('defaults the resolution to the first frame', (_) async {
      final frames = await buildFrames(5, width: 480, height: 360);
      final result = await ProVideoEditor.instance.renderStopMotion(
        StopMotionRenderData(frames: frames, frameRate: 5),
      );

      final meta = await ProVideoEditor.instance.getMetadata(
        EditorVideo.memory(result),
      );
      expect(meta.resolution.width, closeTo(480, 16));
      expect(meta.resolution.height, closeTo(360, 16));
    }, skip: !supportsStopMotion);

    for (final fit in StopMotionFit.values) {
      testWidgets('renders valid output with fit "${fit.name}"', (_) async {
        // Non-square frames so the fit mode actually matters against a
        // square output.
        final frames = await buildFrames(6, width: 640, height: 360);
        final result = await ProVideoEditor.instance.renderStopMotion(
          StopMotionRenderData(
            frames: frames,
            frameRate: 6,
            fit: fit,
            resolution: const ui.Size(320, 320),
          ),
        );

        expect(
          result.lengthInBytes,
          greaterThan(1000),
          reason: 'fit ${fit.name} produced no output',
        );
      }, skip: !supportsStopMotion);
    }

    testWidgets('renderStopMotionToFile writes the video to disk', (_) async {
      final frames = await buildFrames(8);
      final tempDir = await Directory.systemTemp.createTemp('stop_motion_');
      final outputPath = '${tempDir.path}/stop_motion.mp4';

      final returnedPath = await ProVideoEditor.instance.renderStopMotionToFile(
        outputPath,
        StopMotionRenderData(frames: frames, frameRate: 8),
      );

      expect(returnedPath, outputPath);
      final file = File(outputPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(1000));

      await tempDir.delete(recursive: true);
    }, skip: !supportsStopMotion);

    testWidgets('progress stream reports completion', (_) async {
      final frames = await buildFrames(20);
      final task = StopMotionRenderData(frames: frames, frameRate: 10);

      final progressValues = <double>[];
      final sub = task.progressStream.listen((p) {
        progressValues.add(p.progress);
      });

      await ProVideoEditor.instance.renderStopMotion(task);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(progressValues, isNotEmpty, reason: 'No progress updates');
      expect(
        progressValues.last,
        equals(1.0),
        reason: 'Final progress should be 100%',
      );
    }, skip: !supportsStopMotion);

    testWidgets('progress advances smoothly instead of jumping 0 → 100%',
        (_) async {
      // Enough frames at a real resolution so the encode takes long enough to
      // emit several intermediate progress updates on every platform.
      final frames = await buildFrames(60, width: 1280, height: 720);
      final task = StopMotionRenderData(frames: frames, frameRate: 24);

      final progressValues = <double>[];
      final sub = task.progressStream.listen((p) {
        progressValues.add(p.progress);
      });

      await ProVideoEditor.instance.renderStopMotion(task);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(progressValues, isNotEmpty, reason: 'No progress updates');

      // Progress never goes backwards.
      for (var i = 1; i < progressValues.length; i++) {
        expect(
          progressValues[i],
          greaterThanOrEqualTo(progressValues[i - 1]),
          reason: 'Progress must never regress: $progressValues',
        );
      }

      // Completion is reported.
      expect(
        progressValues.last,
        equals(1.0),
        reason: 'Final progress should be 100%',
      );

      // The actual fix: the encode phase must report intermediate progress
      // rather than freezing low and snapping to 100%. Before the fix the
      // highest value seen before completion was the ~0.2 frame-prep share on
      // Android, so no value landed in the mid range.
      expect(
        progressValues.any((v) => v > 0.25 && v < 0.95),
        isTrue,
        reason: 'Progress jumped to 100% without meaningful mid-range updates: '
            '$progressValues',
      );
    }, skip: !supportsStopMotion);

    testWidgets('cancel throws RenderCanceledException', (_) async {
      final taskId =
          'stop-motion-cancel-${DateTime.now().millisecondsSinceEpoch}';
      // Many frames so the job runs long enough to be cancelled.
      final frames = await buildFrames(120, width: 1280, height: 720);
      final task = StopMotionRenderData(
        id: taskId,
        frames: frames,
        frameRate: 24,
      );

      final renderFuture = ProVideoEditor.instance.renderStopMotion(task);
      final capturedError = renderFuture.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await ProVideoEditor.instance.cancel(taskId);

      expect(await capturedError, isA<RenderCanceledException>());
    }, skip: !supportsStopMotion);
  });
}
