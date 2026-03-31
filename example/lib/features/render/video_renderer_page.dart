import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';

import '/core/constants/example_constants.dart';
import '/core/constants/example_filters.dart';
import '/shared/utils/bytes_formatter.dart';
import '/shared/widgets/filter_generator.dart';

/// A page that handles the video export workflow.
///
/// This widget provides the UI and logic for exporting a video using the
/// selected settings.
class VideoRendererPage extends StatefulWidget {
  /// Creates a [VideoRendererPage].
  const VideoRendererPage({super.key});

  @override
  State<VideoRendererPage> createState() => _VideoRendererPageState();
}

class _VideoRendererPageState extends State<VideoRendererPage> {
  final _pve = ProVideoEditor.instance;

  late final _playerContent = Player();
  late final _controllerContent = VideoController(_playerContent);
  late final _playerPreview = Player();
  late final _controllerPreview = VideoController(_playerPreview);

  final _boundaryKey = GlobalKey();
  bool _isExporting = false;
  Uint8List? _videoBytes;

  Duration _generationTime = Duration.zero;

  final double _blurFactor = 0;
  final List<List<double>> _colorFilters = [];

  // kBasicFilterMatrix   kComplexFilterMatrix

  VideoMetadata? _outputMetadata;

  String _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  late final EditorVideo _video;

  bool get _supportsCancel => canCancelOnCurrentPlatform();

  @override
  void initState() {
    super.initState();
    _playerContent.open(
      Media('asset:///$kVideoEditorExampleH264Path'),
      play: false,
    );
    _video = EditorVideo.asset(kVideoEditorExampleH264Path);
  }

  @override
  void dispose() {
    _playerContent.dispose();
    _playerPreview.dispose();
    super.dispose();
  }

  Future<void> _rotate() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      transform: const ExportTransform(rotateTurns: 1),
    );

    await _renderVideo(data);
  }

  Future<void> _flip() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      transform: const ExportTransform(flipX: true),
    );

    await _renderVideo(data);
  }

  Future<void> _crop() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      transform: const ExportTransform(x: 100, y: 250, width: 700, height: 300),
    );

    await _renderVideo(data);
  }

  Future<void> _scale() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      transform: const ExportTransform(scaleX: 0.2, scaleY: 0.2),
    );

    await _renderVideo(data);
  }

  Future<void> _trim() async {
    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 7),
          endTime: const Duration(seconds: 20),
        ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _changeSpeed() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      playbackSpeed: .5,
    );

    await _renderVideo(data);
  }

  Future<void> _removeAudio() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      enableAudio: false,
    );

    await _renderVideo(data);
  }

  Future<File> _writeAssetAudioToFile(String assetPath) async {
    final ByteData data = await rootBundle.load(assetPath);
    final buffer = data.buffer;

    final directory = await getTemporaryDirectory();

    // Ensure directory exists
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    // Extract just the filename from the asset path
    final fileName = assetPath.split('/').last;
    final file = File('${directory.path}/$fileName');

    // Ensure parent directory exists
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    await file.writeAsBytes(
      buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );

    // Verify the file was written successfully
    if (!await file.exists()) {
      throw Exception('Failed to write audio file to: ${file.path}');
    }
    debugPrint('Audio file written to: ${file.path}');

    return file;
  }

  /// Replace original audio with custom audio track.
  ///
  /// This example demonstrates how to replace the video's original audio
  /// with a custom audio track from an asset file.
  ///
  /// The asset audio is first loaded and saved to a temporary file,
  /// then the native code can access it via the file path.
  Future<void> _customAudioReplace() async {
    final customAudioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          volume: 0.0, // Mute original audio
        ),
      ],
      audioTracks: [
        VideoAudioTrack(
          path: customAudioFile.path,
          volume: 1, // Full volume for custom audio
          loop: true,
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Mix original audio with background music.
  ///
  /// This example shows how to blend the video's original audio with
  /// a custom background music track at different volume levels.
  ///
  /// The asset audio is first loaded and saved to a temporary file,
  /// then mixed with the original video audio during export.
  Future<void> _customAudioMix() async {
    final customAudioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video, volume: 0.9)],
      audioTracks: [
        VideoAudioTrack(path: customAudioFile.path, volume: 0.1, loop: true),
      ],
    );

    await _renderVideo(data);
  }

  /// Adjust the volume of the original video audio.
  ///
  /// This example demonstrates how to reduce or amplify the video's
  /// original audio without adding any custom audio track.
  ///
  /// **Volume Range:**
  /// - `0.0`: Completely muted
  /// - `0.5`: Half volume (50%)
  /// - `1.0`: Original volume (100%)
  /// - `1.5`: Amplified by 50%
  /// - `2.0`: Doubled volume
  Future<void> _adjustOriginalVolume() async {
    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          volume: 0.2, // Reduce to 20%
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Play custom audio once without looping.
  ///
  /// By default, custom audio loops to match the video duration.
  /// Setting `loopCustomAudio: false` plays the audio only once,
  /// with silence for the remaining video duration.
  Future<void> _customAudioNoLoop() async {
    final customAudioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video, volume: 0)],
      audioTracks: [
        VideoAudioTrack(path: customAudioFile.path, volume: 1.0, loop: false),
      ],
    );

    await _renderVideo(data);
  }

  /// Start custom audio from a specific offset.
  ///
  /// This example demonstrates how to use `customAudioStartTime` to start
  /// playing the custom audio from a specific position instead of from the
  /// beginning. This is useful for using a specific section of a longer
  /// audio file.
  Future<void> _customAudioStartOffset() async {
    final customAudioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video, volume: 0)],
      audioTracks: [
        VideoAudioTrack(
          path: customAudioFile.path,
          startTime: const Duration(seconds: 5),
          volume: 1.0,
          loop: false,
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Mix multiple audio tracks at different time ranges.
  ///
  /// This example demonstrates timed audio mixing:
  /// - Audio track 1 plays from 0–10 seconds
  /// - Audio track 2 plays from 10–20 seconds
  /// - Both overlap for a brief transition
  Future<void> _timedAudioTracks() async {
    final audioFile1 = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );
    final audioFile2 = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio2Path,
    );

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video, volume: 0.3)],
      audioTracks: [
        VideoAudioTrack(
          path: audioFile1.path,
          volume: 0.8,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 10),
        ),
        VideoAudioTrack(
          path: audioFile2.path,
          volume: 0.8,
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 20),
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Use audioStartTime and audioEndTime to select a specific portion of
  /// an audio file.
  ///
  /// This example demonstrates extracting a section from within the audio
  /// file itself (5s–15s of the audio) and placing it at a specific position
  /// in the video timeline (starting at 3s).
  Future<void> _audioClipRange() async {
    final customAudioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video, volume: 0)],
      audioTracks: [
        VideoAudioTrack(
          path: customAudioFile.path,
          volume: 1.0,
          audioStartTime: const Duration(seconds: 3),
          audioEndTime: const Duration(seconds: 8),
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Different volume levels per video segment.
  ///
  /// This example demonstrates per-clip volume control when concatenating
  /// multiple video clips:
  /// - Clip 1: Original audio at 100%
  /// - Clip 2: Muted (0%)
  /// - Clip 3: Reduced to 30%
  Future<void> _perClipVolume() async {
    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 0),
          endTime: const Duration(seconds: 7),
          volume: 1.0,
        ),
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 7),
          endTime: const Duration(seconds: 14),
          volume: 0.0,
        ),
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 14),
          endTime: const Duration(seconds: 21),
          volume: 0.3,
        ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _layers() async {
    final imageBytes = await _captureLayerContent();
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [ImageLayer(image: EditorLayerImage.memory(imageBytes))],
    );

    await _renderVideo(data);
  }

  Future<void> _layersTimed() async {
    final metadata = await _pve.getMetadata(_video);

    final layerImage = EditorLayerImage.asset('assets/sticker.png');

    final rng = Random();
    const stickerSize = 256;
    const videoWidth = 1280;
    const videoHeight = 720;

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [
        /// Always visible — positioned at top-left
        ImageLayer(image: layerImage, offset: const Offset(0, 0)),

        /// Start at 5s
        ImageLayer(
          image: layerImage,
          startTime: const Duration(seconds: 5),
          offset: Offset((videoWidth - stickerSize).toDouble(), 0),
        ),

        /// End at 7s
        ImageLayer(
          image: layerImage,
          endTime: const Duration(seconds: 7),
          offset: Offset(0, (videoHeight - stickerSize).toDouble()),
        ),

        /// Random positions
        for (int i = 0; i < metadata.duration.inSeconds; i++)
          ImageLayer(
            image: layerImage,
            startTime: Duration(seconds: i),
            endTime: Duration(seconds: i + 1),
            offset: Offset(
              rng.nextInt(videoWidth - stickerSize).toDouble(),
              rng.nextInt(videoHeight - stickerSize).toDouble(),
            ),
          ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _layersWithSize() async {
    final stickerImage = EditorLayerImage.asset('assets/sticker.png');

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [
        /// Scaled to 200×200 at top-left
        ImageLayer(
          image: stickerImage,
          offset: const Offset(20, 20),
          size: const Size(100, 100),
        ),

        /// Scaled to 400×100 (stretched) at bottom-right area
        ImageLayer(
          image: stickerImage,
          offset: const Offset(800, 550),
          size: const Size(400, 100),
        ),

        /// Original size (no size set) in the center
        ImageLayer(image: stickerImage, offset: const Offset(500, 230)),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _colorMatrix() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      colorFilters: kComplexFilterMatrix,
    );

    await _renderVideo(data);
  }

  /// Apply different color filters at specific time ranges.
  ///
  /// This example demonstrates timed color filters:
  /// - A warm filter applied from 0–8 seconds
  /// - A cool filter applied from 8–16 seconds
  /// - A high-contrast filter applied from 16 seconds onwards
  Future<void> _colorMatrixTimed() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      colorFilters: [
        // Warm tone filter: 0s – 8s
        ColorFilter(
          matrix: const [
            1.2, 0.0, 0.0, 0.0, 20.0, //
            0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.8, 0.0, -10.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
          ],
          startTime: Duration.zero,
          endTime: const Duration(seconds: 8),
        ),
        // Cool tone filter: 8s – 16s
        ColorFilter(
          matrix: const [
            0.8, 0.0, 0.0, 0.0, -10.0, //
            0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 1.3, 0.0, 30.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
          ],
          startTime: const Duration(seconds: 8),
          endTime: const Duration(seconds: 16),
        ),
        // High contrast filter: 16s – end
        const ColorFilter(
          matrix: [
            1.5, 0.0, 0.0, 0.0, -60.0, //
            0.0, 1.5, 0.0, 0.0, -60.0,
            0.0, 0.0, 1.5, 0.0, -60.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
          ],
          startTime: Duration(seconds: 16),
        ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _blur() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      blur: 5,
    );

    await _renderVideo(data);
  }

  Future<void> _multipleChanges() async {
    final imageBytes = await _captureLayerContent();
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      transform: const ExportTransform(flipX: true),
      endTime: const Duration(seconds: 20),
      colorFilters: kBasicFilterMatrix,
      imageLayers: [ImageLayer(image: EditorLayerImage.memory(imageBytes))],
    );

    await _renderVideo(data);
  }

  /// Combined timeline-based example.
  ///
  /// This example demonstrates how to combine multiple timed features:
  /// - 2 video segments with different per-clip volume
  /// - Timed color filters (warm first half, cool second half)
  /// - A timed image layer that only appears from 3–8 seconds
  /// - A stretched overlay visible for the entire video
  /// - Background music that plays during the second half
  Future<void> _combinedTimeBased() async {
    final imageBytes = await _captureLayerContent();
    final stickerImage = EditorLayerImage.asset('assets/sticker.png');
    final audioFile = await _writeAssetAudioToFile(
      kVideoEditorExampleAudio1Path,
    );

    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 10),
          volume: 1.0,
        ),
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 20),
          volume: 0.3,
        ),
      ],
      colorFilters: [
        // Warm tone: first 10s
        ColorFilter(
          matrix: const [
            1.2, 0.0, 0.0, 0.0, 20.0, //
            0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.8, 0.0, -10.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
          ],
          startTime: Duration.zero,
          endTime: const Duration(seconds: 10),
        ),
        // Cool tone: 10s – end
        const ColorFilter(
          matrix: [
            0.8, 0.0, 0.0, 0.0, -10.0, //
            0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 1.3, 0.0, 30.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
          ],
          startTime: Duration(seconds: 10),
        ),
      ],
      imageLayers: [
        // Stretched overlay for entire video
        ImageLayer(image: EditorLayerImage.memory(imageBytes)),
        // Sticker visible only from 3s–8s
        ImageLayer(
          image: stickerImage,
          offset: const Offset(500, 150),
          startTime: const Duration(seconds: 3),
          endTime: const Duration(seconds: 8),
        ),
      ],
      audioTracks: [
        // Background music in second half at low volume
        VideoAudioTrack(
          path: audioFile.path,
          volume: 0.4,
          startTime: const Duration(seconds: 10),
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Fade animation on image layer.
  ///
  /// This example demonstrates a simple fade-in and fade-out animation
  /// on an image layer. The layer fades in over 500ms and fades out
  /// over 300ms.
  Future<void> _layerFadeAnimation() async {
    final stickerImage = EditorLayerImage.asset('assets/sticker.png');

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [
        ImageLayer(
          image: stickerImage,
          offset: const Offset(100, 100),
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 8),
          animations: [
            const LayerAnimation(
              type: LayerAnimationType.fade,
              phase: AnimationPhase.animateIn,
              duration: Duration(milliseconds: 500),
              curve: AnimationCurve.easeIn,
            ),
            const LayerAnimation(
              type: LayerAnimationType.fade,
              phase: AnimationPhase.animateOut,
              duration: Duration(milliseconds: 300),
              curve: AnimationCurve.easeOut,
            ),
          ],
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Slide animation on image layer.
  ///
  /// This example slides a sticker in from the left and slides it out
  /// to the bottom, using different easing curves.
  Future<void> _layerSlideAnimation() async {
    final stickerImage = EditorLayerImage.asset('assets/sticker.png');

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [
        ImageLayer(
          image: stickerImage,
          offset: const Offset(200, 200),
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 7),
          animations: [
            const LayerAnimation(
              type: LayerAnimationType.slide,
              phase: AnimationPhase.animateIn,
              duration: Duration(milliseconds: 600),
              slideDirection: SlideDirection.left,
              curve: AnimationCurve.easeOutCubic,
            ),
            const LayerAnimation(
              type: LayerAnimationType.slide,
              phase: AnimationPhase.animateOut,
              duration: Duration(milliseconds: 400),
              slideDirection: SlideDirection.bottom,
              curve: AnimationCurve.easeIn,
            ),
          ],
        ),
      ],
    );

    await _renderVideo(data);
  }

  /// Combined animations on image layer.
  ///
  /// This example combines fade, slide, and scale animations on a single
  /// layer, using the `animateInOut` phase for convenience.
  Future<void> _layerCombinedAnimations() async {
    final stickerImage = EditorLayerImage.asset('assets/sticker.png');

    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      imageLayers: [
        ImageLayer(
          image: stickerImage,
          offset: const Offset(300, 150),
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 10),
          animations: [
            const LayerAnimation(
              type: LayerAnimationType.fade,
              phase: AnimationPhase.animateInOut,
              duration: Duration(milliseconds: 500),
              curve: AnimationCurve.easeInOut,
            ),
            const LayerAnimation(
              type: LayerAnimationType.slide,
              phase: AnimationPhase.animateIn,
              duration: Duration(milliseconds: 600),
              slideDirection: SlideDirection.left,
              curve: AnimationCurve.bounceOut,
            ),
            const LayerAnimation(
              type: LayerAnimationType.scale,
              phase: AnimationPhase.animateIn,
              duration: Duration(milliseconds: 400),
              scaleFrom: 0.3,
              curve: AnimationCurve.elasticOut,
            ),
          ],
        ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _bitrate() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      bitrate: 1000000,
    );

    await _renderVideo(data);
  }

  Future<void> _generateMov() async {
    var data = VideoRenderData(
      outputFormat: VideoOutputFormat.mov,
      videoSegments: [VideoSegment(video: _video)],
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset1080p() async {
    var data = VideoRenderData.withQualityPreset(
      videoSegments: [VideoSegment(video: _video)],
      qualityPreset: VideoQualityPreset.p1080,
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset720p() async {
    var data = VideoRenderData.withQualityPreset(
      videoSegments: [VideoSegment(video: _video)],
      qualityPreset: VideoQualityPreset.p720,
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset4K() async {
    var data = VideoRenderData.withQualityPreset(
      videoSegments: [VideoSegment(video: _video)],
      qualityPreset: VideoQualityPreset.k4,
    );

    await _renderVideo(data);
  }

  Future<void> _concatenateVideos() async {
    var data = VideoRenderData(
      videoSegments: [
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 0),
          endTime: const Duration(seconds: 5),
        ),
        VideoSegment(
          video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 15),
        ),
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 8),
          endTime: const Duration(seconds: 12),
        ),
      ],
    );

    await _renderVideo(data);
  }

  Future<void> _concatenateWithTransforms() async {
    final imageBytes = await _captureLayerContent();
    var data = VideoRenderData(
      imageLayers: [ImageLayer(image: EditorLayerImage.memory(imageBytes))],
      videoSegments: [
        VideoSegment(
          video: _video,
          startTime: const Duration(seconds: 0),
          endTime: const Duration(seconds: 5),
        ),
        VideoSegment(
          video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
          startTime: const Duration(seconds: 7),
          endTime: const Duration(seconds: 12),
        ),
      ],
      transform: const ExportTransform(
        rotateTurns: 2, // Rotate all clips 180°
        flipX: true, // Flip all clips horizontally
      ),
    );

    await _renderVideo(data);
  }

  /// Export with network streaming optimization (fast start).
  ///
  /// This example demonstrates how to optimize the video for progressive
  /// streaming by moving the moov atom to the beginning of the file.
  ///
  /// When `shouldOptimizeForNetworkUse` is `true` (default), the video
  /// metadata is placed at the start of the file, allowing browsers and
  /// media players to begin playback before the entire file is downloaded.
  ///
  /// This fixes the "mdat before moov" issue that prevents progressive
  /// streaming in browsers.
  Future<void> _optimizeForNetworkUse() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      shouldOptimizeForNetworkUse: true, // Default, but explicit for demo
    );

    await _renderVideo(data);
  }

  /// Export WITHOUT network streaming optimization.
  ///
  /// This example exports the video without moving the moov atom,
  /// which may result in faster encoding but prevents progressive
  /// streaming in browsers.
  Future<void> _noNetworkOptimization() async {
    var data = VideoRenderData(
      videoSegments: [VideoSegment(video: _video)],
      shouldOptimizeForNetworkUse: false,
    );

    await _renderVideo(data);
  }

  Future<void> _testMetadataStripped() async {
    final sourceMeta = await _pve.getMetadata(_video);

    final result = await _pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: _video)],
        outputFormat: VideoOutputFormat.mp4,
      ),
    );

    final renderedMeta = await _pve.getMetadata(EditorVideo.memory(result));

    final checks = <String, bool>{
      'GPS stripped': renderedMeta.gpsCoordinates == null,
      'Title stripped': renderedMeta.title.isEmpty,
      'Artist stripped': renderedMeta.artist.isEmpty,
      'Author stripped': renderedMeta.author.isEmpty,
    };

    final allPassed = checks.values.every((v) => v);
    final details = checks.entries
        .map((e) => '${e.value ? "\u2705" : "\u274c"} ${e.key}')
        .join('\n');

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          allPassed
              ? '\u2705 All metadata stripped'
              : '\u274c Some metadata leaked',
        ),
        content: Text(
          'Source GPS: ${sourceMeta.gpsCoordinates}\n'
          'Source Date: ${sourceMeta.date}\n\n'
          '$details\n\n'
          'Note: Date is expected to remain (MP4 creation_time).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _renderVideo(VideoRenderData value) async {
    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() => _isExporting = true);

    final directory = await getTemporaryDirectory();
    var sp = Stopwatch()..start();

    final now = DateTime.now().millisecondsSinceEpoch;
    // Use the correct file extension based on the output format
    final extension = value.outputFormat.name;
    String outputPath = '${directory.path}/my_video_$now.$extension';

    try {
      await _pve.renderVideoToFile(outputPath, value.copyWith(id: _taskId));
    } on RenderCanceledException {
      setState(() => _isExporting = false);
      return;
    }

    final result = File(outputPath).readAsBytesSync();

    _generationTime = sp.elapsed;

    _outputMetadata = await _pve.getMetadata(
      EditorVideo.memory(result),
      checkStreamingOptimization: true,
    );

    _isExporting = false;
    _videoBytes = result;
    setState(() {});

    await _playerPreview.open(Media(outputPath));
    await _playerPreview.play();
  }

  Future<void> _cancelRender() async {
    if (!_supportsCancel) return;
    try {
      await _pve.cancel(_taskId);
      // Reset the state after canceling.
      setState(() {
        _isExporting = false;
        _videoBytes = null;
        _generationTime = Duration.zero;
        _outputMetadata = null;
      });
      _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    } catch (error, stackTrace) {
      debugPrint('Failed to cancel render: $error\n$stackTrace');
    }
  }

  Future<Uint8List> _captureLayerContent([Size? resolution]) async {
    final context = _boundaryKey.currentContext!;
    final boundary = context.findRenderObject() as RenderRepaintBoundary;
    final double pixelRatio = resolution == null
        ? MediaQuery.devicePixelRatioOf(context)
        : max(
            resolution.width / boundary.size.width,
            resolution.height / boundary.size.height,
          );

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: .png);

    return byteData!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Video Export')),
      body: SingleChildScrollView(
        padding: .fromLTRB(0, 16, 0, 16 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            Padding(
              padding: const .symmetric(horizontal: 16.0),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: _buildDemoEditorContent(),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: _buildExportedVideo(),
                  ),
                ],
              ),
            ),
            _buildOptions(),
          ],
        ),
      ),
    );
  }

  Widget _buildDemoEditorContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 5,
      children: [
        const Text('Demo-Video'),
        AspectRatio(
          aspectRatio: 1280 / 720,
          child: Stack(
            children: [
              ColorFilterGenerator(
                filters: _colorFilters,
                child: Video(controller: _controllerContent),
              ),
              IgnorePointer(
                child: ClipRect(
                  clipBehavior: Clip.hardEdge,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: _blurFactor,
                      sigmaY: _blurFactor,
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      color: Colors.white.withValues(alpha: 0.0),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: AspectRatio(
                  aspectRatio: 1280 / 720,
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: const Stack(
                      children: [
                        Positioned(
                          top: 10,
                          left: 10,
                          child: Text('🤑', style: TextStyle(fontSize: 40)),
                        ),
                        Positioned(
                          bottom: 10,
                          right: 10,
                          child: Text('❤️', style: TextStyle(fontSize: 32)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExportedVideo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 5,
      children: _videoBytes == null
          ? []
          : [
              const Text('Output-Video'),
              AspectRatio(
                aspectRatio: max(
                  _outputMetadata?.resolution.aspectRatio ?? 0,
                  1280 / 720,
                ),
                child: Video(controller: _controllerPreview),
              ),
              Text(
                'Result: ${formatBytes(_videoBytes!.lengthInBytes)} '
                'bytes in ${_generationTime.inMilliseconds}ms',
              ),
              if (_outputMetadata?.isOptimizedForStreaming != null)
                Row(
                  children: [
                    Icon(
                      _outputMetadata!.isOptimizedForStreaming!
                          ? Icons.check_circle
                          : Icons.cancel,
                      color: _outputMetadata!.isOptimizedForStreaming!
                          ? Colors.green
                          : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _outputMetadata!.isOptimizedForStreaming!
                          ? 'Optimized for streaming (moov before mdat)'
                          : 'Not optimized (mdat before moov)',
                    ),
                  ],
                ),
            ],
    );
  }

  Widget _buildOptions() {
    if (_isExporting) {
      return VideoRendererProgressPanel(
        progressStream: _pve.progressStreamById(_taskId),
        supportsCancel: _supportsCancel,
        onCancel: _supportsCancel ? _cancelRender : null,
      );
    }

    return Column(
      children: [
        ListTile(
          onTap: _rotate,
          leading: const Icon(Icons.rotate_90_degrees_ccw),
          title: const Text('Rotate'),
        ),
        ListTile(
          onTap: _flip,
          leading: const Icon(Icons.flip),
          title: const Text('Flip'),
        ),
        ListTile(
          onTap: _crop,
          leading: const Icon(Icons.crop),
          title: const Text('Crop'),
        ),
        ListTile(
          onTap: _scale,
          leading: const Icon(Icons.fit_screen_outlined),
          title: const Text('Scale'),
        ),
        ListTile(
          onTap: _trim,
          leading: const Icon(Icons.content_cut_rounded),
          title: const Text('Trim'),
        ),
        ListTile(
          onTap: _changeSpeed,
          leading: const Icon(Icons.speed_outlined),
          title: const Text('Change playback speed'),
        ),
        ListTile(
          onTap: _layers,
          leading: const Icon(Icons.layers_outlined),
          title: const Text('Parse with layers'),
        ),
        ListTile(
          onTap: _layersTimed,
          leading: const Icon(Icons.av_timer_outlined),
          title: const Text('Parse with timed layers'),
        ),
        ListTile(
          onTap: _layersWithSize,
          leading: const Icon(Icons.photo_size_select_large_outlined),
          title: const Text('Layers with custom size'),
          subtitle: const Text('Scale layers to specific dimensions'),
        ),
        ListTile(
          onTap: _colorMatrix,
          leading: const Icon(Icons.lens_blur_outlined),
          title: const Text('Apply ColorMatrix'),
        ),
        ListTile(
          onTap: _colorMatrixTimed,
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Timed Color Filters'),
          subtitle: const Text('Warm → Cool → Contrast'),
        ),
        ListTile(
          onTap: _blur,
          leading: const Icon(Icons.blur_circular_outlined),
          title: const Text('Blur'),
        ),
        ListTile(
          onTap: _multipleChanges,
          leading: const Icon(Icons.web_stories_outlined),
          title: const Text('Multiple changes'),
        ),
        ListTile(
          onTap: _combinedTimeBased,
          leading: const Icon(Icons.timeline_outlined),
          title: const Text('Combined Time-Based'),
          subtitle: const Text('Clips + filters + layers + audio, all timed'),
        ),
        ListTile(
          onTap: _bitrate,
          leading: const Icon(Icons.animation),
          title: const Text('Bitrate'),
        ),
        if (!kIsWeb && (Platform.isIOS || Platform.isMacOS))
          ListTile(
            onTap: _generateMov,
            leading: const Icon(Icons.video_file_outlined),
            title: const Text('Output-Format "mov"'),
          ),
        ..._buildSectionTitle('Layer Animations'),
        ListTile(
          onTap: _layerFadeAnimation,
          leading: const Icon(Icons.animation_outlined),
          title: const Text('Fade Animation'),
          subtitle: const Text('Fade in 500ms + fade out 300ms'),
        ),
        ListTile(
          onTap: _layerSlideAnimation,
          leading: const Icon(Icons.swap_horiz_outlined),
          title: const Text('Slide Animation'),
          subtitle: const Text('Slide in from left, out to bottom'),
        ),
        ListTile(
          onTap: _layerCombinedAnimations,
          leading: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Combined Animations'),
          subtitle: const Text('Fade + slide + scale with curves'),
        ),
        ..._buildSectionTitle('Video Concatenation'),
        ListTile(
          onTap: _concatenateVideos,
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('Concatenate Multiple Clips'),
          subtitle: const Text('Combine 3 clips'),
        ),
        ListTile(
          onTap: _concatenateWithTransforms,
          leading: const Icon(Icons.join_full_outlined),
          title: const Text('Concatenate with Transformations'),
          subtitle: const Text('2 clips with rotation, flip, layers'),
        ),
        ..._buildSectionTitle('Audio'),
        ListTile(
          onTap: _removeAudio,
          leading: const Icon(Icons.volume_off_outlined),
          title: const Text('Remove Audio'),
        ),
        ListTile(
          onTap: _customAudioReplace,
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('Replace Audio with Custom Track'),
          subtitle: const Text('Custom audio at 100%'),
        ),
        ListTile(
          onTap: _customAudioMix,
          leading: const Icon(Icons.music_note_outlined),
          title: const Text('Mix Custom Audio'),
          subtitle: const Text('Original 90% + Custom 10%'),
        ),
        ListTile(
          onTap: _adjustOriginalVolume,
          leading: const Icon(Icons.volume_down_outlined),
          title: const Text('Adjust Original Volume'),
          subtitle: const Text('Reduce to 20%'),
        ),
        ListTile(
          onTap: _customAudioNoLoop,
          leading: const Icon(Icons.music_off_outlined),
          title: const Text('Custom Audio Without Loop'),
          subtitle: const Text('Plays once, then silence'),
        ),
        ListTile(
          onTap: _customAudioStartOffset,
          leading: const Icon(Icons.skip_next_outlined),
          title: const Text('Custom Audio with Start Offset'),
          subtitle: const Text('Start at 5 seconds into audio'),
        ),
        ListTile(
          onTap: _timedAudioTracks,
          leading: const Icon(Icons.queue_music_outlined),
          title: const Text('Timed Audio Tracks'),
          subtitle: const Text('Track 1: 0–10s, Track 2: 10–20s'),
        ),
        ListTile(
          onTap: _audioClipRange,
          leading: const Icon(Icons.content_cut_outlined),
          title: const Text('Audio Clip Range'),
          subtitle: const Text('Extract 3s–8s from audio file'),
        ),
        ListTile(
          onTap: _perClipVolume,
          leading: const Icon(Icons.tune_outlined),
          title: const Text('Per-Clip Volume'),
          subtitle: const Text('100% → 0% → 30% across clips'),
        ),
        ..._buildSectionTitle('Quality'),
        ListTile(
          onTap: _qualityPreset1080p,
          leading: const Icon(Icons.high_quality),
          title: const Text('Export with 1080p Quality Preset'),
          subtitle: const Text('8 Mbps bitrate'),
        ),
        ListTile(
          onTap: _qualityPreset720p,
          leading: const Icon(Icons.sd),
          title: const Text('Export with 720p Quality Preset'),
          subtitle: const Text('3 Mbps bitrate'),
        ),
        ListTile(
          onTap: _qualityPreset4K,
          leading: const Icon(Icons.four_k),
          title: const Text('Export with 4K Quality Preset'),
          subtitle: const Text('35 Mbps bitrate'),
        ),
        ..._buildSectionTitle('Network Streaming'),
        ListTile(
          onTap: _optimizeForNetworkUse,
          leading: const Icon(Icons.cloud_upload_outlined),
          title: const Text('Optimize for Network Streaming'),
          subtitle: const Text('Fast start enabled (moov at beginning)'),
        ),
        ListTile(
          onTap: _noNetworkOptimization,
          leading: const Icon(Icons.cloud_off_outlined),
          title: const Text('No Network Optimization'),
          subtitle: const Text('Fast start disabled'),
        ),
        ..._buildSectionTitle('Privacy'),
        ListTile(
          onTap: _testMetadataStripped,
          leading: const Icon(Icons.security_outlined),
          title: const Text('Test Metadata Stripping'),
          subtitle: const Text('Verify GPS, date, etc. are removed'),
        ),
      ],
    );
  }

  List<Widget> _buildSectionTitle(String title) {
    return [
      const Divider(height: 32),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    ];
  }
}
