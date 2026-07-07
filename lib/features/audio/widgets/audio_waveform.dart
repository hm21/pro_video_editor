import 'package:flutter/material.dart';
import 'package:pro_video_editor/core/models/audio/waveform_configs_model.dart';
import 'package:pro_video_editor/features/audio/widgets/streaming_waveform.dart';
import 'package:pro_video_editor/features/audio/widgets/waveform_painter.dart';

import '/core/models/audio/waveform_data_model.dart';
import '../models/waveform_style.dart';

/// A widget that displays an audio waveform visualization.
///
/// This widget renders [WaveformData] as a series of vertical bars representing
/// audio amplitude over time. It supports both mono and stereo audio, with
/// stereo displaying left channel above and right channel below the center
/// line.
///
/// Example usage:
/// ```dart
/// AudioWaveform(
///   waveform: waveformData,
///   style: WaveformStyle(
///     waveColor: Colors.blue,
///     backgroundColor: Colors.black,
///   ),
/// )
/// ```
///
/// For interactive waveforms with selection, use [AudioWaveform.interactive]:
/// ```dart
/// AudioWaveform.interactive(
///   waveform: waveformData,
///   currentPosition: currentPositionMs,
///   onSeek: (positionMs) => player.seek(positionMs),
/// )
/// ```
///
/// For streaming waveforms that update progressively, use
/// [AudioWaveform.streaming]:
/// ```dart
/// AudioWaveform.streaming(
///   config: WaveformConfigs(path: audioPath),
///   style: WaveformStyle(waveColor: Colors.green),
/// )
/// ```
class AudioWaveform extends StatefulWidget {
  /// Creates an [AudioWaveform] widget.
  ///
  /// [waveform] The waveform data to display.
  /// [style] Visual styling options for the waveform.
  const AudioWaveform({
    super.key,
    required this.waveform,
    this.style = const WaveformStyle(),
  }) : config = null,
       currentPosition = null,
       onSeek = null,
       showPositionIndicator = false,
       onComplete = null;

  /// Creates an interactive [AudioWaveform] with position indicator and
  /// seek support.
  ///
  /// [waveform] The waveform data to display.
  /// [currentPosition] Current playback position.
  /// [onSeek] Callback when user taps to seek.
  /// [style] Visual styling options for the waveform.
  const AudioWaveform.interactive({
    super.key,
    required this.waveform,
    required this.currentPosition,
    required this.onSeek,
    this.style = const WaveformStyle(),
  }) : config = null,
       showPositionIndicator = true,
       onComplete = null;

  /// Creates a streaming [AudioWaveform] that displays chunks progressively.
  ///
  /// This constructor is designed for use with streaming waveform generation,
  /// where chunks arrive over time. The waveform grows from left to right
  /// as new chunks are added.
  ///
  /// The widget internally manages the stream - you only need to provide
  /// the [config] and the widget handles everything else.
  ///
  /// [config] The waveform configuration for streaming generation.
  /// [style] Visual styling options for the waveform.
  /// [showPositionIndicator] Whether to show the streaming progress indicator.
  /// [onComplete] Called when the streaming waveform generation is complete.
  const AudioWaveform.streaming({
    super.key,
    required WaveformConfigs this.config,
    this.style = const WaveformStyle(),
    this.onSeek,
    this.showPositionIndicator = false,
    this.currentPosition,
    this.onComplete,
  }) : waveform = null;

  /// The waveform data to render (for non-streaming mode).
  final WaveformData? waveform;

  /// The waveform configuration for streaming mode.
  final WaveformConfigs? config;

  /// Visual styling options for the waveform.
  final WaveformStyle style;

  /// Current playback position (for interactive mode).
  final Duration? currentPosition;

  /// Callback when user seeks to a position. Receives position in milliseconds.
  final ValueChanged<Duration>? onSeek;

  /// Whether to show the position indicator line.
  final bool showPositionIndicator;

  /// Called when streaming waveform generation is complete.
  final VoidCallback? onComplete;

  /// Whether this widget is in streaming mode.
  bool get isStreaming => config != null;

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform> {
  Duration _streamingDuration = Duration.zero;

  Duration get _duration => widget.isStreaming
      ? _streamingDuration
      : (widget.waveform?.duration ?? Duration.zero);

  void _handleTap(TapDownDetails details) {
    final box = context.findRenderObject() as RenderBox;
    final position = details.localPosition.dx / box.size.width;
    final seekMs = (position * _duration.inMilliseconds).round();
    widget.onSeek?.call(
      Duration(milliseconds: seekMs.clamp(0, _duration.inMilliseconds)),
    );
  }

  void _handleDrag(DragUpdateDetails details) {
    final box = context.findRenderObject() as RenderBox;
    final position = details.localPosition.dx / box.size.width;
    final seekMs = (position * _duration.inMilliseconds).round();
    widget.onSeek?.call(
      Duration(milliseconds: seekMs.clamp(0, _duration.inMilliseconds)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enableSeekInteraction =
        widget.onSeek != null && _duration > Duration.zero;

    return Container(
      height: widget.style.height,
      decoration: BoxDecoration(
        color: widget.style.backgroundColor,
        borderRadius: widget.style.borderRadius,
      ),
      clipBehavior: Clip.hardEdge,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enableSeekInteraction ? _handleTap : null,
        onHorizontalDragUpdate: enableSeekInteraction ? _handleDrag : null,
        child: widget.showPositionIndicator
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final positionRatio =
                      widget.currentPosition != null &&
                          _duration > Duration.zero
                      ? widget.currentPosition!.inMilliseconds /
                            _duration.inMilliseconds
                      : 0.0;
                  final indicatorPosition =
                      (constraints.maxWidth * positionRatio).clamp(
                        0.0,
                        constraints.maxWidth - 2,
                      );

                  return Stack(
                    alignment: AlignmentGeometry.center,
                    fit: StackFit.expand,
                    children: [
                      _buildWaveForm(),
                      if (widget.currentPosition != null) ...[
                        // Played overlay (before indicator)
                        if (widget.style.playedOverlayColor != null)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: indicatorPosition,
                            child: Container(
                              color: widget.style.playedOverlayColor!,
                            ),
                          ),
                        // Unplayed overlay (after indicator)
                        if (widget.style.unplayedOverlayColor != null)
                          Positioned(
                            left: indicatorPosition + 2,
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              color: widget.style.unplayedOverlayColor!,
                            ),
                          ),
                        // Position indicator line
                        Positioned(
                          left: indicatorPosition,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 2,
                            color:
                                widget.style.positionIndicatorColor ??
                                widget.style.waveColor,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              )
            : _buildWaveForm(),
      ),
    );
  }

  Widget _buildWaveForm() {
    // Standard waveform rendering
    return widget.isStreaming
        ? StreamingWaveform(
            widget.config!,
            style: widget.style,
            onDurationAvailable: (duration) {
              if (_streamingDuration != duration) {
                setState(() => _streamingDuration = duration);
              }
            },
            onComplete: widget.onComplete,
          )
        : CustomPaint(
            size: Size(double.infinity, widget.style.height),
            painter: WaveformPainter(
              waveform: widget.waveform!,
              style: widget.style,
              currentPosition: widget.currentPosition,
              showPositionIndicator: widget.showPositionIndicator,
            ),
          );
  }
}
