import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pro_video_editor/core/models/video/progress_model.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

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

  Uint8List? _temporaryVideoBytes;

  String _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  @override
  void initState() {
    super.initState();
    _playerContent.open(Media('asset:///assets/demo.mp4'), play: true);
  }

  @override
  void dispose() {
    _playerContent.dispose();
    _playerPreview.dispose();
    super.dispose();
  }

  Future<Uint8List> _getVideoBytes() async {
    if (_temporaryVideoBytes != null) return _temporaryVideoBytes!;
    final videoBytes = await loadAssetImageAsUint8List('assets/demo.mp4');
    _temporaryVideoBytes = videoBytes;
    return videoBytes;
  }

  Future<void> _rotate() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      transform: const ExportTransform(
        rotateTurns: 1,
      ),
    );

    await _renderVideo(data);
  }

  Future<void> _flip() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      transform: const ExportTransform(
        flipX: true,
      ),
    );

    await _renderVideo(data);
  }

  Future<void> _crop() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
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
      videoBytes: await _getVideoBytes(),
      transform: const ExportTransform(scaleX: 0.2, scaleY: 0.2),
    );

    await _renderVideo(data);
  }

  Future<void> _trim() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      startTime: const Duration(seconds: 7),
      endTime: const Duration(seconds: 20),
    );

    await _renderVideo(data);
  }

  Future<void> _changeSpeed() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      playbackSpeed: 2,
    );

    await _renderVideo(data);
  }

  Future<void> _removeAudio() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      enableAudio: false,
    );

    await _renderVideo(data);
  }

  Future<void> _layers() async {
    final imageBytes = await _captureLayerContent();
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      imageBytes: imageBytes,
    );

    await _renderVideo(data);
  }

  Future<void> _colorMatrix() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      colorMatrixList: kComplexFilterMatrix,
    );

    await _renderVideo(data);
  }

  Future<void> _blur() async {
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
      blur: 5,
    );

    await _renderVideo(data);
  }

  Future<void> _multipleChanges() async {
    final imageBytes = await _captureLayerContent();
    var data = RenderVideoModel(
      outputFormat: VideoOutputFormat.mp4,
      videoBytes: await _getVideoBytes(),
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

  Future<void> _renderVideo(RenderVideoModel value) async {
    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() => _isExporting = true);

    var sp = Stopwatch()..start();

    final result = await VideoUtilsService.instance.renderVideo(
      value.copyWith(id: _taskId),
    );

    _generationTime = sp.elapsed;

    _outputMetadata = (await VideoUtilsService.instance
        .getMetadata(EditorVideo(byteArray: result)));

    await _playerPreview.open(await Media.memory(result));
    await _playerPreview.play();

    _isExporting = false;
    _videoBytes = result;
    setState(() {});
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
          spacing: 20,
          children: [
            _buildDemoEditorContent(),
            _buildExportedVideo(),
            _buildOptions(),
          ],
        ),
      ),
    );
  }

  Widget _buildDemoEditorContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
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
      ),
    );
  }

  Widget _buildExportedVideo() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
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
      ),
    );
  }

  Widget _buildOptions() {
    if (_isExporting) {
      return StreamBuilder<ProgressModel>(
        stream: VideoUtilsService.instance.progressStream
            .where((item) => item.id == _taskId),
        builder: (context, snapshot) {
          double progress = snapshot.data?.progress ?? 0;

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 300),
            builder: (context, animatedValue, _) {
              return Column(
                spacing: 7,
                children: [
                  CircularProgressIndicator(
                    value: animatedValue,
                    // ignore: deprecated_member_use
                    year2023: false,
                  ),
                  Text('${(animatedValue * 100).toStringAsFixed(1)} / 100'),
                ],
              );
            },
          );
        },
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
      ],
    );
  }
}
