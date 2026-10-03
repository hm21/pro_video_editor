import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

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

    testWidgets(
      'extractAudio with $format at 2x speed produces valid, shorter output',
      (tester) async {
        if (!isFormatSupported(format)) return;

        final directory = await getTemporaryDirectory();
        final ts = DateTime.now().millisecondsSinceEpoch;
        final normalPath =
            '${directory.path}/test_audio_1x_$ts.${format.extension}';
        final fastPath =
            '${directory.path}/test_audio_2x_$ts.${format.extension}';

        await pve.extractAudioToFile(
          normalPath,
          AudioExtractConfigs(video: testVideo, format: format),
        );
        await pve.extractAudioToFile(
          fastPath,
          AudioExtractConfigs(video: testVideo, format: format, speed: 2.0),
        );

        final normalFile = File(normalPath);
        final fastFile = File(fastPath);

        expect(
          await fastFile.exists(),
          isTrue,
          reason: 'Sped-up audio file should exist',
        );

        // Extension-based MIME detection (see notes on the base test).
        final mimeType = lookupMimeType(fastPath);
        final expectedMimeTypes = switch (format) {
          AudioFormat.aac => [format.mimeType, 'audio/mp4'],
          AudioFormat.wav => [format.mimeType, 'audio/wav'],
          _ => [format.mimeType],
        };
        expect(expectedMimeTypes, contains(mimeType));

        expect(
          await fastFile.length(),
          greaterThan(1000),
          reason: 'Sped-up audio should have content (>1KB)',
        );

        // WAV is uncompressed, so 2x speed roughly halves the PCM data. A
        // generous bound keeps this robust across sample rates / bit depths.
        if (format == AudioFormat.wav) {
          final normalSize = await normalFile.length();
          final fastSize = await fastFile.length();
          expect(
            fastSize,
            lessThan(normalSize * 0.75),
            reason: '2x WAV should be markedly smaller than the 1x extraction',
          );
        }

        // Clean up
        if (await normalFile.exists()) await normalFile.delete();
        if (await fastFile.exists()) await fastFile.delete();
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

    // Cancel the task. On fast machines the extraction may already have
    // finished, leaving no active task to cancel — that surfaces as a no-op
    // (Android) or a TASK_NOT_FOUND error (iOS/macOS); both are tolerated here.
    try {
      await ProVideoEditor.instance.cancel(config.id);
    } on PlatformException catch (e) {
      if (e.code != 'TASK_NOT_FOUND') rethrow;
    }

    // Whether the cancel landed in time is derived from the extraction outcome,
    // not from the cancel call: a cancelled extraction fails with
    // RenderCanceledException, a completed one resolves without error.
    final error = await capturedError;
    if (error != null) {
      expect(error, isA<RenderCanceledException>());
    }
    // else: extraction completed before the cancel arrived — no error expected.

    // Clean up if file was created
    final file = File(outputPath);
    if (await file.exists()) {
      await file.delete();
    }
  }, skip: skipPlatform);

  testWidgets('extractAudio throws on a video without an audio track', (
    tester,
  ) async {
    final format = Platform.isAndroid ? AudioFormat.mp3 : AudioFormat.m4a;

    final directory = await getTemporaryDirectory();
    final outputPath =
        '${directory.path}/test_audio_noaudio_${DateTime.now().millisecondsSinceEpoch}.${format.extension}';

    final config = AudioExtractConfigs(
      video: EditorVideo.asset('assets/demo_muted.mp4'),
      format: format,
    );

    await expectLater(
      ProVideoEditor.instance.extractAudioToFile(outputPath, config),
      throwsA(isA<AudioNoTrackException>()),
    );

    final file = File(outputPath);
    if (await file.exists()) {
      await file.delete();
    }
  }, skip: skipPlatform);

  testWidgets('extractAudio to WAV writes the decoded HE-AAC format', (
    tester,
  ) async {
    // HE-AAC v2 describes only its AAC core layer in the track (22.05 kHz
    // mono) but decodes to 44.1 kHz stereo (SBR + PS). A WAV header taken
    // from the track claims a quarter of the real data rate: the 2 s, 440 Hz
    // tone would last 8 s and sound two octaves too low.
    final video = EditorVideo.asset('assets/tests/he_aac_v2.m4a');
    final directory = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;

    Future<Pcm> extract(String name, {Duration? start, Duration? end}) async {
      final outputPath = '${directory.path}/test_audio_he_aac_${name}_$ts.wav';
      await pve.extractAudioToFile(
        outputPath,
        AudioExtractConfigs(
          video: video,
          format: AudioFormat.wav,
          startTime: start,
          endTime: end,
        ),
      );
      final file = File(outputPath);
      final pcm = Pcm.parseWav(await file.readAsBytes());
      await file.delete();
      return pcm;
    }

    final full = await extract('full');
    expect(full.seconds, closeTo(2, 0.1), reason: 'Full WAV length');
    expect(full.toneFrequency(0.2, 1.8), closeTo(440, 10));

    final trimmed = await extract(
      'trimmed',
      start: const Duration(milliseconds: 500),
      end: const Duration(milliseconds: 1500),
    );
    expect(trimmed.seconds, closeTo(1, 0.1), reason: 'Trimmed WAV length');
    expect(trimmed.toneFrequency(0.2, 0.8), closeTo(440, 10));
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

  testWidgets('extractAudio to WAV keeps a trimmed range in place', (
    tester,
  ) async {
    // 1 kHz bursts start exactly at 0.6 s and 1.2 s. The two files declare
    // the AAC encoder delay differently (iTunes metadata vs. an edit list);
    // both have to come out on the timeline of the audio as it plays.
    double? onsetAfter(Pcm pcm, double fromSec) {
      final from = (fromSec * pcm.sampleRate).round();
      for (var i = from; i < pcm.samples.length; i++) {
        if (pcm.samples[i].abs() > 0.1) return i / pcm.sampleRate;
      }
      return null;
    }

    final directory = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;

    for (final asset in ['aac_bursts_itunes.m4a', 'aac_bursts_ffmpeg.m4a']) {
      for (final (start, end) in [(null, null), (0.5, 1.5), (0.55, 1.95)]) {
        final outputPath =
            '${directory.path}/test_audio_bursts_${asset}_${start}_$ts.wav';
        await pve.extractAudioToFile(
          outputPath,
          AudioExtractConfigs(
            video: EditorVideo.asset('assets/tests/$asset'),
            format: AudioFormat.wav,
            startTime: start == null
                ? null
                : Duration(milliseconds: (start * 1000).round()),
            endTime: end == null
                ? null
                : Duration(milliseconds: (end * 1000).round()),
          ),
        );
        final file = File(outputPath);
        final pcm = Pcm.parseWav(await file.readAsBytes());
        await file.delete();

        final offset = start ?? 0;
        final reason = '$asset, range $start-$end';
        expect(
          pcm.seconds,
          closeTo((end ?? 2) - offset, 0.005),
          reason: '$reason: length',
        );
        final first = onsetAfter(pcm, 0);
        expect(first, isNotNull, reason: '$reason: first burst');
        expect(first! + offset, closeTo(0.6, 0.005), reason: reason);
        expect(
          onsetAfter(pcm, first + 0.3)! + offset,
          closeTo(1.2, 0.005),
          reason: reason,
        );
      }
    }
  }, skip: skipPlatform);
}
