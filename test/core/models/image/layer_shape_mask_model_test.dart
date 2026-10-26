import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/layer_shape_mask_model.dart'
    show sortLayerShapeMaskKeyframes;
import 'package:pro_video_editor/pro_video_editor.dart';

void main() {
  group(LayerShapeMask, () {
    const keyframes = [
      LayerShapeMaskKeyframe(
        time: Duration(seconds: 2),
        center: Offset(0.7, 0.3),
        size: Size(0.9, 0.4),
        rotation: 1,
        feather: 0.2,
        curve: AnimationCurve.easeOutCubic,
      ),
      LayerShapeMaskKeyframe(time: Duration.zero, size: Size.zero),
    ];
    const mask = LayerShapeMask(
      shape: LayerShapeMaskShape.speechBubble,
      center: Offset(0.25, 0.75),
      size: Size(0.4, 0.2),
      rotation: 0.5,
      feather: 0.1,
      cornerRadius: 0.3,
      invert: true,
      mirrored: true,
      keyframes: keyframes,
    );

    group('toMap', () {
      test('writes every field the renderers read', () {
        expect(mask.toMap(), {
          'shape': 'speechBubble',
          'x': 0.25,
          'y': 0.75,
          'width': 0.4,
          'height': 0.2,
          'rotation': 0.5,
          'feather': 0.1,
          'cornerRadius': 0.3,
          'invert': true,
          'mirrored': true,
          'keyframes': [
            {
              'timeUs': 0,
              'x': 0.5,
              'y': 0.5,
              'width': 0.0,
              'height': 0.0,
              'rotation': 0.0,
              'feather': 0.0,
              'curve': 'linear',
            },
            {
              'timeUs': 2000000,
              'x': 0.7,
              'y': 0.3,
              'width': 0.9,
              'height': 0.4,
              'rotation': 1.0,
              'feather': 0.2,
              'curve': 'easeOutCubic',
            },
          ],
        });
      });
    });

    group('fromMap', () {
      test('reads what toMap writes, keyframes in time order', () {
        expect(
          LayerShapeMask.fromMap(mask.toMap()),
          mask.copyWith(keyframes: sortLayerShapeMaskKeyframes(keyframes)),
        );
      });

      test('falls back to an ellipse and keeps values in range', () {
        final read = LayerShapeMask.fromMap(const {
          'shape': 'spiral',
          'feather': -1,
          'cornerRadius': 4,
          'keyframes': [
            {'timeUs': 5, 'feather': -2, 'curve': 'wobble'},
          ],
        });

        expect(read.shape, LayerShapeMaskShape.ellipse);
        expect(read.center, const Offset(0.5, 0.5));
        expect(read.feather, 0);
        expect(read.cornerRadius, 1);
        expect(read.keyframes.single.feather, 0);
        expect(read.keyframes.single.curve, AnimationCurve.linear);
      });
    });

    test('copyWith replaces only the fields given', () {
      final copy = mask.copyWith(invert: false, keyframes: const []);

      expect(copy.invert, isFalse);
      expect(copy.keyframes, isEmpty);
      expect(copy.copyWith(invert: true, keyframes: keyframes), mask);
    });

    test('keyframes take part in equality', () {
      expect(mask.copyWith(keyframes: const []), isNot(mask));
      expect(
        mask.copyWith(keyframes: List.of(keyframes)).hashCode,
        mask.hashCode,
      );
    });
  });

  group('shapeMask on a layer', () {
    final image = EditorLayerImage.memory(Uint8List.fromList([1, 2, 3]));
    const shapeMask = LayerShapeMask(
      shape: LayerShapeMaskShape.heart,
      keyframes: [LayerShapeMaskKeyframe(time: Duration(seconds: 1))],
    );

    test('an ImageLayer keeps it through toMap, fromMap and copyWith', () {
      final layer = ImageLayer(image: image, shapeMask: shapeMask);

      expect(ImageLayer.fromMap(layer.toMap()).shapeMask, shapeMask);
      expect(layer.copyWith(loop: false).shapeMask, shapeMask);
      expect(layer, isNot(ImageLayer(image: image)));
    });

    test('a VideoLayer keeps it through toMap, fromMap and copyWith', () {
      final layer = VideoLayer(
        clips: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        shapeMask: shapeMask,
      );

      expect(VideoLayer.fromMap(layer.toMap()).shapeMask, shapeMask);
      expect(layer.copyWith(opacity: 0.5).shapeMask, shapeMask);
      expect(
        layer,
        isNot(
          layer.copyWith(
            shapeMask: const LayerShapeMask(shape: LayerShapeMaskShape.star),
          ),
        ),
      );
    });

    test('a VideoLayer sends it over the platform channel', () async {
      final map = await VideoLayer(
        clips: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        shapeMask: shapeMask,
      ).toAsyncMap();

      expect(map['shapeMask'], shapeMask.toMap());
    });

    test('an ImageLayer sends it over the platform channel', () async {
      final map = await VideoRenderData(
        id: 'test',
        videoSegments: [VideoSegment(video: EditorVideo.file('test.mp4'))],
        imageLayers: [
          ImageLayer(image: image, shapeMask: shapeMask),
          ImageLayer(image: image),
        ],
      ).toAsyncMap();
      final layers = (map['imageLayers'] as List).cast<Map<String, dynamic>>();

      expect(layers.first['shapeMask'], shapeMask.toMap());
      expect(layers.last['shapeMask'], isNull);
    });

    test('an ImageLayer refuses one on a censor area', () {
      expect(
        () => ImageLayer(
          image: image,
          censor: const LayerCensor.blur(),
          shapeMask: shapeMask,
        ),
        throwsAssertionError,
      );
    });
  });
}
