import 'dart:io';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/shared/utils/render_cancel_capability.dart';
import 'package:pro_video_editor_example/shared/widgets/video_renderer_progress.dart';
import 'package:video_player/video_player.dart';

import '/core/constants/example_constants.dart';
import '/shared/utils/bytes_formatter.dart';
import '/shared/widgets/native_log_console.dart';

/// A page demonstrating video effects: a live preview with
/// [VideoEffectPreview] and an export that renders the same picture.
class VideoEffectsExamplePage extends StatefulWidget {
  /// Creates a [VideoEffectsExamplePage].
  const VideoEffectsExamplePage({super.key});

  @override
  State<VideoEffectsExamplePage> createState() =>
      _VideoEffectsExamplePageState();
}

class _VideoEffectsExamplePageState extends State<VideoEffectsExamplePage>
    with SingleTickerProviderStateMixin {
  final _pve = ProVideoEditor.instance;

  /// Only the first seconds are rendered, to keep the export quick.
  static const _renderLength = Duration(seconds: 5);

  late final VideoPlayerController _source;
  final _position = ValueNotifier<Duration>(Duration.zero);
  late final Ticker _ticker;

  /// The player reports its position ten times a second; the ticker fills
  /// the gaps, so an effect that changes 24 times a second previews smoothly.
  Duration _reportedPosition = Duration.zero;
  Duration _reportedAt = Duration.zero;
  Duration _elapsed = Duration.zero;

  VideoEffectType? _type = VideoEffectType.glitch;
  double _intensity = 0.8;
  bool _onlyOneSecond = false;

  VideoPlayerController? _controllerOutput;
  ChewieController? _chewieControllerOutput;
  bool _isOutputInitialized = false;
  bool _isExporting = false;
  Uint8List? _videoBytes;
  Duration _generationTime = Duration.zero;
  String _taskId = DateTime.now().microsecondsSinceEpoch.toString();

  bool get _supportsCancel => canCancelOnCurrentPlatform();

  List<VideoEffect> get _effects => [
    if (_type != null)
      VideoEffect(
        type: _type!,
        intensity: _intensity,
        startTime: _onlyOneSecond ? const Duration(seconds: 1) : null,
        endTime: _onlyOneSecond ? const Duration(seconds: 2) : null,
      ),
  ];

  @override
  void initState() {
    super.initState();
    VideoEffectPreview.precache();
    _source = VideoPlayerController.asset(kVideoEditorExampleH264Path)
      ..addListener(_onSourceChanged)
      ..setLooping(true);
    _source.initialize().then((_) {
      if (!mounted) return;
      _source.play();
      setState(() {});
    });
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _source.dispose();
    _position.dispose();
    _chewieControllerOutput?.dispose();
    _controllerOutput?.dispose();
    super.dispose();
  }

  void _onSourceChanged() {
    _reportedPosition = _source.value.position;
    _reportedAt = _elapsed;
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    final value = _source.value;
    if (!value.isInitialized) return;
    var position = _reportedPosition;
    if (value.isPlaying) position += elapsed - _reportedAt;
    if (value.duration > Duration.zero && position > value.duration) {
      position = value.duration;
    }
    _position.value = position;
  }

  Future<void> _render() async {
    if (_isExporting) return;

    _taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _isExporting = true;
      _isOutputInitialized = false;
    });
    await _disposeOutput();

    final directory = await getTemporaryDirectory();
    final now = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${directory.path}/video_effect_$now.mp4';

    final data = VideoRenderData(
      id: _taskId,
      videoSegments: [
        VideoSegment(
          video: EditorVideo.asset(kVideoEditorExampleH264Path),
          endTime: _renderLength,
        ),
      ],
      effects: _effects,
    );

    final sw = Stopwatch()..start();
    try {
      await _pve.renderVideoToFile(
        outputPath,
        data,
        nativeLogLevel: NativeLogLevel.debug,
      );
    } on RenderCanceledException {
      if (mounted) setState(() => _isExporting = false);
      return;
    } catch (error) {
      // Brings the controls back, so another render can be started.
      if (!mounted) return;
      setState(() => _isExporting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Render failed: $error')));
      return;
    }
    _generationTime = sw.elapsed;
    _videoBytes = File(outputPath).readAsBytesSync();
    _isExporting = false;

    _controllerOutput = VideoPlayerController.file(File(outputPath));
    await _controllerOutput!.initialize();
    if (!mounted) {
      await _disposeOutput();
      return;
    }
    _chewieControllerOutput = ChewieController(
      videoPlayerController: _controllerOutput!,
      autoPlay: true,
      looping: true,
      placeholder: const ColoredBox(color: Color(0xFF000000)),
    );
    setState(() => _isOutputInitialized = true);
  }

  Future<void> _cancel() async {
    if (!_supportsCancel) return;
    await _pve.cancel(_taskId);
  }

  Future<void> _disposeOutput() async {
    await _chewieControllerOutput?.pause();
    _chewieControllerOutput?.dispose();
    _chewieControllerOutput = null;
    final controller = _controllerOutput;
    _controllerOutput = null;
    await controller?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Video Effects')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            _buildLivePreview(),
            if (_isExporting)
              VideoRendererProgressPanel(
                progressStream: _pve.progressStreamById(_taskId),
                supportsCancel: _supportsCancel,
                onCancel: _supportsCancel ? _cancel : null,
              )
            else
              _buildControls(),
            if (_videoBytes != null) _buildOutput(),
            NativeLogConsole(logStream: _pve.logStream),
          ],
        ),
      ),
    );
  }

  Widget _buildLivePreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 5,
      children: [
        const Text('Live preview'),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _source.value.isInitialized
              ? VideoEffectPreview(
                  effects: _effects,
                  position: _position,
                  child: VideoPlayer(_source),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
        if (!VideoEffectPreview.isSupported)
          const Text(
            'This renderer cannot run the preview shader (Impeller only). '
            'The export still applies the effect.',
            style: TextStyle(fontSize: 12),
          ),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in <VideoEffectType?>[
              null,
              ...VideoEffectType.values,
            ])
              ChoiceChip(
                label: Text(type?.name ?? 'none'),
                selected: _type == type,
                onSelected: (_) => setState(() => _type = type),
              ),
          ],
        ),
        Text('intensity: ${_intensity.toStringAsFixed(2)}'),
        Slider(
          value: _intensity,
          onChanged: (v) => setState(() => _intensity = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Only from 1 s to 2 s'),
          value: _onlyOneSecond,
          onChanged: (v) => setState(() => _onlyOneSecond = v),
        ),
        FilledButton.icon(
          onPressed: _render,
          icon: const Icon(Icons.movie_creation_outlined),
          label: Text('Render the first ${_renderLength.inSeconds} s'),
        ),
      ],
    );
  }

  Widget _buildOutput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 5,
      children: [
        const Text('Output-Video'),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _isOutputInitialized
              ? Chewie(controller: _chewieControllerOutput!)
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
