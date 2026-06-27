import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final testVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// A H.264 video without any audio track.
  const mutedVideoPath = 'assets/demo_muted.mp4';

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  /// Waveform generation decodes the audio track natively and is only
  /// supported on Android, iOS, and macOS (same as audio extraction).
  final skipPlatform = kIsWeb || isWindows || isLinux;

  /// Asserts that every sample sits in the normalized `[0, 1]` range and that
  /// at least one peak is audibly above silence.
  void expectNormalized(Float32List channel, {required String reason}) {
    var maxPeak = 0.0;
    for (final value in channel) {
      expect(
        value,
        inInclusiveRange(0.0, 1.0),
        reason: '$reason: sample outside [0, 1]',
      );
      if (value > maxPeak) maxPeak = value;
    }
    expect(
      maxPeak,
      greaterThan(0.0),
      reason: '$reason: waveform is all silence',
    );
  }

  group('getWaveform', () {
    testWidgets('returns normalized peaks for an audio track', (tester) async {
      final configs = WaveformConfigs(video: testVideo);

      final waveform = await pve.getWaveform(configs);

      expect(waveform.sampleCount, greaterThan(0));
      expect(waveform.leftChannel, isNotEmpty);
      expect(
        waveform.samplesPerSecond,
        equals(WaveformResolution.medium.samplesPerSecond),
      );
      expect(waveform.duration.inSeconds, greaterThan(0));
      expect(waveform.sampleRate, greaterThan(0));
      expectNormalized(waveform.leftChannel, reason: 'leftChannel');

      /// The sample count should track duration × resolution closely.
      final expectedSamples =
          waveform.duration.inMilliseconds / 1000 * waveform.samplesPerSecond;
      expect(
        waveform.sampleCount,
        closeTo(expectedSamples, expectedSamples * 0.15),
        reason: 'sampleCount should match duration × samplesPerSecond',
      );
    }, skip: skipPlatform);

    testWidgets('higher resolution yields more samples', (tester) async {
      final low = await pve.getWaveform(
        WaveformConfigs(video: testVideo, resolution: WaveformResolution.low),
      );
      final high = await pve.getWaveform(
        WaveformConfigs(video: testVideo, resolution: WaveformResolution.high),
      );

      expect(low.samplesPerSecond, lessThan(high.samplesPerSecond));
      expect(
        high.sampleCount,
        greaterThan(low.sampleCount),
        reason: 'higher resolution must produce more samples',
      );
    }, skip: skipPlatform);

    testWidgets('time range produces a shorter waveform', (tester) async {
      final full = await pve.getWaveform(WaveformConfigs(video: testVideo));
      final ranged = await pve.getWaveform(
        WaveformConfigs(
          video: testVideo,
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 10),
        ),
      );

      expect(ranged.duration.inSeconds, closeTo(5, 1));
      expect(
        ranged.sampleCount,
        lessThan(full.sampleCount),
        reason: 'a 5s window must contain fewer samples than the full track',
      );
      expectNormalized(ranged.leftChannel, reason: 'ranged leftChannel');
    }, skip: skipPlatform);

    testWidgets('emits progress updates', (tester) async {
      final configs = WaveformConfigs(
        video: testVideo,
        resolution: WaveformResolution.high,
      );

      final progressValues = <double>[];
      final sub = pve
          .progressStreamById(configs.id)
          .listen((event) => progressValues.add(event.progress));

      await pve.getWaveform(configs);

      /// Give the stream time to flush the final value on iOS/macOS.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(
        progressValues,
        isNotEmpty,
        reason: 'no progress updates received',
      );
      expect(progressValues.first, lessThanOrEqualTo(0.1));
      expect(progressValues.last, closeTo(1.0, 0.05));

      final sorted = List.of(progressValues)..sort();
      expect(progressValues, sorted, reason: 'progress not monotonic');
    }, skip: skipPlatform);

    testWidgets('throws when the video has no audio track', (tester) async {
      final configs = WaveformConfigs(video: EditorVideo.asset(mutedVideoPath));

      await expectLater(
        pve.getWaveform(configs),
        throwsA(isA<AudioNoTrackException>()),
      );
    }, skip: skipPlatform);

    testWidgets('can be cancelled', (tester) async {
      final configs = WaveformConfigs(
        video: testVideo,
        resolution: WaveformResolution.ultra,
      );

      final future = pve.getWaveform(configs);
      final capturedError = future.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      try {
        await pve.cancel(configs.id);
      } on PlatformException catch (e) {
        if (e.code != 'TASK_NOT_FOUND') rethrow;
      }

      /// On fast machines generation may finish before the cancel lands; a
      /// cancelled run fails with [RenderCanceledException], a completed one
      /// resolves without error.
      final error = await capturedError;
      if (error != null) {
        expect(error, isA<RenderCanceledException>());
      }
    }, skip: skipPlatform);
  });

  group('getWaveformStream', () {
    testWidgets('streams chunks until completion', (tester) async {
      final configs = WaveformConfigs(
        video: testVideo,
        resolution: WaveformResolution.high,
        chunkSize: 100,
      );

      final chunks = <WaveformChunk>[];
      await for (final chunk in pve.getWaveformStream(configs)) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty, reason: 'no chunks emitted');
      expect(
        chunks.last.isComplete,
        isTrue,
        reason: 'final chunk not complete',
      );
      expect(chunks.last.progress, closeTo(1.0, 0.01));

      /// Progress must be non-decreasing across chunks.
      for (var i = 1; i < chunks.length; i++) {
        expect(
          chunks[i].progress,
          greaterThanOrEqualTo(chunks[i - 1].progress),
          reason: 'chunk progress went backwards',
        );
      }

      /// Non-final chunks must respect the configured chunk size.
      for (final chunk in chunks.take(chunks.length - 1)) {
        expect(chunk.sampleCount, lessThanOrEqualTo(configs.chunkSize));
        expectNormalized(chunk.leftChannel, reason: 'chunk leftChannel');
      }
    }, skip: skipPlatform);

    testWidgets('concatenated chunks match a single getWaveform', (
      tester,
    ) async {
      const resolution = WaveformResolution.medium;

      final single = await pve.getWaveform(
        WaveformConfigs(video: testVideo, resolution: resolution),
      );

      final streamConfig = WaveformConfigs(
        video: testVideo,
        resolution: resolution,
      );

      var streamedSamples = 0;
      await for (final chunk in pve.getWaveformStream(streamConfig)) {
        streamedSamples += chunk.sampleCount;
      }

      /// The streaming path can emit up to one extra trailing chunk relative to
      /// the one-shot total, so allow a full chunk of slack on top of a small
      /// relative tolerance.
      expect(
        streamedSamples,
        closeTo(
          single.sampleCount,
          single.sampleCount * 0.05 + streamConfig.chunkSize,
        ),
        reason: 'streamed sample count should match the one-shot waveform',
      );
    }, skip: skipPlatform);

    testWidgets('errors when the video has no audio track', (tester) async {
      final configs = WaveformConfigs(video: EditorVideo.asset(mutedVideoPath));

      /// The no-audio condition surfaces as [AudioNoTrackException] via the
      /// event channel, but may arrive as a raw [PlatformException] if the
      /// native side rejects the start call itself.
      await expectLater(
        pve.getWaveformStream(configs).toList(),
        throwsA(anyOf(isA<AudioNoTrackException>(), isA<PlatformException>())),
      );
    }, skip: skipPlatform);
  });
}
