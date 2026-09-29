import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// A layered [VideoComposition] carries its layers' own audio, placed where
/// each layer plays and at each layer's volume. The output is read back as
/// PCM and its loudness compared with plain renders of the same source.
///
/// Android used to declare its layer sequences video-only, so a layered render
/// came out with no audio track at all.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isSupported =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  final demo = EditorVideo.asset(kVideoEditorExampleH264Path);
  // Stereo, unlike the demo's 5.1, which a layered render folds to stereo.
  final stereo = EditorVideo.asset('assets/tests/test_a.mp4');
  const window = Duration(seconds: 6);
  final tempFiles = <String>[];

  tearDown(() async {
    for (final path in tempFiles) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  /// Renders [data] and returns its audio.
  Future<Pcm> renderAudio(VideoRenderData data) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/layered_audio_$stamp.mp4';
    final wavPath = '${dir.path}/layered_audio_$stamp.wav';
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

  VideoRenderData layered(List<VideoLayer> layers) =>
      VideoRenderData(composition: VideoComposition(layers: layers));

  VideoLayer layer({
    double? volume,
    Duration? timelineStart,
    Duration endTime = window,
  }) => VideoLayer(
    clips: [
      VideoSegment(
        video: demo,
        endTime: endTime,
        volume: volume,
        timelineStart: timelineStart,
      ),
    ],
  );

  testWidgets('a layered composition carries its layer\'s audio', (_) async {
    final plain = await renderAudio(
      VideoRenderData(videoSegments: [VideoSegment(video: stereo)]),
    );
    final composed = await renderAudio(
      layered([
        VideoLayer(clips: [VideoSegment(video: stereo)]),
      ]),
    );

    expect(plain.rms(1, 4.5), greaterThan(0.002), reason: 'no source audio');
    expect(
      composed.rms(1, 4.5) / plain.rms(1, 4.5),
      inInclusiveRange(0.8, 1.25),
    );
  }, skip: !isSupported);

  testWidgets('a layer keeps its volume', (_) async {
    final full = await renderAudio(layered([layer()]));
    final quiet = await renderAudio(layered([layer(volume: 0.3)]));

    expect(quiet.rms(1, 5) / full.rms(1, 5), inInclusiveRange(0.25, 0.35));
  }, skip: !isSupported);

  testWidgets(
    'a muted layer beside an audible one renders only the audible one',
    (_) async {
      final one = await renderAudio(layered([layer()]));
      final withMuted = await renderAudio(layered([layer(volume: 0), layer()]));

      expect(withMuted.rms(1, 5) / one.rms(1, 5), inInclusiveRange(0.8, 1.25));
    },
    skip: !isSupported,
  );

  testWidgets('a layer\'s audio starts where the layer does', (_) async {
    // A muted full-length base, and an audible 3 s layer entering at 2 s.
    final pcm = await renderAudio(
      layered([
        layer(volume: 0),
        layer(
          timelineStart: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
        ),
      ]),
    );

    final inside = pcm.rms(2.5, 4.5);
    expect(inside, greaterThan(0.002), reason: 'the layer is silent');
    expect(pcm.rms(0.2, 1.8), lessThan(inside * 0.05));
    expect(pcm.rms(5.3, 5.9), lessThan(inside * 0.05));
  }, skip: !isSupported);

  testWidgets('a global trim moves a layer\'s audio with it', (_) async {
    // The audible layer plays 3 s to 5 s; trimming the first 2 s moves it to
    // 1 s to 3 s of the output.
    final pcm = await renderAudio(
      VideoRenderData(
        composition: VideoComposition(
          layers: [
            layer(volume: 0),
            layer(
              timelineStart: const Duration(seconds: 3),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
        startTime: const Duration(seconds: 2),
      ),
    );

    final inside = pcm.rms(1.3, 2.7);
    expect(inside, greaterThan(0.002), reason: 'the layer is silent');
    expect(pcm.rms(0.1, 0.8), lessThan(inside * 0.05));
    expect(pcm.rms(3.3, 3.9), lessThan(inside * 0.05));
  }, skip: !isSupported);

  testWidgets('a layer\'s second clip plays its own source range', (_) async {
    // A muted 2 s clip, then 4 s to 6 s of the source.
    final pcm = await renderAudio(
      layered([
        VideoLayer(
          clips: [
            VideoSegment(
              video: demo,
              endTime: const Duration(seconds: 2),
              volume: 0,
            ),
            VideoSegment(
              video: demo,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      ]),
    );
    final alone = await renderAudio(
      layered([
        VideoLayer(
          clips: [
            VideoSegment(
              video: demo,
              startTime: const Duration(seconds: 4),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      ]),
    );

    final second = pcm.rms(2.2, 3.8);
    expect(second, greaterThan(0.002), reason: 'the second clip is silent');
    expect(pcm.rms(0.2, 1.8), lessThan(second * 0.05));
    expect(second / alone.rms(0.2, 1.8), inInclusiveRange(0.8, 1.25));
  }, skip: !isSupported);

  testWidgets('a surround layer mixes with a stereo one', (_) async {
    // The demo's audio is 5.1; the world clip's is stereo.
    final pcm = await renderAudio(
      layered([
        layer(),
        VideoLayer(
          clips: [
            VideoSegment(
              video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
              endTime: window,
            ),
          ],
        ),
      ]),
    );

    expect(pcm.rms(1, 5), greaterThan(0.002));
  }, skip: !isSupported);
}
