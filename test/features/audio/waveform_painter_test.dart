import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/features/audio/widgets/waveform_painter.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

WaveformData buildWaveform({
  int samples = 100,
  bool stereo = false,
  Duration duration = const Duration(seconds: 2),
}) {
  final left = Float32List(samples);
  for (var i = 0; i < samples; i++) {
    left[i] = (i % 10) / 10;
  }
  Float32List? right;
  if (stereo) {
    right = Float32List(samples);
    for (var i = 0; i < samples; i++) {
      right[i] = (i % 7) / 7;
    }
  }
  return WaveformData(
    leftChannel: left,
    rightChannel: right,
    sampleRate: 44100,
    duration: duration,
    samplesPerSecond: 50,
  );
}

void paintOnce(WaveformPainter painter, [Size size = const Size(300, 80)]) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  recorder.endRecording();
}

void main() {
  group('WaveformPainter.shouldRepaint', () {
    test('repaints when the playback position changes', () {
      final waveform = buildWaveform();
      const style = WaveformStyle();
      final oldPainter = WaveformPainter(
        waveform: waveform,
        style: style,
        currentPosition: const Duration(seconds: 1),
        showPositionIndicator: true,
      );
      final newPainter = WaveformPainter(
        waveform: waveform,
        style: style,
        currentPosition: const Duration(milliseconds: 1500),
        showPositionIndicator: true,
      );

      expect(newPainter.shouldRepaint(oldPainter), isTrue);
    });

    test('does not repaint when nothing changed', () {
      final waveform = buildWaveform();
      const style = WaveformStyle();
      final oldPainter = WaveformPainter(waveform: waveform, style: style);
      final newPainter = WaveformPainter(waveform: waveform, style: style);

      expect(newPainter.shouldRepaint(oldPainter), isFalse);
    });

    test('repaints when the waveform data changes', () {
      const style = WaveformStyle();
      final oldPainter = WaveformPainter(
        waveform: buildWaveform(samples: 50),
        style: style,
      );
      final newPainter = WaveformPainter(
        waveform: buildWaveform(samples: 80),
        style: style,
      );

      expect(newPainter.shouldRepaint(oldPainter), isTrue);
    });
  });

  group('WaveformPainter.paint', () {
    test('paints mono data without throwing', () {
      final painter = WaveformPainter(
        waveform: buildWaveform(),
        style: const WaveformStyle(),
        currentPosition: const Duration(seconds: 1),
        showPositionIndicator: true,
      );

      expect(() => paintOnce(painter), returnsNormally);
    });

    test('paints stereo data without throwing', () {
      final painter = WaveformPainter(
        waveform: buildWaveform(stereo: true),
        style: const WaveformStyle(),
      );

      expect(() => paintOnce(painter), returnsNormally);
    });

    test('handles an empty waveform gracefully', () {
      final painter = WaveformPainter(
        waveform: WaveformData(
          leftChannel: Float32List(0),
          sampleRate: 44100,
          duration: Duration.zero,
          samplesPerSecond: 50,
        ),
        style: const WaveformStyle(),
      );

      expect(() => paintOnce(painter, const Size(100, 40)), returnsNormally);
    });
  });
}
