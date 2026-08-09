import 'dart:io';
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

    group('toChannelSource', () {
      late Directory tempDir;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('layer_image_test');
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('sends an existing file as a path and no bytes', () async {
        final file = File('${tempDir.path}/photo.jpg')
          ..writeAsBytesSync([1, 2, 3, 4]);
        final map = await EditorLayerImage.file(
          file.path,
        ).toChannelSource(pathKey: 'imagePath', dataKey: 'imageData');

        expect(map, {'imagePath': file.path});
      });

      test('sends in-memory bytes under the data key', () async {
        final bytes = Uint8List.fromList([9, 8, 7]);
        final map = await EditorLayerImage.memory(
          bytes,
        ).toChannelSource(pathKey: 'imagePath', dataKey: 'imageData');

        expect(map, {'imageData': bytes});
      });

      test('throws naming the path when the file is gone', () async {
        final missing = '${tempDir.path}/gone.jpg';

        await expectLater(
          EditorLayerImage.file(
            missing,
          ).toChannelSource(pathKey: 'imagePath', dataKey: 'imageData'),
          throwsA(
            isA<FileSystemException>().having((e) => e.path, 'path', missing),
          ),
        );
      });

      test('prefers the path even once bytes have been cached', () async {
        final file = File('${tempDir.path}/cached.jpg')
          ..writeAsBytesSync([5, 5, 5]);
        final image = EditorLayerImage.file(file.path);
        // A prior read caches the bytes; the channel should still get the path,
        // since the point is to keep the bytes out of the message.
        await image.safeByteArray();

        final map = await image.toChannelSource(
          pathKey: 'imagePath',
          dataKey: 'imageData',
        );

        expect(map, {'imagePath': file.path});
      });
    });
  });
}
