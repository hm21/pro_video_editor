import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/editor_video_model.dart';

void main() {
  group('EditorVideo', () {
    group('toMap / fromMap', () {
      test('roundtrip with memory bytes', () {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final video = EditorVideo.memory(bytes);
        final map = video.toMap();
        final restored = EditorVideo.fromMap(map);

        expect(restored.hasBytes, isTrue);
        expect(restored.byteArray, bytes);
      });

      test('roundtrip with file path', () {
        final video = EditorVideo.file('/tmp/video.mp4');
        final map = video.toMap();
        final restored = EditorVideo.fromMap(map);

        expect(restored.hasFile, isTrue);
        expect(restored.file?.path, '/tmp/video.mp4');
      });

      test('roundtrip with network url', () {
        final video = EditorVideo.network('https://example.com/video.mp4');
        final map = video.toMap();
        final restored = EditorVideo.fromMap(map);

        expect(restored.hasNetworkUrl, isTrue);
        expect(restored.networkUrl, 'https://example.com/video.mp4');
      });

      test('roundtrip with asset path', () {
        final video = EditorVideo.asset('assets/sample.mp4');
        final map = video.toMap();
        final restored = EditorVideo.fromMap(map);

        expect(restored.hasAssetPath, isTrue);
        expect(restored.assetPath, 'assets/sample.mp4');
      });

      test('toMap includes only non-null sources', () {
        final video = EditorVideo.network('https://example.com/v.mp4');
        final map = video.toMap();

        expect(map.containsKey('networkUrl'), isTrue);
        expect(map.containsKey('byteArray'), isFalse);
        expect(map.containsKey('file'), isFalse);
        expect(map.containsKey('assetPath'), isFalse);
      });

      test('fromMap with null sources throws assertion', () {
        expect(() => EditorVideo.fromMap({}), throwsA(isA<AssertionError>()));
      });
    });
  });
}
