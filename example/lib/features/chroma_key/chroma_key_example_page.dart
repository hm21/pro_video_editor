import 'dart:io';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';
import 'package:video_player/video_player.dart';

import '/core/constants/example_constants.dart';
import '/shared/utils/bytes_formatter.dart';
import '/shared/widgets/native_log_console.dart';

/// What the removed screen is filled with.
enum _Background {
  /// A solid color.
  color,

  /// A still image.
  image,

  /// Nothing — the layer below in a [VideoComposition] shows through.
  video,
}

/// A page demonstrating the chroma key: removing a green screen and putting
/// something else behind the subject.
class ChromaKeyExamplePage extends StatefulWidget {
  /// Creates a [ChromaKeyExamplePage].
  const ChromaKeyExamplePage({super.key});

  @override
  State<ChromaKeyExamplePage> createState() => _ChromaKeyExamplePageState();
}

class _ChromaKeyExamplePageState extends State<ChromaKeyExamplePage> {
  final _pve = ProVideoEditor.instance;

  VideoPlayerController? _controllerPreview;
  ChewieController? _chewieControllerPreview;
  bool _isPreviewInitialized = false;

  bool _isExporting = false;
  Uint8List? _videoBytes;
  Duration _generationTime = Duration.zero;
  String _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  _Background _background = _Background.color;
  Color _keyColor = const ChromaKey().color;
  double _similarity = const ChromaKey().similarity;
  double _smoothness = 0.08;
  double _spill = 0.5;

  /// The last auto-detection, shown so the measurement is visible rather than
  /// just silently applied.
  ChromaKeyDetection? _detection;
  bool _isDetecting = false;

  bool get _supportsCancel => canCancelOnCurrentPlatform();

  static const _fillRed = Color(0xFFE00000);

  /// The green-screen asset's own size, used as the composition canvas so the
  /// keyed clip and the backdrop line up without scaling.
  static const _canvas = Size(756, 732);

  EditorVideo get _greenScreen =>
      EditorVideo.asset(kVideoEditorExampleGreenScreenPath);

  @override
  void dispose() {
    // Unconditional: the controller can be fully initialized and playing while
    // `_isPreviewInitialized` is still false, when the page is popped between
    // `initialize()` and the `setState` that flips the flag.
    _chewieControllerPreview?.dispose();
    _controllerPreview?.dispose();
    super.dispose();
  }

  /// Builds the render for the selected background.
  VideoRenderData _buildRenderData(EditorVideo source) {
    switch (_background) {
      case _Background.color:
        return VideoRenderData(
          id: _taskId,
          videoSegments: [VideoSegment(video: source)],
          chromaKey: ChromaKey(
            color: _keyColor,
            similarity: _similarity,
            smoothness: _smoothness,
            spill: _spill,
            backgroundColor: _fillRed,
          ),
        );

      case _Background.image:
        return VideoRenderData(
          id: _taskId,
          videoSegments: [VideoSegment(video: source)],
          chromaKey: ChromaKey(
            color: _keyColor,
            similarity: _similarity,
            smoothness: _smoothness,
            spill: _spill,
            backgroundImage: EditorLayerImage.asset('assets/sticker.png'),
          ),
        );

      case _Background.video:
        // The key is left transparent, so the layer below — a second video —
        // shows through. This is the only way to put a *video* behind the
        // screen: the single-track path has nothing underneath, and neither
        // H.264 nor HEVC carries an alpha channel.
        return VideoRenderData(
          id: _taskId,
          composition: VideoComposition(
            canvasSize: _canvas,
            layers: [
              VideoLayer(
                clips: [
                  VideoSegment(
                    video: EditorVideo.asset(kVideoEditorExampleAssetWorldPath),
                    endTime: const Duration(seconds: 3),
                  ),
                ],
              ),
              VideoLayer(
                clips: [VideoSegment(video: source)],
                chromaKey: ChromaKey(
                  color: _keyColor,
                  similarity: _similarity,
                  smoothness: _smoothness,
                  spill: _spill,
                ),
              ),
            ],
          ),
        );
    }
  }

  /// Measures the screen in the source and adopts the result, so the sliders
  /// show what was found instead of a guess.
  Future<void> _autoDetect() async {
    setState(() => _isDetecting = true);
    try {
      final detection = await ChromaKey.detect(_greenScreen);
      if (!mounted) return;
      setState(() {
        _detection = detection;
        _keyColor = detection.color;
        _similarity = detection.similarity;
      });
    } on ChromaKeyDetectionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }
  }

  Future<void> _render() async {
    if (_isExporting) return;

    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _isExporting = true;
      _isPreviewInitialized = false;
    });

    await _disposePreview();

    final data = _buildRenderData(_greenScreen);

    final directory = await getTemporaryDirectory();
    final now = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${directory.path}/chroma_key_$now.mp4';

    final sw = Stopwatch()..start();
    try {
      await _pve.renderVideoToFile(
        outputPath,
        data,
        nativeLogLevel: NativeLogLevel.debug,
      );
    } on RenderCanceledException {
      setState(() => _isExporting = false);
      return;
    }
    _generationTime = sw.elapsed;

    _videoBytes = File(outputPath).readAsBytesSync();
    _isExporting = false;

    _controllerPreview = VideoPlayerController.file(File(outputPath));
    await _controllerPreview!.initialize();

    // Checked before the Chewie controller exists, so a page popped during
    // initialization never leaves an autoplaying player behind.
    if (!mounted) {
      await _disposePreview();
      return;
    }

    _chewieControllerPreview = ChewieController(
      videoPlayerController: _controllerPreview!,
      autoPlay: true,
      looping: true,
      placeholder: Container(color: Colors.black),
    );

    setState(() => _isPreviewInitialized = true);
  }

  Future<void> _cancel() async {
    if (!_supportsCancel) return;
    await _pve.cancel(_taskId);
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
      appBar: AppBar(title: const Text('Chroma Key')),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        const Text(
          'Source: a person in front of a lit studio green screen. The screen '
          'is not evenly lit — its darkest corners sit close to the default '
          'similarity, so lowering that slider makes them survive the key.',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        OutlinedButton.icon(
          onPressed: _isDetecting ? null : _autoDetect,
          icon: _isDetecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.colorize_outlined),
          label: const Text('Measure the screen from the clip'),
        ),
        if (_detection != null) _buildDetectionSummary(_detection!),
        const Text('Fill the removed screen with:'),
        SegmentedButton<_Background>(
          selected: {_background},
          onSelectionChanged: (v) => setState(() => _background = v.first),
          segments: const [
            ButtonSegment(
              value: _Background.color,
              icon: Icon(Icons.format_color_fill_outlined),
              label: Text('Color'),
            ),
            ButtonSegment(
              value: _Background.image,
              icon: Icon(Icons.image_outlined),
              label: Text('Image'),
            ),
            ButtonSegment(
              value: _Background.video,
              icon: Icon(Icons.layers_outlined),
              label: Text('Video'),
            ),
          ],
        ),
        if (_background == _Background.video)
          const Text(
            'Transparent key on the upper layer of a VideoComposition, so the '
            'video below shows through.',
            style: TextStyle(fontSize: 12),
          ),
        _buildSlider(
          label: 'similarity',
          value: _similarity,
          min: 0.01,
          max: 0.6,
          hint: 'Raise it if the screen survives, lower it if the subject goes',
          onChanged: (v) => setState(() => _similarity = v),
        ),
        _buildSlider(
          label: 'smoothness',
          value: _smoothness,
          min: 0,
          max: 0.4,
          hint: 'Width of the soft edge',
          onChanged: (v) => setState(() => _smoothness = v),
        ),
        _buildSlider(
          label: 'spill',
          value: _spill,
          min: 0,
          max: 1,
          hint: 'How much of the green cast is pulled off the subject',
          onChanged: (v) => setState(() => _spill = v),
        ),
        FilledButton.icon(
          onPressed: _render,
          icon: const Icon(Icons.movie_creation_outlined),
          label: const Text('Render with this key'),
        ),
      ],
    );
  }

  Widget _buildDetectionSummary(ChromaKeyDetection d) {
    final hex = d.color.toARGB32().toRadixString(16).toUpperCase();
    return Text(
      'Detected 0x$hex · spread ${d.spread.toStringAsFixed(3)} · '
      '${(d.coverage * 100).toStringAsFixed(0)}% of the border. '
      'The SMPTE constant sits about 0.12 away from this — margin the key '
      'would have to spend instead of keeping the subject safe.',
      style: const TextStyle(fontSize: 12),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String hint,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(2)}'),
        Text(hint, style: const TextStyle(fontSize: 12)),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
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
          aspectRatio: _canvas.width / _canvas.height,
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
