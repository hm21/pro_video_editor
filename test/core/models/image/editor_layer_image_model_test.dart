import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/image/editor_layer_image_model.dart';

void main() {
  group('EditorLayerImage', () {
    group('toMap / fromMap', () {
      test('roundtrip with memory bytes', () {
        final bytes = Uint8List.fromList([10, 20, 30]);
        final image = EditorLayerImage.memory(bytes);
        final map = image.toMap();
        final restored = EditorLayerImage.fromMap(map);

        expect(restored.hasBytes, isTrue);
        expect(restored.byteArray, bytes);
      });

      test('roundtrip with asset path', () {
        final image = EditorLayerImage.asset('assets/overlay.png');
        final map = image.toMap();
        final restored = EditorLayerImage.fromMap(map);

        expect(restored.hasAssetPath, isTrue);
        expect(restored.assetPath, 'assets/overlay.png');
      });

      test('roundtrip with file path', () {
        final image = EditorLayerImage.file('/tmp/image.png');
        final map = image.toMap();
        final restored = EditorLayerImage.fromMap(map);

        expect(restored.hasFile, isTrue);
        expect(restored.file?.path, '/tmp/image.png');
      });

      test('roundtrip with network url', () {
        final image = EditorLayerImage.network('https://example.com/image.png');
        final map = image.toMap();
        final restored = EditorLayerImage.fromMap(map);

        expect(restored.hasNetworkUrl, isTrue);
        expect(restored.networkUrl, 'https://example.com/image.png');
      });

      test('throws for empty map', () {
        expect(() => EditorLayerImage.fromMap({}), throwsArgumentError);
      });
    });
  });
}
