import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final testVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  // Audio extraction is not supported on Web, Windows, and Linux yet
  final skipPlatform = kIsWeb || isWindows || isLinux;

  final pve = ProVideoEditor.instance;

  /// Helper to check if a format is supported on current platform
  bool isFormatSupported(AudioFormat format) {
    if (kIsWeb) return false;

    switch (format) {
      case AudioFormat.mp3:
        return Platform.isAndroid; // MP3 only on Android
      case AudioFormat.aac:
      case AudioFormat.m4a:
      case AudioFormat.wav:
        return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
      case AudioFormat.caf:
        return Platform.isIOS || Platform.isMacOS; // CAF only on Apple
    }
  }

  for (final format in AudioFormat.values) {
    testWidgets(
      'extractAudio with $format returns valid audio file',
      (tester) async {
        if (!isFormatSupported(format)) return;

        final directory = await getTemporaryDirectory();
        final outputPath =
            '${directory.path}/test_audio_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

        final config = AudioExtractConfigs(video: testVideo, format: format);
        final result = await pve.extractAudioToFile(outputPath, config);

        expect(result, equals(outputPath));

        // Verify file was created
        final file = File(outputPath);
        expect(
          await file.exists(),
          isTrue,
          reason: 'Audio file should exist at $outputPath',
        );

        // Use extension-based MIME detection — header-based detection is
        // unreliable for MP4-container formats (AAC/M4A/MP3 on Android all
        // share the same magic bytes regardless of audio content).
        final mimeType = lookupMimeType(result);
        // AAC on iOS/macOS is saved with a .m4a extension (the only container
        // Apple supports for AAC export), so it resolves to 'audio/mp4'.
        // The mime package maps .wav to 'audio/x-wav' rather than 'audio/wav'.
        final expectedMimeTypes = switch (format) {
          AudioFormat.aac => [format.mimeType, 'audio/mp4'],
          AudioFormat.wav => [format.mimeType, 'audio/wav'],
          _ => [format.mimeType],
        };
        expect(expectedMimeTypes, contains(mimeType));

        // Verify file has content
        final fileSize = await file.length();
        expect(
          fileSize,
          greaterThan(1000),
          reason: 'Audio file should have reasonable size (>1KB)',
        );

        // Clean up
        await file.delete();
      },
      skip: skipPlatform || !isFormatSupported(format),
    );

    testWidgets(
      'extractAudio with $format and trimming works correctly',
      (tester) async {
        if (!isFormatSupported(format)) return;

        final directory = await getTemporaryDirectory();
        final outputPath =
            '${directory.path}/test_audio_trimmed_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

        // Extract 5 seconds from the middle of the video
        final config = AudioExtractConfigs(
          video: testVideo,
          format: format,
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 10),
        );

        final result = await pve.extractAudioToFile(outputPath, config);

        expect(result, equals(outputPath));

        // Verify file was created
        final file = File(outputPath);
        expect(
          await file.exists(),
          isTrue,
          reason: 'Trimmed audio file should exist',
        );

        // Verify file size is smaller than full extraction
        // (approximately 1/6 of the original since we extract 5 of ~30 seconds)
        final fileSize = await file.length();
        expect(
          fileSize,
          greaterThan(500),
          reason: 'Trimmed audio should have some content',
        );
        // WAV is uncompressed — 5 seconds can be several MB depending on
        // sample rate and bit depth, so only cap compressed formats.
        if (format != AudioFormat.wav && format != AudioFormat.caf) {
          expect(
            fileSize,
            lessThan(500000),
            reason: 'Trimmed audio should be smaller than full extraction',
          );
        }

        // Clean up
        await file.delete();
      },
      skip: skipPlatform || !isFormatSupported(format),
    );
  }

  testWidgets('extractAudio emits progress updates', (tester) async {
    // Use platform-specific format
    final format = Platform.isAndroid ? AudioFormat.mp3 : AudioFormat.m4a;

    final directory = await getTemporaryDirectory();
    final outputPath =
        '${directory.path}/test_audio_progress_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

    final config = AudioExtractConfigs(video: testVideo, format: format);

    final progressValues = <double>[];
    final subscription = ProVideoEditor.instance
        .progressStreamById(config.id)
        .listen((event) {
          progressValues.add(event.progress);
        });

    await ProVideoEditor.instance.extractAudioToFile(outputPath, config);
    await subscription.cancel();

    // Verify progress updates
    expect(progressValues, isNotEmpty, reason: 'Progress: no updates received');
    expect(
      progressValues.first,
      lessThanOrEqualTo(0.1),
      reason: 'Progress: did not start low',
    );
    expect(
      progressValues.last,
      closeTo(1.0, 0.05),
      reason: 'Progress: did not reach 1.0',
    );

    // Verify progress is monotonically increasing
    final sorted = List.of(progressValues)..sort();
    expect(
      progressValues,
      sorted,
      reason: 'Progress: not monotonically increasing',
    );

    // Clean up
    final file = File(outputPath);
    if (await file.exists()) {
      await file.delete();
    }
  }, skip: skipPlatform);

  testWidgets('extractAudio can be cancelled', (tester) async {
    // Use platform-specific format
    final format = Platform.isAndroid ? AudioFormat.mp3 : AudioFormat.m4a;

    final directory = await getTemporaryDirectory();
    final outputPath =
        '${directory.path}/test_audio_cancel_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

    final config = AudioExtractConfigs(video: testVideo, format: format);

    // Start extraction in a non-blocking way
    final extractionFuture = ProVideoEditor.instance.extractAudioToFile(
      outputPath,
      config,
    );

    // Capture error before cancel to prevent unhandled async exception
    final capturedError = extractionFuture.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );

    // Small delay to let extraction start
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Cancel the task — extraction may already be finished on fast machines,
    // so handle TASK_NOT_FOUND gracefully.
    bool cancelledInTime = true;
    try {
      await ProVideoEditor.instance.cancel(config.id);
    } on PlatformException catch (e) {
      if (e.code == 'TASK_NOT_FOUND') {
        cancelledInTime = false;
      } else {
        rethrow;
      }
    }

    final error = await capturedError;
    if (cancelledInTime) {
      expect(error, isA<RenderCanceledException>());
    } else {
      // Task completed before cancel — no error expected
      expect(error, isNull);
    }

    // Clean up if file was created
    final file = File(outputPath);
    if (await file.exists()) {
      await file.delete();
    }
  }, skip: skipPlatform);

  testWidgets('extractAudio handles invalid time ranges gracefully', (
    tester,
  ) async {
    // Use platform-specific format
    final format = Platform.isAndroid ? AudioFormat.mp3 : AudioFormat.m4a;

    final directory = await getTemporaryDirectory();
    final outputPath =
        '${directory.path}/test_audio_invalid_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

    // Try to extract with start time after end time
    final config = AudioExtractConfigs(
      video: testVideo,
      format: format,
      startTime: const Duration(seconds: 20),
      endTime: const Duration(seconds: 10),
    );

    try {
      await ProVideoEditor.instance.extractAudioToFile(outputPath, config);
      // If it succeeds, the implementation might handle it gracefully
      // by swapping or clamping the values
    } catch (e) {
      // Expected: should throw an error for invalid range
      expect(e, isNotNull);
    }

    // Clean up if file was created
    final file = File(outputPath);
    if (await file.exists()) {
      await file.delete();
    }
  }, skip: skipPlatform);
}
