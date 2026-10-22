import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_blend_mode_model.dart';

void main() {
  group('LayerBlendMode', () {
    group('blendMode', () {
      test('names the Flutter mode a preview paints the layer with', () {
        expect(
          {for (final mode in LayerBlendMode.values) mode: mode.blendMode},
          {
            LayerBlendMode.normal: BlendMode.srcOver,
            LayerBlendMode.multiply: BlendMode.multiply,
            LayerBlendMode.screen: BlendMode.screen,
            LayerBlendMode.overlay: BlendMode.overlay,
            LayerBlendMode.softLight: BlendMode.softLight,
            LayerBlendMode.darken: BlendMode.darken,
            LayerBlendMode.lighten: BlendMode.lighten,
            LayerBlendMode.add: BlendMode.plus,
            LayerBlendMode.difference: BlendMode.difference,
          },
        );
      });
    });

    group('fromBlendMode', () {
      test('finds the mode of every Flutter mode it renders', () {
        for (final mode in LayerBlendMode.values) {
          expect(LayerBlendMode.fromBlendMode(mode.blendMode), mode);
        }
      });

      test('returns null for a Flutter mode the render has not', () {
        expect(LayerBlendMode.fromBlendMode(BlendMode.colorBurn), isNull);
        expect(LayerBlendMode.fromBlendMode(BlendMode.xor), isNull);
      });
    });

    group('fromName', () {
      test('reads a stored name back', () {
        expect(LayerBlendMode.fromName('softLight'), LayerBlendMode.softLight);
      });

      test('falls back to normal for a missing or unknown name', () {
        expect(LayerBlendMode.fromName(null), LayerBlendMode.normal);
        expect(LayerBlendMode.fromName('colorBurn'), LayerBlendMode.normal);
        expect(LayerBlendMode.fromName(3), LayerBlendMode.normal);
      });
    });
  });
}
