import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Checks the fade a custom audio track gets in a real render: the output is
/// read back as PCM and its loudness at the edges compared with an unfaded
/// render of the same track, so the music's own dynamics cancel out.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isSupported =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  const window = Duration(seconds: 6);

  late String audioPath;
  final tempFiles = <String>[];

  setUp(() async {
    final bytes = await rootBundle.load(kVideoEditorExampleAudio1Path);
    final dir = await getTemporaryDirectory();
    audioPath =
        '${dir.path}/fade_source_${DateTime.now().microsecondsSinceEpoch}.mp3';
    await File(audioPath).writeAsBytes(bytes.buffer.asUint8List());
    tempFiles.add(audioPath);
  });

  tearDown(() async {
    for (final path in tempFiles) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  /// Renders the demo video with [fadeIn]/[fadeOut] on a track that plays a
  /// steady stretch of the demo song, and returns the output's audio.
  Future<_Pcm> renderTrack({
    Duration fadeIn = Duration.zero,
    Duration fadeOut = Duration.zero,
  }) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/fade_render_$stamp.mp4';
    final wavPath = '${dir.path}/fade_render_$stamp.wav';
    tempFiles.addAll([videoPath, wavPath]);

    await ProVideoEditor.instance.renderVideoToFile(
      videoPath,
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset(kVideoEditorExampleH264Path),
            endTime: window,
          ),
        ],
        enableAudio: false,
        audioTracks: [
          VideoAudioTrack(
            path: audioPath,
            // Four seconds in, the demo song holds a steady level.
            audioStartTime: const Duration(seconds: 4),
            startTime: Duration.zero,
            endTime: window,
            fadeInDuration: fadeIn,
            fadeOutDuration: fadeOut,
          ),
        ],
      ),
    );
    await ProVideoEditor.instance.extractAudioToFile(
      wavPath,
      AudioExtractConfigs(
        video: EditorVideo.file(videoPath),
        format: AudioFormat.wav,
      ),
    );
    return _Pcm.parseWav(await File(wavPath).readAsBytes());
  }

  testWidgets(
    'a faded track starts and ends near silence and is untouched between',
    (_) async {
      final plain = await renderTrack();
      final faded = await renderTrack(
        fadeIn: const Duration(seconds: 1),
        fadeOut: const Duration(seconds: 1),
      );

      double ratio(double from, double to) =>
          faded.rms(from, to) / plain.rms(from, to);

      // The plain render must actually carry sound where the fades are
      // measured, or the ratios below prove nothing.
      expect(plain.rms(0, 0.1), greaterThan(0.01));
      expect(plain.rms(5.85, 5.95), greaterThan(0.01));

      // Linear ramps: under a tenth of full level in the first 100 ms and in
      // the last 150 ms before the window ends, full level in the middle.
      expect(ratio(0, 0.1), lessThan(0.2));
      expect(ratio(0.45, 0.55), inInclusiveRange(0.35, 0.65));
      expect(ratio(2.5, 3.5), inInclusiveRange(0.9, 1.1));
      expect(ratio(5.85, 5.95), lessThan(0.25));
    },
    skip: !isSupported,
  );
}

/// Mono PCM read from a WAV file.
class _Pcm {
  _Pcm(this.samples, this.sampleRate);

  /// Reads 16-bit integer or 32-bit float PCM, averaging the channels.
  factory _Pcm.parseWav(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    int? format;
    var channels = 0;
    var sampleRate = 0;
    var bitsPerSample = 0;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final bytesPerSample = bitsPerSample ~/ 8;
        final end = math.min(body + size, bytes.length);
        final frames = (end - body) ~/ (bytesPerSample * channels);
        final samples = Float64List(frames);
        for (var f = 0; f < frames; f++) {
          var sum = 0.0;
          for (var c = 0; c < channels; c++) {
            final p = body + (f * channels + c) * bytesPerSample;
            sum += switch ((format, bitsPerSample)) {
              (3, 32) => data.getFloat32(p, Endian.little),
              (_, 16) => data.getInt16(p, Endian.little) / 32768,
              (_, 32) => data.getInt32(p, Endian.little) / 2147483648,
              _ => throw UnsupportedError('$bitsPerSample-bit PCM'),
            };
          }
          samples[f] = sum / channels;
        }
        return _Pcm(samples, sampleRate);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('WAV without a data chunk');
  }

  final Float64List samples;
  final int sampleRate;

  /// Root-mean-square level between [fromSec] and [toSec].
  double rms(double fromSec, double toSec) {
    final from = (fromSec * sampleRate).round().clamp(0, samples.length);
    final to = (toSec * sampleRate).round().clamp(from, samples.length);
    if (to <= from) return 0;
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += samples[i] * samples[i];
    }
    return math.sqrt(sum / (to - from));
  }
}
