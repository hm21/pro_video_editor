import 'dart:math' as math;

import 'package:flutter/material.dart';

import '/core/models/audio/waveform_data_model.dart';
import '../models/waveform_style.dart';

/// Custom painter for rendering static waveform data.
///
/// Renders [WaveformData] as vertical bars with support for mono/stereo,
/// played/unplayed coloring, and position indicators.
class WaveformPainter extends CustomPainter {
  /// Creates a [WaveformPainter].
  WaveformPainter({
    required this.waveform,
    required this.style,
    this.currentPosition,
    this.showPositionIndicator = false,
  });

  /// The waveform data to render.
  final WaveformData waveform;

  /// Visual styling options.
  final WaveformStyle style;

  /// Current playback position.
  final Duration? currentPosition;

  /// Whether to show the position indicator line.
  final bool showPositionIndicator;

  @override
  void paint(Canvas canvas, Size size) {
    final samples = waveform.leftChannel;
    if (samples.isEmpty) return;

    final totalBarWidth = style.barWidth + style.barSpacing;
    final barsCount = (size.width / totalBarWidth).floor();
    if (barsCount == 0) return;

    final samplesPerBar = samples.length / barsCount;
    final centerY = size.height / 2;
    final maxAmplitude = waveform.isStereo
        ? size.height / 4 - 2
        : size.height / 2 - 2;

    // Calculate position for played/unplayed coloring
    final positionRatio =
        currentPosition != null && waveform.duration.inMilliseconds > 0
        ? currentPosition!.inMilliseconds / waveform.duration.inMilliseconds
        : 0.0;
    final playedBars = (barsCount * positionRatio).floor();

    // Prepare paints
    final unplayedPaint = Paint()
      ..color = style.waveColor
      ..strokeWidth = style.barWidth
      ..strokeCap = StrokeCap.round;

    final playedPaint = Paint()
      ..color = style.waveColorPlayed ?? style.waveColor
      ..strokeWidth = style.barWidth
      ..strokeCap = StrokeCap.round;

    // Draw waveform bars
    for (int i = 0; i < barsCount; i++) {
      final startIdx = (i * samplesPerBar).floor();
      final endIdx = ((i + 1) * samplesPerBar).floor().clamp(0, samples.length);

      // Find peak in this range
      double leftPeak = 0;
      double rightPeak = 0;

      for (int j = startIdx; j < endIdx; j++) {
        leftPeak = math.max(leftPeak, samples[j]);
        if (waveform.rightChannel != null) {
          rightPeak = math.max(rightPeak, waveform.rightChannel![j]);
        }
      }

      final x = i * totalBarWidth + style.barWidth / 2;
      final isPlayed = i < playedBars;

      if (waveform.isStereo) {
        // Stereo: left channel above center, right below
        final leftHeight = (leftPeak * maxAmplitude).clamp(
          style.minBarHeight,
          maxAmplitude,
        );
        final rightHeight = (rightPeak * maxAmplitude).clamp(
          style.minBarHeight,
          maxAmplitude,
        );

        final paint = isPlayed ? playedPaint : unplayedPaint;

        // Left channel (above center)
        canvas
          ..drawLine(
            Offset(x, centerY - 1),
            Offset(x, centerY - 1 - leftHeight),
            paint,
          )
          // Right channel (below center)
          ..drawLine(
            Offset(x, centerY + 1),
            Offset(x, centerY + 1 + rightHeight),
            paint,
          );
      } else {
        // Mono: symmetric around center
        final height = (leftPeak * maxAmplitude).clamp(
          style.minBarHeight,
          maxAmplitude,
        );
        canvas.drawLine(
          Offset(x, centerY - height),
          Offset(x, centerY + height),
          isPlayed ? playedPaint : unplayedPaint,
        );
      }
    }

    // Draw center line for stereo
    if (waveform.isStereo && style.showCenterLine) {
      final linePaint = Paint()
        ..color =
            style.centerLineColor ?? style.waveColor.withValues(alpha: 0.3)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(0, centerY),
        Offset(size.width, centerY),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.style != style;
  }
}
