import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_audio_visualizer_model.dart';
import 'package:pro_video_editor/features/audio_visualizer/audio_visualizer_shapes.dart';

/// The numbers in this file are repeated in the native tests,
/// `AudioVisualizerShapesTest.kt` and the darwin `RunnerTests`, so all three
/// renderers draw the same shapes. Change them together.
void main() {
  Matcher bar(
    double left,
    double top,
    double right,
    double bottom,
    double radius, {
    double pivotX = 0,
    double pivotY = 0,
    double rotation = 0,
  }) => isA<AudioVisualizerBar>()
      .having((b) => b.left, 'left', closeTo(left, 1e-9))
      .having((b) => b.top, 'top', closeTo(top, 1e-9))
      .having((b) => b.right, 'right', closeTo(right, 1e-9))
      .having((b) => b.bottom, 'bottom', closeTo(bottom, 1e-9))
      .having((b) => b.radius, 'radius', closeTo(radius, 1e-9))
      .having((b) => b.pivotX, 'pivotX', closeTo(pivotX, 1e-9))
      .having((b) => b.pivotY, 'pivotY', closeTo(pivotY, 1e-9))
      .having((b) => b.rotation, 'rotation', closeTo(rotation, 1e-9));

  group('audioVisualizerShapes', () {
    test('bars stand on the bottom, a silent one as a dot', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.bars,
        width: 100,
        height: 50,
        levels: const [0, 0.5, 1, 0.2],
      );

      expect(shapes.wave, isNull);
      expect(shapes.bars, [
        bar(3.75, 32.5, 21.25, 50, 8.75),
        bar(28.75, 25, 46.25, 50, 8.75),
        bar(53.75, 0, 71.25, 50, 8.75),
        bar(78.75, 32.5, 96.25, 50, 8.75),
      ]);
    });

    test('mirrored bars grow from the middle', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.mirroredBars,
        width: 100,
        height: 50,
        levels: const [0, 0.5, 1, 0.2],
      );

      expect(shapes.bars, [
        bar(3.75, 16.25, 21.25, 33.75, 8.75),
        bar(28.75, 12.5, 46.25, 37.5, 8.75),
        bar(53.75, 0, 71.25, 50, 8.75),
        bar(78.75, 16.25, 96.25, 33.75, 8.75),
      ]);
    });

    test('a circle mirrors the bands down both sides of its ring', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.circle,
        width: 200,
        height: 100,
        levels: const [1, 0],
      );

      expect(shapes.bars, [
        bar(
          -6.25,
          -50,
          6.25,
          -25,
          6.25,
          pivotX: 100,
          pivotY: 50,
          rotation: math.pi / 4,
        ),
        bar(
          -6.25,
          -37.5,
          6.25,
          -25,
          6.25,
          pivotX: 100,
          pivotY: 50,
          rotation: 3 * math.pi / 4,
        ),
        bar(
          -6.25,
          -37.5,
          6.25,
          -25,
          6.25,
          pivotX: 100,
          pivotY: 50,
          rotation: 5 * math.pi / 4,
        ),
        bar(
          -6.25,
          -50,
          6.25,
          -25,
          6.25,
          pivotX: 100,
          pivotY: 50,
          rotation: 7 * math.pi / 4,
        ),
      ]);
    });

    test('a bar fills the share of its slot it is given', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.bars,
        width: 100,
        height: 50,
        levels: const [1, 0],
        barFill: 0.5,
      );

      expect(shapes.bars, [
        bar(12.5, 0, 37.5, 50, 12.5),
        bar(62.5, 25, 87.5, 50, 12.5),
      ]);
    });

    test('a bar fill out of range takes the style\'s own', () {
      for (final style in [
        AudioVisualizerStyle.bars,
        AudioVisualizerStyle.circle,
      ]) {
        final own = audioVisualizerShapes(
          style: style,
          width: 100,
          height: 50,
          levels: const [1, 0],
        ).bars;
        for (final barFill in [0.0, -0.5, 1.5, double.nan]) {
          expect(
            audioVisualizerShapes(
              style: style,
              width: 100,
              height: 50,
              levels: const [1, 0],
              barFill: barFill,
            ).bars,
            own,
            reason: '${style.name}, $barFill',
          );
        }
      }
    });

    test('a ring of bars fills the share of the ring it is given', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.circle,
        width: 200,
        height: 100,
        levels: const [1, 0],
        barFill: 0.2,
      );
      // 2 pi 25 / 4 * 0.2 wide, leaving 25 - that for the loudest bar.
      const barWidth = 7.853981633974483;

      expect(shapes.bars, [
        bar(
          -barWidth / 2,
          -50,
          barWidth / 2,
          -25,
          barWidth / 2,
          pivotX: 100,
          pivotY: 50,
          rotation: math.pi / 4,
        ),
        bar(
          -barWidth / 2,
          -(25 + barWidth),
          barWidth / 2,
          -25,
          barWidth / 2,
          pivotX: 100,
          pivotY: 50,
          rotation: 3 * math.pi / 4,
        ),
        bar(
          -barWidth / 2,
          -(25 + barWidth),
          barWidth / 2,
          -25,
          barWidth / 2,
          pivotX: 100,
          pivotY: 50,
          rotation: 5 * math.pi / 4,
        ),
        bar(
          -barWidth / 2,
          -50,
          barWidth / 2,
          -25,
          barWidth / 2,
          pivotX: 100,
          pivotY: 50,
          rotation: 7 * math.pi / 4,
        ),
      ]);
    });

    test('a wave tapers at the edges and stays inside the box', () {
      final shapes = audioVisualizerShapes(
        style: AudioVisualizerStyle.wave,
        width: 40,
        height: 20,
        levels: const [0.5, 1],
      );

      expect(shapes.bars, isEmpty);
      expect(shapes.wave, [
        for (final value in const [
          0, 10, //
          1.6666666667, 9.1666666667, 5, 6.6666666667, 10, 5,
          15, 3.3333333333, 25, 0, 30, 0,
          35, 0.8333333333, 38.3333333333, 8.3333333333, 40, 10,
          38.3333333333, 11.6666666667, 35, 19.1666666667, 30, 20,
          25, 20, 15, 16.6666666667, 10, 15,
          5, 13.3333333333, 1.6666666667, 10.8333333333, 0, 10,
        ])
          closeTo(value, 1e-9),
      ]);
    });

    test('a silent wave keeps a thin line', () {
      final wave = audioVisualizerShapes(
        style: AudioVisualizerStyle.wave,
        width: 10,
        height: 100,
        levels: const [0],
      ).wave!;

      // The point of the band, on the top and on the bottom.
      expect(wave[6], 5);
      expect(wave[7], closeTo(48, 1e-9));
      expect(wave[19], closeTo(52, 1e-9));
    });

    test('a NaN level counts as silent', () {
      for (final style in AudioVisualizerStyle.values) {
        final silent = audioVisualizerShapes(
          style: style,
          width: 100,
          height: 50,
          levels: const [0, 1],
        );
        final broken = audioVisualizerShapes(
          style: style,
          width: 100,
          height: 50,
          levels: const [double.nan, 1],
        );
        expect(broken.bars, silent.bars, reason: style.name);
        expect(broken.wave, silent.wave, reason: style.name);
      }
    });

    test('draws nothing without bands or without a box', () {
      for (final style in AudioVisualizerStyle.values) {
        final empty = audioVisualizerShapes(
          style: style,
          width: 0,
          height: 10,
          levels: const [1],
        );
        expect(empty.bars, isEmpty);
        expect(empty.wave, isNull);
        expect(
          audioVisualizerShapes(
            style: style,
            width: 10,
            height: 10,
            levels: const [],
          ).bars,
          isEmpty,
        );
      }
    });
  });
}
