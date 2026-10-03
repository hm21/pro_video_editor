import 'package:flutter/foundation.dart';
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

      test('roundtrip with content url', () {
        final video = EditorVideo.content(_contentUrl);
        final map = video.toMap();
        final restored = EditorVideo.fromMap(map);

        expect(map, {'contentUrl': _contentUrl});
        expect(restored.hasContentUrl, isTrue);
        expect(restored.contentUrl, _contentUrl);
        expect(restored, video);
      });
    });

    group('content source', () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('reports the content type', () {
        final video = EditorVideo.content(_contentUrl);

        expect(video.type, EditorVideoType.content);
        expect(video.typePreferredFile, EditorVideoType.content);
      });

      test('takes part in equality and copyWith', () {
        final video = EditorVideo.content(_contentUrl);

        expect(video, EditorVideo.content(_contentUrl));
        expect(video.hashCode, EditorVideo.content(_contentUrl).hashCode);
        expect(video, isNot(EditorVideo.content('$_contentUrl/2')));
        expect(video.copyWith().contentUrl, _contentUrl);
      });

      test('resolves to the content url on Android', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        expect(
          await EditorVideo.content(_contentUrl).contentOrSafeFilePath(),
          _contentUrl,
        );
      });

      test('throws a clear error on other platforms', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        await expectLater(
          EditorVideo.content(_contentUrl).contentOrSafeFilePath(),
          throwsUnsupportedError,
        );
      });

      test('has no file path or bytes', () async {
        final video = EditorVideo.content(_contentUrl);

        await expectLater(video.safeFilePath(), throwsUnsupportedError);
        await expectLater(video.safeByteArray(), throwsUnsupportedError);
      });

      test('a local file is preferred over the content url', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final video = EditorVideo.autoSource(
          contentUrl: _contentUrl,
          file: '/tmp/video.mp4',
        );

        expect(await video.contentOrSafeFilePath(), '/tmp/video.mp4');
      });

      test('other sources resolve through safeFilePath', () async {
        expect(
          await EditorVideo.file('/tmp/video.mp4').contentOrSafeFilePath(),
          '/tmp/video.mp4',
        );
      });
    });
  });
}

const _contentUrl = 'content://media/external/video/media/42';
