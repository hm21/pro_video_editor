import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// Ducks a steady tone under a voice that talks from 2 s to 3.5 s: the curve
/// comes from measuring the voice file, and a real render of the tone with
/// that curve is read back as PCM and compared with a render without it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isSupported =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  const window = Duration(seconds: 6);
  const ducking = AudioDucking(
    volume: 0.25,
    attack: Duration(milliseconds: 250),
    release: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 400),
  );

  final tempFiles = <String>[];

  tearDown(() async {
    for (final path in tempFiles) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  Future<String> writeTemp(String name, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/ducking_${name}_${DateTime.now().microsecondsSinceEpoch}'
        '.wav';
    await File(path).writeAsBytes(bytes);
    tempFiles.add(path);
    return path;
  }

  /// Renders the demo video with only [music] as its sound and returns it.
  Future<Pcm> render(VideoAudioTrack music) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/ducking_render_$stamp.mp4';
    final wavPath = '${dir.path}/ducking_render_$stamp.wav';
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
        audioTracks: [music],
      ),
    );
    await ProVideoEditor.instance.extractAudioToFile(
      wavPath,
      AudioExtractConfigs(
        video: EditorVideo.file(videoPath),
        format: AudioFormat.wav,
      ),
    );
    return Pcm.parseWav(await File(wavPath).readAsBytes());
  }

  testWidgets(
    'music goes down while the voice talks and back up after it',
    (_) async {
      final voicePath = await writeTemp(
        'voice',
        Pcm.toneWav(seconds: 3, frequency: 1000, bursts: [(1, 2.5)]),
      );
      final musicPath = await writeTemp(
        'music',
        Pcm.toneWav(seconds: 6, frequency: 220, amplitude: 0.4),
      );

      // The voice file talks from 1 s to 2.5 s and is placed 1 s in.
      final curve = await ducking.analyze([
        VideoAudioTrack(path: voicePath, startTime: const Duration(seconds: 1)),
      ], videoDuration: window);
      expect(curve.points, isNotEmpty);
      // Down by the time the voice starts, up again after hold and release.
      expect(curve.volumeAt(const Duration(milliseconds: 1700)), 1);
      expect(curve.volumeAt(const Duration(milliseconds: 2010)), 0.25);
      expect(curve.volumeAt(const Duration(milliseconds: 3800)), 0.25);
      expect(curve.volumeAt(const Duration(milliseconds: 4500)), 1);

      // The music starts 1 s in too, so the curve has to be read on the
      // video's timeline, not the track's.
      final music = VideoAudioTrack(
        path: musicPath,
        startTime: const Duration(seconds: 1),
        endTime: window,
      );
      final plain = await render(music);
      final ducked = await render(music.copyWith(volumeCurve: curve));

      double ratio(double from, double to) =>
          ducked.rms(from, to) / plain.rms(from, to);

      expect(plain.rms(2.2, 3.7), greaterThan(0.1));
      expect(ratio(1.2, 1.6), inInclusiveRange(0.9, 1.1));
      // Halfway down the attack.
      expect(ratio(1.85, 1.9), inInclusiveRange(0.5, 0.75));
      expect(ratio(2.2, 3.7), inInclusiveRange(0.2, 0.3));
      expect(ratio(4.6, 5.5), inInclusiveRange(0.9, 1.1));
    },
    skip: !isSupported,
  );

  testWidgets('a long 44.1 kHz voice-over is measured on time', (_) async {
    // 220.5 frames per waveform point: rounded down to 220, the points
    // ran 65 ms late by 30 s.
    final voicePath = await writeTemp(
      'long_voice',
      Pcm.toneWav(seconds: 32, frequency: 1000, bursts: [(30, 31)]),
    );

    final curve = await ducking.analyze([VideoAudioTrack(path: voicePath)]);
    expect(curve.volumeAt(const Duration(milliseconds: 29740)), 1);
    expect(curve.volumeAt(const Duration(seconds: 30)), 0.25);
  }, skip: !isSupported);
}
