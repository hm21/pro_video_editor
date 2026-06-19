import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:chewie/chewie.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';
import 'package:video_player/video_player.dart';

import '/shared/utils/bytes_formatter.dart';
import '/shared/widgets/native_log_console.dart';

/// A page demonstrating the stop-motion feature: turning a sequence of still
/// images into a video.
class StopMotionExamplePage extends StatefulWidget {
  /// Creates a [StopMotionExamplePage].
  const StopMotionExamplePage({super.key});

  @override
  State<StopMotionExamplePage> createState() => _StopMotionExamplePageState();
}

class _StopMotionExamplePageState extends State<StopMotionExamplePage> {
  final _pve = ProVideoEditor.instance;

  VideoPlayerController? _controllerPreview;
  ChewieController? _chewieControllerPreview;
  bool _isPreviewInitialized = false;

  bool _isExporting = false;
  Uint8List? _videoBytes;
  Duration _generationTime = Duration.zero;
  String _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  double _fps = 8;
  StopMotionFit _fit = StopMotionFit.contain;

  /// User-picked image frames. When null, synthetic sample frames are used.
  List<StopMotionFrame>? _pickedFrames;

  bool get _supportsCancel => canCancelOnCurrentPlatform();

  @override
  void dispose() {
    if (_isPreviewInitialized) _controllerPreview?.dispose();
    _chewieControllerPreview?.dispose();
    super.dispose();
  }

  /// Generates a sequence of synthetic frames so the demo runs without picking
  /// any files — a moving circle on a shifting background plus a frame counter.
  Future<List<StopMotionFrame>> _generateSampleFrames({
    int count = 24,
    Size size = const Size(640, 480),
  }) async {
    final frames = <StopMotionFrame>[];
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.0 : i / (count - 1);

      final recorder = ui.PictureRecorder();
      final canvas =
          Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height))
            ..drawRect(
              Offset.zero & size,
              Paint()..color = Color.lerp(Colors.indigo, Colors.teal, t)!,
            );

      final cx = size.width * t;
      final cy = size.height / 2 + sin(t * 2 * pi) * size.height / 4;
      canvas.drawCircle(Offset(cx, cy), 40, Paint()..color = Colors.amber);

      TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )
        ..layout()
        ..paint(canvas, const Offset(20, 20));

      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();

      frames.add(
        StopMotionFrame(
          image: EditorLayerImage.memory(byteData!.buffer.asUint8List()),
        ),
      );
    }
    return frames;
  }

  Future<void> _pickImages() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result == null) return;

    final frames = result.files
        .where((f) => f.path != null)
        .map((f) => StopMotionFrame(image: EditorLayerImage.file(f.path!)))
        .toList();

    if (frames.isEmpty) return;
    setState(() => _pickedFrames = frames);
  }

  Future<void> _render() async {
    if (_isExporting) return;

    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _isExporting = true;
      _isPreviewInitialized = false;
    });

    await _disposePreview();

    final frames = _pickedFrames ?? await _generateSampleFrames();

    final data = StopMotionRenderData(
      id: _taskId,
      frames: frames,
      frameRate: _fps,
      fit: _fit,
    );

    final directory = await getTemporaryDirectory();
    final now = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${directory.path}/stop_motion_$now.mp4';

    final sw = Stopwatch()..start();
    try {
      await _pve.renderStopMotionToFile(
        outputPath,
        data,
        nativeLogLevel: NativeLogLevel.debug,
      );
    } on RenderCanceledException {
      setState(() => _isExporting = false);
      return;
    }
    _generationTime = sw.elapsed;

    final result = File(outputPath).readAsBytesSync();
    _videoBytes = result;
    _isExporting = false;

    _controllerPreview = VideoPlayerController.file(File(outputPath));
    await _controllerPreview!.initialize();
    _chewieControllerPreview = ChewieController(
      videoPlayerController: _controllerPreview!,
      autoPlay: true,
      looping: true,
      placeholder: Container(color: Colors.black),
    );

    if (!mounted) return;
    setState(() => _isPreviewInitialized = true);
  }

  Future<void> _cancel() async {
    if (!_supportsCancel) return;
    try {
      await _pve.cancel(_taskId);
      setState(() {
        _isExporting = false;
        _videoBytes = null;
        _generationTime = Duration.zero;
      });
      _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    } catch (error, stackTrace) {
      debugPrint('Failed to cancel stop-motion render: $error\n$stackTrace');
    }
  }

  Future<void> _disposePreview() async {
    await _chewieControllerPreview?.pause();
    _chewieControllerPreview?.dispose();
    _chewieControllerPreview = null;
    final controller = _controllerPreview;
    _controllerPreview = null;
    await controller?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Stop-Motion')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            if (_videoBytes != null) _buildPreview(),
            if (_isExporting)
              VideoRendererProgressPanel(
                progressStream: _pve.progressStreamById(_taskId),
                supportsCancel: _supportsCancel,
                onCancel: _supportsCancel ? _cancel : null,
              )
            else
              _buildControls(),
            NativeLogConsole(logStream: _pve.logStream),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final frameCount = _pickedFrames?.length ?? 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(
          _pickedFrames == null
              ? 'Using 24 generated sample frames.'
              : 'Using $frameCount picked image(s).',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _pickImages,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Pick images'),
            ),
            if (_pickedFrames != null)
              OutlinedButton.icon(
                onPressed: () => setState(() => _pickedFrames = null),
                icon: const Icon(Icons.refresh),
                label: const Text('Use sample frames'),
              ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 4),
            Text('FPS: ${_fps.toStringAsFixed(0)}'),
            Expanded(
              child: Slider(
                value: _fps,
                min: 1,
                max: 30,
                divisions: 29,
                label: _fps.toStringAsFixed(0),
                onChanged: (v) => setState(() => _fps = v),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Text('Fit:'),
            const SizedBox(width: 12),
            DropdownButton<StopMotionFit>(
              value: _fit,
              onChanged: (v) => setState(() => _fit = v ?? _fit),
              items: StopMotionFit.values
                  .map((f) => DropdownMenuItem(value: f, child: Text(f.name)))
                  .toList(),
            ),
          ],
        ),
        FilledButton.icon(
          onPressed: _render,
          icon: const Icon(Icons.movie_creation_outlined),
          label: const Text('Render stop-motion video'),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 5,
      children: [
        const Text('Output-Video'),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: _isPreviewInitialized
              ? Chewie(controller: _chewieControllerPreview!)
              : const Center(child: CircularProgressIndicator()),
        ),
        Text(
          'Result: ${formatBytes(_videoBytes!.lengthInBytes)} bytes '
          'in ${_generationTime.inMilliseconds}ms',
        ),
      ],
    );
  }
}
