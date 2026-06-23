import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '/core/models/audio/waveform_chunk_model.dart';
import '/core/models/audio/waveform_configs_model.dart';
import '/core/platform/platform_interface.dart';
import '../models/waveform_style.dart';

/// Animated widget for streaming waveform that animates bars as they appear.
///
/// This widget internally manages the waveform stream - you only provide
/// the [config] and it handles subscribing, accumulating chunks, and
/// animating the bars as they arrive.
class StreamingWaveform extends StatefulWidget {
  /// Creates a [StreamingWaveform].
  const StreamingWaveform(
    this.config, {
    super.key,
    required this.style,
    this.onDurationAvailable,
    this.onComplete,
  });

  /// The waveform configuration for streaming generation.
  final WaveformConfigs config;

  /// Visual styling options.
  final WaveformStyle style;

  /// Called when the total duration becomes available from the stream.
  final ValueChanged<Duration>? onDurationAvailable;

  /// Called when the streaming waveform generation is complete.
  final VoidCallback? onComplete;

  @override
  State<StreamingWaveform> createState() => _StreamingWaveformState();
}

class _StreamingWaveformState extends State<StreamingWaveform> {
  final _id = DateTime.now().microsecondsSinceEpoch;

  double _lastKnownWidth = 0;

  // Accumulated chunks from the stream
  final List<WaveformChunk> _chunks = [];

  // Cached computed values - only recalculated when chunks change
  List<double> _allLeftSamples = [];
  int _totalSamples = 0;
  int _expectedTotalSamples = 0;
  double _progress = 0;
  bool _isComplete = false;
  bool _isStereo = false;
  Duration _lastReportedDuration = Duration.zero;
  bool _hasCalledComplete = false;

  // Cached bar heights - recalculated when chunks or width changes
  List<double> _barHeights = [];
  int _totalBarsCount = 50;

  // Stream subscription
  StreamSubscription<WaveformChunk>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = ProVideoEditor.instance
        .getWaveformStream(widget.config)
        .listen(_onChunkReceived);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onChunkReceived(WaveformChunk chunk) {
    // Only process if it's a new chunk
    if (_chunks.isNotEmpty && _chunks.last.startIndex == chunk.startIndex) {
      return;
    }

    _chunks.add(chunk);
    _recalculateSamples();

    // Trigger rebuild with updated bar heights
    if (mounted) setState(() {});
  }

  void _recalculateSamples() {
    if (_chunks.isEmpty) {
      _allLeftSamples = [];
      _totalSamples = 0;
      _progress = 0;
      _isComplete = false;
      _isStereo = false;
      return;
    }

    // Build flat sample list
    final leftSamples = <double>[];
    for (final chunk in _chunks) {
      leftSamples.addAll(chunk.leftChannel);
    }
    _allLeftSamples = leftSamples;
    _totalSamples = _chunks.fold<int>(0, (sum, c) => sum + c.sampleCount);

    final lastChunk = _chunks.last;
    _progress = lastChunk.progress;
    _isComplete = _progress >= 0.99;
    _isStereo = _chunks.first.isStereo;

    // Calculate expected total samples from duration and samplesPerSecond
    if (_expectedTotalSamples == 0 && lastChunk.totalDuration > Duration.zero) {
      _expectedTotalSamples = (lastChunk.totalDuration.inMilliseconds /
              1000 *
              lastChunk.samplesPerSecond)
          .round();
    }

    // Report duration when it becomes available
    if (lastChunk.totalDuration != _lastReportedDuration) {
      _lastReportedDuration = lastChunk.totalDuration;
      widget.onDurationAvailable?.call(lastChunk.totalDuration);
    }

    // Notify when streaming is complete
    if (_isComplete && !_hasCalledComplete) {
      _hasCalledComplete = true;
      widget.onComplete?.call();
    }

    // Recalculate bar heights if we know the width
    if (_lastKnownWidth > 0) {
      _recalculateBarHeights();
    }
  }

  void _recalculateBarHeights() {
    final totalBarWidth = widget.style.barWidth + widget.style.barSpacing;
    final barsCount = (_lastKnownWidth / totalBarWidth).floor();
    if (barsCount == 0) {
      _barHeights = [];
      _totalBarsCount = 50;
      return;
    }

    _totalBarsCount = barsCount;

    // Use expected total samples if available, otherwise estimate from progress
    final effectiveTotalSamples = _expectedTotalSamples > 0
        ? _expectedTotalSamples
        : (_progress > 0 ? (_totalSamples / _progress).round() : _totalSamples);

    if (effectiveTotalSamples == 0) {
      _barHeights = List.filled(barsCount, 0.0);
      return;
    }

    final samplesPerBar = effectiveTotalSamples / barsCount;
    final maxAmplitude =
        _isStereo ? widget.style.height / 4 - 2 : widget.style.height / 2 - 2;

    // Pre-calculate all bar heights (including zeros for bars without data yet)
    final heights = <double>[];
    for (var i = 0; i < barsCount; i++) {
      final startIdx = (i * samplesPerBar).floor();
      final endIdx = ((i + 1) * samplesPerBar).floor();

      // Check if we have data for this bar
      if (startIdx >= _allLeftSamples.length) {
        // No data yet - show minimum height bar
        heights.add(0.0);
        continue;
      }

      final clampedEndIdx = endIdx.clamp(0, _allLeftSamples.length);
      double leftPeak = 0;
      for (int j = startIdx; j < clampedEndIdx; j++) {
        leftPeak = math.max(leftPeak, _allLeftSamples[j]);
      }

      heights.add((leftPeak * maxAmplitude * 2).clamp(4.0, maxAmplitude * 2));
    }

    _barHeights = heights;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Update width for bar calculations
        if (_lastKnownWidth != constraints.maxWidth) {
          _lastKnownWidth = constraints.maxWidth;
          _recalculateBarHeights();
        }

        return RepaintBoundary(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _totalBarsCount; i++)
                _AnimatedWaveformBar(
                  key: ValueKey('pro_image_editor_bar_${_id}_$i'),
                  height: i < _barHeights.length ? _barHeights[i] : 0.0,
                  style: widget.style,
                  spacing:
                      i < _totalBarsCount - 1 ? widget.style.barSpacing : 0,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A single animated bar in the streaming waveform.
///
/// Uses [TweenAnimationBuilder] to animate from [minHeight] to [height] when
/// first appearing or when height changes.
class _AnimatedWaveformBar extends StatelessWidget {
  const _AnimatedWaveformBar({
    super.key,
    required this.height,
    required this.style,
    required this.spacing,
  });

  final double height;
  final WaveformStyle style;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    // Use minHeight if height is 0 (no data yet)
    final targetHeight = height > 0 ? height : style.minBarHeight;

    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: style.minBarHeight, end: targetHeight),
        duration: style.animationDuration,
        curve: Curves.easeOutCubic,
        builder: (context, animatedHeight, child) {
          return Container(
            margin: EdgeInsets.only(right: spacing),
            width: style.barWidth,
            height: animatedHeight,
            decoration: BoxDecoration(
              color: style.waveColor,
              borderRadius: BorderRadius.circular(style.barWidth / 2),
            ),
          );
        },
      ),
    );
  }
}
