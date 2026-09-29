import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

import 'utils/pcm.dart';

/// Checks where a custom audio track lands when the render itself is trimmed
/// (`VideoRenderData.startTime`/`endTime`): its own range and its fades count
/// from the trimmed start, on every platform and in both composition paths.
///
/// The track is a steady 440 Hz tone, so its level and pitch are known. A
/// quiet copy of it runs under the whole output as a reference: an exported
/// audio track that started with a gap would lose that gap when read back
/// as WAV, and every onset below would shift to zero.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isSupported =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  final demo = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// Level at which the tested tone counts as sounding. The tone alone
  /// measures ~0.35, the reference ~0.014.
  const audible = 0.1;

  /// Allowed error of a measured edge: a few 10 ms windows, the trim's frame
  /// compensation and the AAC encoder's priming delay.
  const edge = 0.1;

  late String tonePath;
  final tempFiles = <String>[];

  setUpAll(() async {
    final dir = await getTemporaryDirectory();
    tonePath =
        '${dir.path}/trim_tone_${DateTime.now().microsecondsSinceEpoch}.wav';
    await File(tonePath).writeAsBytes(Pcm.toneWav(seconds: 12));
  });

  tearDownAll(() async {
    try {
      await File(tonePath).delete();
    } catch (_) {}
  });

  tearDown(() async {
    for (final path in tempFiles) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  /// The quiet copy of the tone that fills the whole output.
  VideoAudioTrack reference() => VideoAudioTrack(path: tonePath, volume: 0.04);

  /// Renders [data] and returns the output's length and audio.
  Future<(Duration, Pcm)> render(VideoRenderData data) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final videoPath = '${dir.path}/trim_render_$stamp.mp4';
    final wavPath = '${dir.path}/trim_render_$stamp.wav';
    tempFiles.addAll([videoPath, wavPath]);

    await ProVideoEditor.instance.renderVideoToFile(videoPath, data);
    final meta = await ProVideoEditor.instance.getMetadata(
      EditorVideo.file(videoPath),
    );
    await ProVideoEditor.instance.extractAudioToFile(
      wavPath,
      AudioExtractConfigs(
        video: EditorVideo.file(videoPath),
        format: AudioFormat.wav,
      ),
    );
    return (meta.duration, Pcm.parseWav(await File(wavPath).readAsBytes()));
  }

  /// Expects the tone to sound from [start] to [end] seconds of the output.
  void expectToneAt(Pcm pcm, double start, double end) {
    final span = pcm.audibleSpan(audible);
    expect(span, isNotNull, reason: 'the tone never sounds');
    final (first, last) = span!;
    expect(first, closeTo(start, edge), reason: 'tone starts at ${first}s');
    expect(last, closeTo(end, edge), reason: 'tone ends at ${last}s');
  }

  testWidgets('a track counts its range from the trimmed start', (_) async {
    final (duration, pcm) = await render(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: demo, endTime: const Duration(seconds: 10)),
        ],
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 6),
        enableAudio: false,
        audioTracks: [
          reference(),
          VideoAudioTrack(
            path: tonePath,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
          ),
        ],
      ),
    );

    expect(duration.inMilliseconds / 1000, closeTo(4, 0.15));
    expectToneAt(pcm, 1, 3);
  }, skip: !isSupported);

  testWidgets('a track fades in and out at the trimmed edges', (_) async {
    final (_, pcm) = await render(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: demo, endTime: const Duration(seconds: 10)),
        ],
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 6),
        enableAudio: false,
        audioTracks: [
          VideoAudioTrack(
            path: tonePath,
            fadeInDuration: const Duration(seconds: 1),
            fadeOutDuration: const Duration(seconds: 1),
          ),
        ],
      ),
    );

    final full = pcm.rms(1.5, 2.5);
    final end = pcm.seconds;
    expect(full, greaterThan(0.25), reason: 'the tone must sound in between');

    // Linear ramps over the first and last second of the 4 s output: near
    // silence at both edges and half level half a second in. Before the fix,
    // iOS/macOS faded at the untrimmed edges, which the trim cut away.
    expect(pcm.rms(0, 0.1) / full, lessThan(0.2));
    expect(pcm.rms(0.45, 0.55) / full, inInclusiveRange(0.35, 0.65));
    expect(pcm.rms(end - 0.15, end - 0.05) / full, lessThan(0.25));
  }, skip: !isSupported);

  testWidgets('a sped-up segment is trimmed on its output', (_) async {
    // 12 s of source at 2x play for 6 s; the trim keeps output 1 s–5 s,
    // and the track keeps its own tempo.
    final (duration, pcm) = await render(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: demo,
            endTime: const Duration(seconds: 12),
            playbackSpeed: 2,
          ),
        ],
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 5),
        enableAudio: false,
        audioTracks: [
          reference(),
          VideoAudioTrack(
            path: tonePath,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
          ),
        ],
      ),
    );

    expect(duration.inMilliseconds / 1000, closeTo(4, 0.15));
    expectToneAt(pcm, 1, 3);
    expect(pcm.toneFrequency(1.5, 2.5), closeTo(440, 10));
  }, skip: !isSupported);

  testWidgets('a layered composition places the track the same way', (_) async {
    final (duration, pcm) = await render(
      VideoRenderData(
        composition: VideoComposition(
          layers: [
            VideoLayer(
              clips: [
                VideoSegment(video: demo, endTime: const Duration(seconds: 10)),
              ],
            ),
          ],
        ),
        startTime: const Duration(seconds: 2),
        endTime: const Duration(seconds: 6),
        enableAudio: false,
        audioTracks: [
          reference(),
          VideoAudioTrack(
            path: tonePath,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 3),
          ),
        ],
      ),
    );

    expect(duration.inMilliseconds / 1000, closeTo(4, 0.25));
    expectToneAt(pcm, 1, 3);
  }, skip: !isSupported);
}
