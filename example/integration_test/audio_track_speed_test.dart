import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final files = <File>[];
  final supported = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  tearDown(() async {
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    files.clear();
  });

  Future<File> tempFile(String suffix) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/audio_speed_${DateTime.now().microsecondsSinceEpoch}$suffix',
    );
    files.add(file);
    return file;
  }

  Future<Uint8List> render(double speed, {bool loop = false}) async {
    // Trim a two-second window from a longer stereo source. Each channel
    // carries a different pitch, so a mono downmix cannot pass the test.
    final left = Pcm.toneWav(seconds: 4);
    final right = Pcm.toneWav(seconds: 4, frequency: 660, amplitude: 0.25);
    final header = ByteData.sublistView(left);
    final frames = (left.length - 44) ~/ 2;
    final stereo = ByteData(44 + frames * 4);
    stereo.buffer.asUint8List().setRange(0, 44, left);
    stereo
      ..setUint32(4, 36 + frames * 4, Endian.little)
      ..setUint16(22, 2, Endian.little)
      ..setUint32(28, 44100 * 4, Endian.little)
      ..setUint16(32, 4, Endian.little)
      ..setUint32(40, frames * 4, Endian.little);
    final rightData = ByteData.sublistView(right);
    for (var frame = 0; frame < frames; frame++) {
      stereo
        ..setInt16(
          44 + frame * 4,
          header.getInt16(44 + frame * 2, Endian.little),
          Endian.little,
        )
        ..setInt16(
          46 + frame * 4,
          rightData.getInt16(44 + frame * 2, Endian.little),
          Endian.little,
        );
    }
    final audio = await tempFile('.wav');
    await audio.writeAsBytes(stereo.buffer.asUint8List());
    final video = await tempFile('.mp4');
    final wav = await tempFile('_result.wav');
    await ProVideoEditor.instance.renderVideoToFile(
      video.path,
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: EditorVideo.asset(kVideoEditorExampleH264Path),
            endTime: const Duration(seconds: 6),
          ),
        ],
        enableAudio: false,
        audioTracks: [
          VideoAudioTrack(
            path: audio.path,
            playbackSpeed: speed,
            loop: loop,
            audioStartTime: const Duration(seconds: 1),
            audioEndTime: const Duration(seconds: 3),
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 6),
            fadeInDuration: const Duration(milliseconds: 250),
            fadeOutDuration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
    await ProVideoEditor.instance.extractAudioToFile(
      wav.path,
      AudioExtractConfigs(
        video: EditorVideo.file(video.path),
        format: AudioFormat.wav,
      ),
    );
    return wav.readAsBytes();
  }

  for (final speed in [0.5, 2.0]) {
    testWidgets(
      'trimmed stereo at ${speed}x keeps pitch, placement and fades',
      (_) async {
        final bytes = await render(speed);
        final left = Pcm.parseWav(bytes, channel: 0);
        final right = Pcm.parseWav(bytes, channel: 1);
        final audibleEnd = 1 + 2 / speed;
        expect(left.seconds, closeTo(6, 0.1));
        expect(left.rms(0.2, 0.7), lessThan(0.01));
        expect(left.rms(1.3, 1.7), greaterThan(0.2));
        expect(left.toneFrequency(1.3, 1.7), closeTo(440, 8));
        expect(right.toneFrequency(1.3, 1.7), closeTo(660, 8));
        expect(right.rms(1.3, 1.7) / left.rms(1.3, 1.7), closeTo(0.5, 0.1));
        expect(left.rms(1, 1.04), lessThan(0.08));
        expect(left.rms(audibleEnd - 0.04, audibleEnd), lessThan(0.08));
        expect(left.rms(audibleEnd + 0.2, 5.8), lessThan(0.01));
      },
      skip: !supported,
    );
  }

  for (final speed in [0.5, 2.0]) {
    testWidgets(
      'a ${speed}x source loops without a gap before the output fade',
      (_) async {
        final bytes = await render(speed, loop: true);
        final pcm = Pcm.parseWav(bytes, channel: 0);
        final level = pcm.rms(3.3, 3.7);
        expect(level, greaterThan(0.2));
        expect(pcm.rms(5.3, 5.7), greaterThan(0.2));
        expect(pcm.toneFrequency(3.3, 3.7), closeTo(440, 8));
        expect(pcm.rms(5.96, 6), lessThan(0.08));
        // The two-second window is whole periods of its tone, so every seam
        // (each second from 2 s at 2x, at 5 s at 0.5x) plays on at full level.
        for (var t = 1.3; t < 5.7; t += 0.005) {
          expect(
            pcm.rms(t, t + 0.01),
            greaterThan(level * 0.7),
            reason: '$t s',
          );
        }
      },
      skip: !supported,
    );
  }
}
