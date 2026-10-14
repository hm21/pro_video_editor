import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_audio_visualizer_model.dart';

void main() {
  group('LayerAudioVisualizer', () {
    // Two bands, ten rows a second: [0, 1] at 0 s, [1, 0] at 0.1 s.
    final visualizer = LayerAudioVisualizer(
      style: AudioVisualizerStyle.bars,
      bandCount: 2,
      levels: Float32List.fromList([0, 1, 1, 0]),
      framesPerSecond: 10,
    );

    group('levelsAt', () {
      test('reads a row at its own time', () {
        expect(visualizer.levelsAt(Duration.zero), [0, 1]);
        expect(visualizer.levelsAt(const Duration(milliseconds: 100)), [1, 0]);
      });

      test('mixes the rows around a time between them', () {
        expect(visualizer.levelsAt(const Duration(milliseconds: 25)), [
          closeTo(0.25, 1e-6),
          closeTo(0.75, 1e-6),
        ]);
      });

      test('fades to silence after the last row and before the first', () {
        expect(visualizer.levelsAt(const Duration(milliseconds: 150)), [
          closeTo(0.5, 1e-6),
          0,
        ]);
        expect(visualizer.levelsAt(const Duration(milliseconds: 200)), [0, 0]);
        expect(visualizer.levelsAt(const Duration(milliseconds: -50)), [
          0,
          closeTo(0.5, 1e-6),
        ]);
      });

      test('clamps levels outside 0 to 1', () {
        final loud = LayerAudioVisualizer(
          style: AudioVisualizerStyle.wave,
          bandCount: 1,
          levels: Float32List.fromList([4, -2]),
          framesPerSecond: 1,
        );

        expect(loud.levelsAt(Duration.zero), [1]);
        expect(loud.levelsAt(const Duration(seconds: 1)), [0]);
      });

      test('counts a NaN level as silent', () {
        final broken = LayerAudioVisualizer(
          style: AudioVisualizerStyle.bars,
          bandCount: 1,
          levels: Float32List.fromList([double.nan, 1]),
          framesPerSecond: 1,
        );

        expect(broken.levelsAt(Duration.zero), [0]);
        expect(broken.levelsAt(const Duration(milliseconds: 500)), [0.5]);
      });

      test('writes into a list of the right length', () {
        final into = Float32List(2);

        expect(
          identical(visualizer.levelsAt(Duration.zero, into), into),
          isTrue,
        );
        expect(into, [0, 1]);
      });
    });

    test('asserts a finite rate above 0', () {
      for (final rate in [0.0, double.infinity]) {
        expect(
          () => LayerAudioVisualizer(
            style: AudioVisualizerStyle.bars,
            bandCount: 1,
            levels: Float32List(1),
            framesPerSecond: rate,
          ),
          throwsAssertionError,
          reason: '$rate',
        );
      }
    });

    test('counts its rows', () {
      expect(visualizer.frameCount, 2);
    });

    group('toMap / fromMap', () {
      test('roundtrip preserves every field', () {
        final source = LayerAudioVisualizer(
          style: AudioVisualizerStyle.circle,
          color: const Color(0x80FF0000),
          bandCount: 2,
          levels: Float32List.fromList([0.25, 0.5, 0.75, 1]),
          framesPerSecond: 30,
        );

        expect(LayerAudioVisualizer.fromMap(source.toMap()), source);
        expect(LayerAudioVisualizer.fromJson(source.toJson()), source);
      });

      test('the channel map carries the levels as typed data', () {
        final map = visualizer.toChannelMap();

        expect(map['levels'], isA<Float32List>());
        expect(map['style'], 'bars');
        expect(map['color'], 0xFFFFFFFF);
        expect(LayerAudioVisualizer.fromMap(map), visualizer);
      });

      test('roundtrips its bar fill and drops one out of range', () {
        final thin = LayerAudioVisualizer(
          style: AudioVisualizerStyle.bars,
          bandCount: 1,
          levels: Float32List.fromList([0.5]),
          barFill: 0.4,
        );

        expect(LayerAudioVisualizer.fromMap(thin.toMap()).barFill, 0.4);
        expect(LayerAudioVisualizer.fromMap(thin.toChannelMap()), thin);
        expect(
          LayerAudioVisualizer.fromMap({
            'style': 'bars',
            'bandCount': 1,
            'levels': [0.5],
            'barFill': 1.5,
          }).barFill,
          isNull,
        );
      });

      test('keeps the whole rows of a table cut short', () {
        final read = LayerAudioVisualizer.fromMap({
          'style': 'wave',
          'bandCount': 2,
          'levels': [0.5, 0.5, 1],
        });

        expect(read.levels, [0.5, 0.5]);
        expect(read.framesPerSecond, 60);
      });

      test('falls back to 60 rows a second for a rate it cannot use', () {
        for (final rate in [0, -5, double.infinity, double.nan]) {
          final read = LayerAudioVisualizer.fromMap({
            'style': 'bars',
            'bandCount': 1,
            'levels': [0.5],
            'framesPerSecond': rate,
          });
          expect(read.framesPerSecond, 60, reason: '$rate');
        }
      });

      test('throws on an unknown style', () {
        expect(
          () => LayerAudioVisualizer.fromMap({
            'style': 'spiral',
            'bandCount': 1,
            'levels': [0.5],
          }),
          throwsArgumentError,
        );
      });
    });

    test('tells visualizers with other levels apart', () {
      final other = LayerAudioVisualizer(
        style: AudioVisualizerStyle.bars,
        bandCount: 2,
        levels: Float32List.fromList([0, 1, 1, 0.5]),
        framesPerSecond: 10,
      );

      expect(visualizer == other, isFalse);
    });
  });
}
