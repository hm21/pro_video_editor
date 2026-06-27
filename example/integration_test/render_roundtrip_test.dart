import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final audioVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// A H.264 video without any audio track.
  const mutedVideoPath = 'assets/demo_muted.mp4';

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  /// Rendering is not available on web.
  const skipRender = kIsWeb;

  /// `hasAudioTrack` is only implemented on Android, iOS, and macOS.
  final skipAudioTrack = kIsWeb || isWindows || isLinux;

  bool hasAudio(VideoMetadata meta) =>
      meta.audioDuration != null && meta.audioDuration != Duration.zero;

  /// Renders [model] and returns the metadata of the encoded result.
  Future<VideoMetadata> renderAndRead(VideoRenderData model) async {
    final bytes = await pve.renderVideo(model);
    expect(bytes.lengthInBytes, greaterThan(10000));
    return pve.getMetadata(EditorVideo.memory(bytes));
  }

  group('Audio presence after render', () {
    testWidgets('enableAudio:false strips the audio track', (tester) async {
      final meta = await renderAndRead(
        VideoRenderData(
          videoSegments: [VideoSegment(video: audioVideo)],
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
        ),
      );

      expect(
        hasAudio(meta),
        isFalse,
        reason: 'enableAudio:false must produce a silent output',
      );
    }, skip: skipRender);

    testWidgets('enableAudio:false output reports hasAudioTrack false', (
      tester,
    ) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: audioVideo)],
          outputFormat: VideoOutputFormat.mp4,
          enableAudio: false,
        ),
      );

      final result = await pve.hasAudioTrack(EditorVideo.memory(bytes));
      expect(result, isFalse);
    }, skip: skipAudioTrack);

    testWidgets('default render keeps the audio track', (tester) async {
      final meta = await renderAndRead(
        VideoRenderData(
          videoSegments: [VideoSegment(video: audioVideo)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      expect(
        hasAudio(meta),
        isTrue,
        reason: 'a default render of an audio video must retain audio',
      );
    }, skip: skipRender);

    testWidgets('merging audio + silent video keeps audio', (tester) async {
      final meta = await renderAndRead(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: audioVideo),
            VideoSegment(video: EditorVideo.asset(mutedVideoPath)),
          ],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      expect(hasAudio(meta), isTrue);
    }, skip: skipRender);
  });

  group('Quality presets', () {
    testWidgets('lower preset yields a lower output bitrate', (tester) async {
      final low = await renderAndRead(
        VideoRenderData.withQualityPreset(
          videoSegments: [VideoSegment(video: audioVideo)],
          qualityPreset: VideoQualityPreset.low,
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      final high = await renderAndRead(
        VideoRenderData.withQualityPreset(
          videoSegments: [VideoSegment(video: audioVideo)],
          qualityPreset: VideoQualityPreset.p720,
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      expect(
        low.bitrate,
        lessThan(high.bitrate),
        reason: 'the low preset must encode at a lower bitrate than p720',
      );
    }, skip: skipRender);

    testWidgets('output bitrate tracks the preset target', (tester) async {
      const preset = VideoQualityPreset.p480; // 2.5 Mbps target
      const tolerance = 0.5; // ±50% — encoders rarely hit CBR exactly

      final meta = await renderAndRead(
        VideoRenderData.withQualityPreset(
          videoSegments: [VideoSegment(video: audioVideo)],
          qualityPreset: preset,
          outputFormat: VideoOutputFormat.mp4,
        ),
      );

      expect(
        meta.bitrate,
        inInclusiveRange(
          preset.bitrate * (1 - tolerance),
          preset.bitrate * (1 + tolerance),
        ),
        reason: 'output bitrate ${meta.bitrate} drifted from the preset target',
      );
    }, skip: skipRender);
  });
}
