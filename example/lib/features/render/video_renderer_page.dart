import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';

import '/core/constants/example_filters.dart';
import '/shared/utils/bytes_formatter.dart';
import '/shared/widgets/filter_generator.dart';
import '../../core/constants/example_constants.dart';

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
      Media('asset:///$kVideoEditorExampleAssetPath'),
      play: true,
    );
    _video = EditorVideo.asset(kVideoEditorExampleAssetPath);
  }

  @override
  void dispose() {
    _playerContent.dispose();
    _playerPreview.dispose();
    super.dispose();
  }

  Future<void> _rotate() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      transform: const ExportTransform(
        rotateTurns: 1,
      ),
    );

    await _renderVideo(data);
  }

  Future<void> _flip() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      transform: const ExportTransform(
        flipX: true,
      ),
    );

    await _renderVideo(data);
  }

  Future<void> _crop() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      transform: const ExportTransform(
        x: 100,
        y: 250,
        width: 700,
        height: 300,
      ),
    );

    await _renderVideo(data);
  }

  Future<void> _scale() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      transform: const ExportTransform(scaleX: 0.2, scaleY: 0.2),
    );

    await _renderVideo(data);
  }

  Future<void> _trim() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      startTime: const Duration(seconds: 7),
      endTime: const Duration(seconds: 20),
    );

    await _renderVideo(data);
  }

  Future<void> _changeSpeed() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      playbackSpeed: 2,
    );

    await _renderVideo(data);
  }

  Future<void> _removeAudio() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      enableAudio: false,
    );

    await _renderVideo(data);
  }

  Future<void> _layers() async {
    final imageBytes = await _captureLayerContent();
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      imageBytes: imageBytes,
    );

    await _renderVideo(data);
  }

  Future<void> _colorMatrix() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      colorMatrixList: kComplexFilterMatrix,
    );

    await _renderVideo(data);
  }

  Future<void> _blur() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      blur: 5,
    );

    await _renderVideo(data);
  }

  Future<void> _multipleChanges() async {
    final imageBytes = await _captureLayerContent();
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      transform: const ExportTransform(
        flipX: true,
      ),
      colorMatrixList: kBasicFilterMatrix,
      enableAudio: false,
      imageBytes: imageBytes,
      endTime: const Duration(seconds: 20),
    );

    await _renderVideo(data);
  }

  Future<void> _bitrate() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      video: _video,
      bitrate: 1000000,
    );

    await _renderVideo(data);
  }

  Future<void> _generateMov() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mov,
      video: _video,
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset1080p() async {
    var data = RenderVideoModel.withQualityPreset(
      video: _video,
      qualityPreset: VideoQualityPreset.p1080,
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset720p() async {
    var data = RenderVideoModel.withQualityPreset(
      video: _video,
      qualityPreset: VideoQualityPreset.p720,
    );

    await _renderVideo(data);
  }

  Future<void> _qualityPreset4K() async {
    var data = RenderVideoModel.withQualityPreset(
      video: _video,
      qualityPreset: VideoQualityPreset.k4,
    );

    await _renderVideo(data);
  }

  Future<void> _renderVideo(RenderVideoModel value) async {
    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() => _isExporting = true);

    final directory = await getTemporaryDirectory();
    var sp = Stopwatch()..start();

    final now = DateTime.now().millisecondsSinceEpoch;
    String outputPath = '${directory.path}/my_video_$now.mp4';

    try {
      await ProVideoEditor.instance.renderVideoToFile(
        outputPath,
        value.copyWith(id: _taskId),
      );
    } on RenderCanceledException {
      setState(() => _isExporting = false);
      return;
    }

    final result = File(outputPath).readAsBytesSync();

    _generationTime = sp.elapsed;

    _outputMetadata = await ProVideoEditor.instance.getMetadata(
      EditorVideo.memory(result),
    );

    await _playerPreview.open(Media(outputPath));
    await _playerPreview.play();

    _isExporting = false;
    _videoBytes = result;
    setState(() {});
  }

  Future<void> _cancelRender() async {
    if (!_supportsCancel) return;
    try {
      await ProVideoEditor.instance.cancel(_taskId);
    } catch (error, stackTrace) {
      debugPrint('Failed to cancel render: $error\n$stackTrace');
    }
  }

  Future<Uint8List> _captureLayerContent() async {
    final boundary = _boundaryKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    final image = await boundary.toImage(
        pixelRatio: MediaQuery.devicePixelRatioOf(context));
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Export')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 360,
                    ),
                    child: _buildDemoEditorContent(),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 360,
                    ),
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
                        sigmaX: _blurFactor, sigmaY: _blurFactor),
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
                          child: Text(
                            '🤑',
                            style: TextStyle(fontSize: 40),
                          ),
                        ),
                        Center(
                          child: Text(
                            '🚀',
                            style: TextStyle(fontSize: 48),
                          ),
                        ),
                        Positioned(
                          bottom: 10,
                          right: 10,
                          child: Text(
                            '❤️',
                            style: TextStyle(fontSize: 32),
                          ),
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
            ],
    );
  }

  Widget _buildOptions() {
    if (_isExporting) {
      return VideoRendererProgressPanel(
        progressStream: ProVideoEditor.instance.progressStreamById(_taskId),
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
          onTap: _removeAudio,
          leading: const Icon(Icons.volume_off_outlined),
          title: const Text('Remove Audio'),
        ),
        ListTile(
          onTap: _layers,
          leading: const Icon(Icons.layers_outlined),
          title: const Text('Parse with layers'),
        ),
        ListTile(
          onTap: _colorMatrix,
          leading: const Icon(Icons.lens_blur_outlined),
          title: const Text('Apply ColorMatrix'),
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
        const Divider(height: 32),
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
      ],
    );
  }
}
