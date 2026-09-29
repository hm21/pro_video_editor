import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

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
  Future<Pcm> renderTrack({
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
    return Pcm.parseWav(await File(wavPath).readAsBytes());
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

      // Linear ramps: near silence in the first 100 ms and 50–150 ms before
      // the window ends (~0.06 and ~0.1 of full level, with headroom for
      // the encoder), half level at 0.5 s, full level in the middle.
      expect(ratio(0, 0.1), lessThan(0.2));
      expect(ratio(0.45, 0.55), inInclusiveRange(0.35, 0.65));
      expect(ratio(2.5, 3.5), inInclusiveRange(0.9, 1.1));
      expect(ratio(5.85, 5.95), lessThan(0.25));
    },
    skip: !isSupported,
  );
}
