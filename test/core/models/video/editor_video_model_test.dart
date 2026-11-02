import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_video_editor/core/models/video/editor_video_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

      test('has no bytes', () async {
        final video = EditorVideo.content(_contentUrl);

        await expectLater(video.safeByteArray(), throwsUnsupportedError);
      });

      test('safeFilePath copies the content natively on Android', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
        const plugin = MethodChannel('pro_video_editor');
        final calls = <MethodCall>[];
        messenger
          ..setMockMethodCallHandler(pathProvider, (_) async => '/tmp')
          ..setMockMethodCallHandler(plugin, (call) async {
            calls.add(call);
            return '${(call.arguments as Map)['outputPath']}.mov';
          });
        addTearDown(() {
          messenger
            ..setMockMethodCallHandler(pathProvider, null)
            ..setMockMethodCallHandler(plugin, null);
        });
        final video = EditorVideo.content(_contentUrl);

        final path = await video.safeFilePath();

        expect(calls.single.method, 'copyContentToFile');
        expect(calls.single.arguments, {
          'inputPath': _contentUrl,
          'outputPath': path.substring(0, path.length - '.mov'.length),
        });
        expect(path, startsWith('/tmp/media_'));
        expect(path, endsWith('.mov'));
        expect(video.file?.path, path);
        // Like a downloaded network video, the copy is used from now on.
        expect(await video.contentOrSafeFilePath(), path);
      });

      test('safeFilePath throws on other platforms', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        await expectLater(
          EditorVideo.content(_contentUrl).safeFilePath(),
          throwsUnsupportedError,
        );
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

    group('photo library source', () {
      late List<MethodCall> calls;
      late String resolvedPath;

      setUp(() {
        calls = [];
        resolvedPath = '/var/mobile/Media/DCIM/100APPLE/IMG_0042.MOV';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('pro_video_editor'), (
              call,
            ) async {
              calls.add(call);
              return resolvedPath;
            });
      });

      tearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('pro_video_editor'),
              null,
            );
      });

      test('reports the content type', () {
        final video = EditorVideo.content(_photoLibraryUrl);

        expect(video.type, EditorVideoType.content);
        expect(EditorVideo.fromMap(video.toMap()), video);
      });

      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        test('resolves natively on ${platform.name}', () async {
          debugDefaultTargetPlatformOverride = platform;
          final video = EditorVideo.content(_photoLibraryUrl);

          expect(await video.contentOrSafeFilePath(), resolvedPath);
          expect(calls.single.method, 'resolvePhotoLibraryVideo');
          expect(calls.single.arguments, {'inputPath': _photoLibraryUrl});
          // Read in place, so it is resolved again on the next call.
          expect(video.hasFile, isFalse);
        });
      }

      test('throws a clear error on other platforms', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        await expectLater(
          EditorVideo.content(_photoLibraryUrl).contentOrSafeFilePath(),
          throwsUnsupportedError,
        );
        expect(calls, isEmpty);
      });

      test('safeFilePath uses the resolved file without copying', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final video = EditorVideo.content(_photoLibraryUrl);

        expect(await video.safeFilePath(), resolvedPath);
        // Not kept: only the running app may read it, so a video restored
        // from toMap in a later launch must resolve the URL again.
        expect(video.hasFile, isFalse);
        expect(video.toMap(), {'contentUrl': _photoLibraryUrl});
        expect(await video.contentOrSafeFilePath(), resolvedPath);
        expect(calls, hasLength(2));
      });

      test('safeByteArray reads the resolved file', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final directory = Directory.systemTemp.createTempSync('photo_library');
        addTearDown(() => directory.deleteSync(recursive: true));
        resolvedPath = '${directory.path}/IMG_0042.MOV';
        File(resolvedPath).writeAsBytesSync([1, 2, 3]);
        final video = EditorVideo.content(_photoLibraryUrl);

        expect(await video.safeByteArray(), [1, 2, 3]);
        // Kept bytes would make later calls copy them into a temp file.
        expect(video.hasBytes, isFalse);
        expect(await video.contentOrSafeFilePath(), resolvedPath);
      });
    });
  });
}

const _contentUrl = 'content://media/external/video/media/42';
const _photoLibraryUrl = 'ph:///ED7AC36B-A150-4C38-BB8C-B6D696F4F2ED/L0/001';
