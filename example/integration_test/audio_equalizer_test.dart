import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// An equalizer band changes the level of its own part of the frequency range
/// and nothing else, on a custom track and on a segment's own audio, and a
/// boost on loud material is limited instead of clipped.
///
/// The track plays a generated 60 Hz tone, so its level after each band is
/// known exactly: +6 dB below the 200 Hz low shelf or at the center of a peak
/// doubles it, -12 dB leaves a quarter, and the 3 kHz high shelf leaves it
/// alone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isSupported =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  const window = Duration(seconds: 6);

  AudioEqualizer equalizer(
    AudioEqualizerBandType type,
    double frequency,
    double gain,
  ) => AudioEqualizer(
    bands: [AudioEqualizerBand(type: type, frequency: frequency, gain: gain)],
  );
  AudioEqualizer bass(double gain) =>
      equalizer(AudioEqualizerBandType.lowShelf, 200, gain);

  final tempFiles = <String>[];

  tearDown(() async {
    for (final path in tempFiles) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  /// Writes a 16-bit stereo WAV of a 60 Hz tone at [amplitude], 8 s long.
  Future<String> tone({required double amplitude}) async {
    const sampleRate = 44100;
    const frames = sampleRate * 8;
    final data = ByteData(44 + frames * 4);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + frames * 4, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 2, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * 4, Endian.little)
      ..setUint16(32, 4, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, frames * 4, Endian.little);
    for (var f = 0; f < frames; f++) {
      final sample =
          (amplitude * 32767 * math.sin(2 * math.pi * 60 * f / sampleRate))
              .round();
      data
        ..setInt16(44 + f * 4, sample, Endian.little)
        ..setInt16(46 + f * 4, sample, Endian.little);
    }
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final path = '${dir.path}/equalizer_tone_$stamp.wav';
    await File(path).writeAsBytes(data.buffer.asUint8List());
    tempFiles.add(path);
    return path;
  }

  /// Renders [data] and returns its audio.
  Future<Pcm> render(VideoRenderData data) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/equalizer_$stamp.mp4';
    final wavPath = '${dir.path}/equalizer_$stamp.wav';
    tempFiles.addAll([videoPath, wavPath]);

    await ProVideoEditor.instance.renderVideoToFile(videoPath, data);
    await ProVideoEditor.instance.extractAudioToFile(
      wavPath,
      AudioExtractConfigs(
        video: EditorVideo.file(videoPath),
        format: AudioFormat.wav,
      ),
    );
    return Pcm.parseWav(await File(wavPath).readAsBytes());
  }

  VideoRenderData mutedVideoWith(VideoAudioTrack track) => VideoRenderData(
    videoSegments: [
      VideoSegment(
        video: EditorVideo.asset(kVideoEditorExampleH264Path),
        endTime: window,
        volume: 0,
      ),
    ],
    audioTracks: [track],
  );

  testWidgets('a track equalizer changes only the range of its band', (
    _,
  ) async {
    final path = await tone(amplitude: 0.2);
    Future<double> level(AudioEqualizer? equalizer) async => (await render(
      mutedVideoWith(
        VideoAudioTrack(
          path: path,
          equalizer: equalizer,
          startTime: Duration.zero,
          endTime: window,
        ),
      ),
    )).rms(1, 5);

    final flat = await level(null);
    final bassUp = await level(bass(6));
    final bassDown = await level(bass(-12));
    final trebleUp = await level(
      equalizer(AudioEqualizerBandType.highShelf, 3000, 12),
    );
    final peakUp = await level(equalizer(AudioEqualizerBandType.peak, 60, 6));

    expect(flat, greaterThan(0.01), reason: 'the tone did not render');
    // A 60 Hz tone through the 200 Hz shelf: x1.98 at +6 dB, x0.255 at -12.
    expect(bassUp / flat, inInclusiveRange(1.85, 2.1));
    expect(bassDown / flat, inInclusiveRange(0.22, 0.29));
    expect(trebleUp / flat, inInclusiveRange(0.95, 1.05));
    // At the center of a peak, all of its gain: x1.995 at +6 dB.
    expect(peakUp / flat, inInclusiveRange(1.85, 2.1));
  }, skip: !isSupported);

  testWidgets('a bass boost on a loud track is limited, not clipped', (
    _,
  ) async {
    final path = await tone(amplitude: 0.8);
    Future<double> peak(AudioEqualizer? equalizer) async {
      final pcm = await render(
        mutedVideoWith(
          VideoAudioTrack(
            path: path,
            equalizer: equalizer,
            startTime: Duration.zero,
            endTime: window,
          ),
        ),
      );
      var peak = 0.0;
      final to = math.min(pcm.samples.length, pcm.sampleRate * 5);
      for (var i = pcm.sampleRate; i < to; i++) {
        peak = math.max(peak, pcm.samples[i].abs());
      }
      return peak;
    }

    final flat = await peak(null);
    final boosted = await peak(bass(12));

    // Unlimited, +12 dB at 60 Hz would multiply the 0.8 tone by 3.92. The
    // limiter holds it at -1 dBFS instead: 0.891 / 0.8 = 1.11 times the flat
    // peak, plus the few percent AAC overshoots a limited peak by.
    expect(boosted / flat, inInclusiveRange(1.0, 1.2));
  }, skip: !isSupported);

  testWidgets('a segment equalizer changes the segment\'s own audio', (
    _,
  ) async {
    Future<double> level(AudioEqualizer? equalizer) async => (await render(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset(kVideoEditorExampleH264Path),
            endTime: window,
            equalizer: equalizer,
          ),
        ],
      ),
    )).rms(1, 5);

    const cutBoth = AudioEqualizer(
      bands: [
        AudioEqualizerBand(
          type: AudioEqualizerBandType.lowShelf,
          frequency: 200,
          gain: -12,
        ),
        AudioEqualizerBand(
          type: AudioEqualizerBandType.highShelf,
          frequency: 3000,
          gain: -12,
        ),
      ],
    );
    final flat = await level(null);
    final cut = await level(cutBoth);
    final again = await level(cutBoth);

    expect(flat, greaterThan(0.002), reason: 'the segment has no audio');
    expect(cut / flat, lessThan(0.9));
    expect(again / cut, inInclusiveRange(0.98, 1.02));
  }, skip: !isSupported);
}
