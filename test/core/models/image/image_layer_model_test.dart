import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/editor_layer_image_model.dart';
import 'package:pro_video_editor/core/models/image/image_layer_model.dart';

void main() {
  group('ImageLayer', () {
    final image = EditorLayerImage.memory(Uint8List.fromList([1, 2, 3]));

    group('toMap', () {
      test('serializes all fields correctly', () {
        final layer = ImageLayer(
          image: image,
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 10),
          offset: const Offset(100, 200),
          size: const Size(300, 150),
        );
        final map = layer.toMap();

        expect(map['image'], isA<Map<String, dynamic>>());
        expect(map['startTime'], 5000000);
        expect(map['endTime'], 10000000);
        expect(map['offset'], {'dx': 100.0, 'dy': 200.0});
        expect(map['size'], {'width': 300.0, 'height': 150.0});
      });

      test('serializes null fields as null', () {
        final layer = ImageLayer(image: image);
        final map = layer.toMap();

        expect(map['startTime'], isNull);
        expect(map['endTime'], isNull);
        expect(map['offset'], isNull);
        expect(map['size'], isNull);
      });
    });

    group('fromMap', () {
      test('deserializes all fields correctly', () {
        final layer = ImageLayer(
          image: image,
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 10),
          offset: const Offset(100, 200),
          size: const Size(300, 150),
        );
        final map = layer.toMap();
        final restored = ImageLayer.fromMap(map);

        expect(restored.startTime, const Duration(seconds: 5));
        expect(restored.endTime, const Duration(seconds: 10));
        expect(restored.offset, const Offset(100, 200));
        expect(restored.size, const Size(300, 150));
      });

      test('handles null optional fields', () {
        final layer = ImageLayer(image: image);
        final map = layer.toMap();
        final restored = ImageLayer.fromMap(map);

        expect(restored.startTime, isNull);
        expect(restored.endTime, isNull);
        expect(restored.offset, isNull);
        expect(restored.size, isNull);
      });

      test('parses numeric strings safely for offset', () {
        final map = {
          'image': image.toMap(),
          'startTime': '3000000',
          'endTime': null,
          'offset': {'dx': '50.5', 'dy': '75.0'},
          'size': {'width': '200.0', 'height': '100.0'},
        };
        final restored = ImageLayer.fromMap(map);

        expect(restored.startTime, const Duration(seconds: 3));
        expect(restored.offset, const Offset(50.5, 75.0));
        expect(restored.size, const Size(200.0, 100.0));
      });
    });

    group('toJson / fromJson', () {
      test('roundtrip preserves data', () {
        final layer = ImageLayer(
          image: image,
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 5),
        );
        final json = layer.toJson();
        final restored = ImageLayer.fromJson(json);

        expect(restored.startTime, layer.startTime);
        expect(restored.endTime, layer.endTime);
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final layer = ImageLayer(
          image: image,
          startTime: const Duration(seconds: 1),
        );
        final copy = layer.copyWith(
          startTime: const Duration(seconds: 2),
          offset: const Offset(10, 20),
          size: const Size(640, 480),
        );

        expect(copy.startTime, const Duration(seconds: 2));
        expect(copy.offset, const Offset(10, 20));
        expect(copy.size, const Size(640, 480));
        expect(copy.endTime, isNull);
      });
    });

    test('toString contains class name', () {
      final layer = ImageLayer(image: image);
      expect(layer.toString(), contains('ImageLayer'));
    });
  });
}
