import 'dart:io' as io;

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_player/video_player.dart';

/// A widget that displays a preview of a specific [VideoClip].
class ClipsPreviewer extends StatefulWidget {
  /// Creates a [ClipsPreviewer] widget.
  const ClipsPreviewer({
    super.key,
    required this.proController,
    required this.videoConfigs,
    required this.videoClip,
  });

  /// Controls video playback, rendering, and transformations.
  final ProVideoController proController;

  /// Configuration settings for the video editor.
  final VideoEditorConfigs videoConfigs;

  /// The video clip being previewed.
  final VideoClip videoClip;

  @override
  State<ClipsPreviewer> createState() => _ClipsPreviewerState();
}

class _ClipsPreviewerState extends State<ClipsPreviewer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

  bool _isSeeking = false;

  /// Stores the currently selected trim duration span.
  TrimDurationSpan? _durationSpan;

  /// Temporarily stores a pending trim duration span.
  TrimDurationSpan? _tempDurationSpan;

  @override
  void initState() {
    super.initState();
    widget.proController.initialize(
      callbacksAudioFunction: () => const AudioEditorCallbacks(),
      callbacksFunction: () => VideoEditorCallbacks(
        onPause: _controller.pause,
        onPlay: _controller.play,
        onMuteToggle: (isMuted) {
          _controller.setVolume(isMuted ? 0 : 100);
        },
        onTrimSpanUpdate: (durationSpan) {
          if (_controller.value.isPlaying) {
            widget.proController.pause();
          }
        },
        onTrimSpanEnd: _seekToPosition,
      ),
      configsFunction: () => widget.videoConfigs,
    );

    _initializePlayer();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _initializePlayer() async {
    final video = widget.videoClip.clip;
    if (video.hasFile) {
      _controller = VideoPlayerController.file(io.File(video.file!.path));
    } else if (video.hasAssetPath) {
      _controller = VideoPlayerController.asset(video.assetPath!);
    } else if (video.hasNetworkUrl) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(video.networkUrl!),
      );
    } else {
      final directory = await getApplicationCacheDirectory();
      final file = io.File('${directory.path}/temp.mp4');
      await file.writeAsBytes(video.bytes!);

      _controller = VideoPlayerController.file(file);
    }

    await Future.wait([
      //  setMetadata(),
      _controller.initialize(),
      _controller.setVolume(widget.videoConfigs.initialMuted ? 0 : 100),
    ]);
    final meta = await ProVideoEditor.instance.getMetadata(
      EditorVideo.autoSource(
        file: video.file,
        byteArray: video.bytes,
        assetPath: video.assetPath,
        networkUrl: video.networkUrl,
      ),
    );

    /// Listen to play time
    _controller.addListener(() {
      if (!mounted) return;

      var totalVideoDuration = meta.duration;
      var duration = _controller.value.position;
      widget.proController.setPlayTime(duration);

      if (_isSeeking) return;

      if (_tempDurationSpan != null && duration >= _tempDurationSpan!.end) {
        _seekToPosition(_tempDurationSpan!);
      } else if (duration >= totalVideoDuration) {
        _seekToPosition(
          TrimDurationSpan(
            start: Duration.zero,
            end: widget.videoClip.duration,
          ),
        );
      }
    });

    _isInitialized = true;
    setState(() {});
  }

  Future<void> _seekToPosition(TrimDurationSpan span) async {
    _durationSpan = span;

    if (_isSeeking) {
      _tempDurationSpan = span; // Store the latest seek request
      return;
    }
    _isSeeking = true;

    widget.proController.pause();
    widget.proController.setPlayTime(_durationSpan!.start);

    await _controller.pause();
    await _controller.seekTo(span.start);

    _isSeeking = false;

    // Check if there's a pending seek request
    if (_tempDurationSpan != null) {
      TrimDurationSpan nextSeek = _tempDurationSpan!;
      _tempDurationSpan = null; // Clear the pending seek
      await _seekToPosition(nextSeek); // Process the latest request
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 400),
      opacity: _isInitialized ? 1 : 0,
      child: _isInitialized
          ? Center(
              child: AspectRatio(
                aspectRatio: _controller.value.size.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
