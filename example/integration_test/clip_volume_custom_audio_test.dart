import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// Every volume in a render lands on the source it belongs to: a segment's
/// and a custom audio track's, however many sources are mixed. The output
/// audio is read back as PCM and its loudness compared between renders that
/// differ in one volume only.
///
/// Android used to assign volumes by the order Media3 registered the mixer's
/// sources, which is not guaranteed: identical renders came out with the
/// custom track's volume on the segment and the segment's on the track.
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
        '${dir.path}/mix_volume_${DateTime.now().microsecondsSinceEpoch}.mp3';
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

  VideoSegment segment({double? volume}) => VideoSegment(
    video: EditorVideo.asset(kVideoEditorExampleH264Path),
    endTime: window,
    volume: volume,
  );

  /// A custom track playing a steady stretch of the demo song at [volume].
  VideoAudioTrack track(double volume) => VideoAudioTrack(
    path: audioPath,
    volume: volume,
    audioStartTime: const Duration(seconds: 4),
    startTime: Duration.zero,
    endTime: window,
  );

  /// Renders [data] and returns the loudness of its audio between 1 s and 5 s.
  Future<double> loudness(VideoRenderData data) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/mix_volume_$stamp.mp4';
    final wavPath = '${dir.path}/mix_volume_$stamp.wav';
    tempFiles.addAll([videoPath, wavPath]);

    await ProVideoEditor.instance.renderVideoToFile(videoPath, data);
    await ProVideoEditor.instance.extractAudioToFile(
      wavPath,
      AudioExtractConfigs(
        video: EditorVideo.file(videoPath),
        format: AudioFormat.wav,
      ),
    );
    return Pcm.parseWav(await File(wavPath).readAsBytes()).rms(1, 5);
  }

  testWidgets('a segment keeps its volume with a custom track mixed in', (
    _,
  ) async {
    // The track is silent, so the output carries only the segment's audio.
    final full = await loudness(
      VideoRenderData(videoSegments: [segment()], audioTracks: [track(0)]),
    );
    final quiet = await loudness(
      VideoRenderData(
        videoSegments: [segment(volume: 0.3)],
        audioTracks: [track(0)],
      ),
    );
    expect(full, greaterThan(0.002), reason: 'the segment has no audio');
    expect(quiet / full, inInclusiveRange(0.25, 0.35));
  }, skip: !isSupported);

  testWidgets('a silent custom track stays silent under a muted segment', (
    _,
  ) async {
    final music = await loudness(
      VideoRenderData(
        videoSegments: [segment(volume: 0)],
        audioTracks: [track(1)],
      ),
    );
    final silent = await loudness(
      VideoRenderData(
        videoSegments: [segment(volume: 0)],
        audioTracks: [track(0)],
      ),
    );
    expect(music, greaterThan(0.01), reason: 'the track has no audio');
    expect(silent, lessThan(music * 0.01));
  }, skip: !isSupported);

  testWidgets(
    'a custom track keeps its volume and identical renders agree',
    (_) async {
      Future<double> music(double volume) => loudness(
        VideoRenderData(
          videoSegments: [segment(volume: 0)],
          audioTracks: [track(volume)],
        ),
      );
      final full = await music(1);
      final half = await music(0.5);
      final halfAgain = await music(0.5);
      expect(half / full, inInclusiveRange(0.45, 0.55));
      expect(halfAgain / half, inInclusiveRange(0.98, 1.02));
    },
    skip: !isSupported,
  );

  testWidgets('a custom track keeps its volume in a layered composition', (
    _,
  ) async {
    Future<double> music(double volume) => loudness(
      VideoRenderData(
        composition: VideoComposition(
          layers: [
            VideoLayer(clips: [segment(volume: 0)]),
          ],
        ),
        audioTracks: [track(volume)],
      ),
    );
    final full = await music(1);
    final half = await music(0.5);
    expect(full, greaterThan(0.01), reason: 'the track has no audio');
    expect(half / full, inInclusiveRange(0.45, 0.55));
  }, skip: !isSupported);
}
