import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Minimal parsed WAV header used to verify the merged output's format and to
/// cross-check the returned offset map against the actual PCM in the file.
class _WavInfo {
  const _WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataBytes;

  Duration get duration {
    final bytesPerFrame = channels * (bitsPerSample ~/ 8);
    if (bytesPerFrame == 0 || sampleRate == 0) return Duration.zero;
    final frames = dataBytes ~/ bytesPerFrame;
    return Duration(microseconds: (frames * 1000000 / sampleRate).round());
  }
}

/// Parses a canonical PCM WAV file by walking its RIFF chunks.
_WavInfo _readWav(File file) {
  final bytes = file.readAsBytesSync();
  final data = ByteData.sublistView(bytes);

  String tag(int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));

  expect(tag(0), 'RIFF', reason: 'not a RIFF file');
  expect(tag(8), 'WAVE', reason: 'not a WAVE file');

  var sampleRate = 0;
  var channels = 0;
  var bitsPerSample = 0;
  var dataBytes = 0;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = tag(offset);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (chunkId == 'fmt ') {
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
    } else if (chunkId == 'data') {
      dataBytes = chunkSize;
    }
    // Chunks are word-aligned.
    offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  return _WavInfo(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
    dataBytes: dataBytes,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final audioVideo = EditorVideo.asset(kVideoEditorExampleH264Path);
  final mutedVideo = EditorVideo.asset('assets/demo_muted.mp4');

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;
  // Audio merge is supported on Android, iOS, and macOS only.
  final skipPlatform = kIsWeb || isWindows || isLinux;

  Future<String> tempPath(String label) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/merge_${label}_$ts.wav';
  }

  testWidgets('two clips: total == d1 + d2 and offsets are [0, d1]', (
    tester,
  ) async {
    final out = await tempPath('two');
    final result = await pve.mergeAudioToFile(
      out,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(
            video: audioVideo,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
          ),
          AudioMergeSegment(
            video: audioVideo,
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 8),
          ),
        ],
      ),
    );

    expect(result.outputPath, out);
    expect(result.segments, hasLength(2));

    final d0 = result.segments[0].outputDuration;
    final d1 = result.segments[1].outputDuration;

    // No gaps: segment 1 starts exactly where segment 0 ends.
    expect(result.segments[0].outputStart, Duration.zero);
    expect(result.segments[1].outputStart, d0);
    // Total is the sum of the segment durations.
    expect(result.totalDuration, d0 + d1);

    // The offset map matches the actual PCM written to disk.
    final wav = _readWav(File(out));
    expect(
      wav.duration.inMilliseconds,
      closeTo(result.totalDuration.inMilliseconds, 5),
    );

    // The windows are ~2s and ~3s, not the full ~29.5s source.
    expect(d0.inMilliseconds, closeTo(2000, 120));
    expect(d1.inMilliseconds, closeTo(3000, 120));

    await File(out).delete();
  }, skip: skipPlatform);

  testWidgets('trim is respected (2s window of a long source)', (tester) async {
    final out = await tempPath('trim');
    final result = await pve.mergeAudioToFile(
      out,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(
            video: audioVideo,
            startTime: const Duration(seconds: 2),
            endTime: const Duration(seconds: 4),
          ),
        ],
        // Explicit format avoids the single-segment parity fast path so the
        // general trim pipeline is exercised.
        sampleRate: 44100,
        channels: 2,
      ),
    );

    expect(
      result.totalDuration.inMilliseconds,
      closeTo(2000, 120),
      reason: 'a 2s window must contribute ~2s, not the full source',
    );

    await File(out).delete();
  }, skip: skipPlatform);

  testWidgets('speed 2x halves a segment output duration', (tester) async {
    final normalPath = await tempPath('spd1x');
    final fastPath = await tempPath('spd2x');

    final normal = await pve.mergeAudioToFile(
      normalPath,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(
            video: audioVideo,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 4),
          ),
        ],
        sampleRate: 44100,
        channels: 2,
      ),
    );
    final fast = await pve.mergeAudioToFile(
      fastPath,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(
            video: audioVideo,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 4),
            speed: 2.0,
          ),
        ],
        sampleRate: 44100,
        channels: 2,
      ),
    );

    final normalMs = normal.totalDuration.inMilliseconds;
    final fastMs = fast.totalDuration.inMilliseconds;
    expect(fastMs, closeTo(normalMs / 2, 150));

    await File(normalPath).delete();
    await File(fastPath).delete();
  }, skip: skipPlatform);

  testWidgets(
    'silent clip contributes silence and keeps offsets aligned',
    (tester) async {
      final out = await tempPath('silent');
      final result = await pve.mergeAudioToFile(
        out,
        AudioMergeConfigs(
          segments: [
            AudioMergeSegment(
              video: audioVideo,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
            ),
            AudioMergeSegment(
              video: mutedVideo, // no audio track -> silence
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );

      expect(result.segments, hasLength(2));
      // The silent clip still contributes its full ~2s output length.
      expect(
        result.segments[1].outputDuration.inMilliseconds,
        closeTo(2000, 30),
      );
      // And it is placed right after the audio clip, with no gap.
      expect(result.segments[1].outputStart, result.segments[0].outputDuration);
      expect(
        result.totalDuration,
        result.segments[0].outputDuration + result.segments[1].outputDuration,
      );

      await File(out).delete();
    },
    skip: skipPlatform,
  );

  testWidgets('output adopts the requested sample rate and channels', (
    tester,
  ) async {
    final out = await tempPath('fmt');
    await pve.mergeAudioToFile(
      out,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(
            video: audioVideo,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 3),
          ),
        ],
        sampleRate: 16000,
        channels: 1,
      ),
    );

    final wav = _readWav(File(out));
    expect(wav.sampleRate, 16000);
    expect(wav.channels, 1);
    expect(wav.bitsPerSample, 16);

    await File(out).delete();
  }, skip: skipPlatform);

  testWidgets('single-segment merge is byte-for-byte equal to extract', (
    tester,
  ) async {
    final extractPath = await tempPath('extract');
    final mergePath = await tempPath('merge');

    const start = Duration(seconds: 2);
    const end = Duration(seconds: 7);

    await pve.extractAudioToFile(
      extractPath,
      AudioExtractConfigs(
        video: audioVideo,
        format: AudioFormat.wav,
        startTime: start,
        endTime: end,
      ),
    );

    await pve.mergeAudioToFile(
      mergePath,
      AudioMergeConfigs(
        segments: [
          AudioMergeSegment(video: audioVideo, startTime: start, endTime: end),
        ],
        // Default format (no explicit sampleRate/channels) -> parity fast path.
      ),
    );

    final extractBytes = await File(extractPath).readAsBytes();
    final mergeBytes = await File(mergePath).readAsBytes();

    expect(
      mergeBytes.length,
      extractBytes.length,
      reason: 'merge output length must match extract output',
    );
    expect(
      _bytesEqual(mergeBytes, extractBytes),
      isTrue,
      reason: 'single-segment merge must be byte-for-byte equal to extract',
    );

    await File(extractPath).delete();
    await File(mergePath).delete();
  }, skip: skipPlatform);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
