import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// On-device checks for [EditorVideo.content] with an Apple photo library
/// `ph://` URL: every feature reads the video in place, from the file the
/// photo library keeps.
///
/// The example app's PhotoLibraryTestHelper adds the test clips to the photo
/// library once and reuses them on later runs. The suite asks for full photo
/// library access, which has to be allowed on the device at every run, since
/// `flutter test` installs the app afresh.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  const photoLibrary = MethodChannel('pro_video_editor_example/photo_library');

  /// Photo library URLs are an iOS and macOS source.
  final isSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 1920x1080, 5 s, H.264 with audible stereo AAC.
  const clipAsset = 'assets/tests/test_a.mp4';

  late String tempDir;
  late String clipFile;
  late EditorVideo clip;

  /// Adds [asset] to the photo library as [name] and returns its local copy
  /// and its `ph://` URL.
  Future<(String, String)> addToPhotoLibrary(String asset, String name) async {
    final data = await rootBundle.load(asset);
    final file = '$tempDir/photo_library_$name';
    await File(file).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final identifier = await photoLibrary.invokeMethod<String>('addVideo', {
      'path': file,
      'name': name,
    });
    // Three slashes, like file_picker's URIs.
    return (file, 'ph:///$identifier');
  }

  setUpAll(() async {
    if (!isSupported) return;
    tempDir = (await getTemporaryDirectory()).path;
    final granted = await photoLibrary.invokeMethod<bool>('requestAccess');
    expect(granted, isTrue, reason: 'needs full photo library access');

    final (file, url) = await addToPhotoLibrary(
      clipAsset,
      'pro_video_editor_test_a.mp4',
    );
    clipFile = file;
    clip = EditorVideo.content(url);
  });

  testWidgets('resolves to the file in the photo library', (_) async {
    final path = await clip.contentOrSafeFilePath();

    expect(path, isNot(startsWith(tempDir)), reason: 'copied: $path');
    expect(File(path).lengthSync(), File(clipFile).lengthSync());
    expect(await clip.contentOrSafeFilePath(), path);
  }, skip: !isSupported);

  testWidgets('getMetadata matches the file source', (_) async {
    final fromFile = await pve.getMetadata(EditorVideo.file(clipFile));
    final fromLibrary = await pve.getMetadata(clip);

    expect(fromLibrary.duration, fromFile.duration);
    expect(fromLibrary.resolution, fromFile.resolution);
    expect(fromLibrary.rotation, fromFile.rotation);
    expect(fromLibrary.audioDuration, fromFile.audioDuration);
    expect(fromLibrary.fileSize, fromFile.fileSize);
    expect(await pve.hasAudioTrack(clip), isTrue);
  }, skip: !isSupported);

  testWidgets('getThumbnails decodes every timestamp', (_) async {
    final thumbnails = await pve.getThumbnails(
      ThumbnailConfigs(
        video: clip,
        outputSize: const Size(160, 90),
        timestamps: [for (var s = 0; s < 5; s++) Duration(seconds: s)],
      ),
    );

    expect(thumbnails, hasLength(5));
    expect(thumbnails.every((bytes) => bytes.isNotEmpty), isTrue);
  }, skip: !isSupported);

  testWidgets('getWaveform reads the audio', (_) async {
    final waveform = await pve.getWaveform(WaveformConfigs(video: clip));

    expect(waveform.leftChannel, isNotEmpty);
  }, skip: !isSupported);

  testWidgets('renderVideoToFile joins two windows of the video', (_) async {
    final output = '$tempDir/photo_library_render.mp4';
    addTearDown(() {
      if (File(output).existsSync()) File(output).deleteSync();
    });

    await pve.renderVideoToFile(
      output,
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            video: clip,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 2),
          ),
          VideoSegment(
            video: EditorVideo.content(clip.contentUrl!),
            startTime: const Duration(seconds: 3),
            endTime: const Duration(seconds: 4),
          ),
        ],
      ),
    );
    final rendered = await pve.getMetadata(EditorVideo.file(output));

    expect(rendered.duration.inMilliseconds, closeTo(2000, 300));
    expect(rendered.resolution, const Size(1920, 1080));
  }, skip: !isSupported);

  testWidgets('safeFilePath and safeByteArray read in place', (_) async {
    final video = EditorVideo.content(clip.contentUrl!);
    final path = await video.safeFilePath();
    final bytes = await EditorVideo.content(clip.contentUrl!).safeByteArray();

    expect(path, await clip.contentOrSafeFilePath());
    expect(video.file?.path, path);
    expect(bytes.length, File(clipFile).lengthSync());
  }, skip: !isSupported);

  testWidgets('a missing video fails clearly', (_) async {
    final missing = EditorVideo.content(
      'ph:///00000000-0000-0000-0000-000000000000/L0/001',
    );

    await expectLater(
      pve.getMetadata(missing),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'PHOTO_LIBRARY_ERROR')
            .having((e) => e.message, 'message', contains('identifier')),
      ),
    );
  }, skip: !isSupported);

  testWidgets('a slow-motion video is exported once', (_) async {
    // 2 s at 240 fps, which Photos plays as slow motion from a composition.
    final (file, url) = await addToPhotoLibrary(
      'assets/tests/slow_motion_240fps.mov',
      'pro_video_editor_test_slow_motion_240fps.mov',
    );
    final video = EditorVideo.content(url);
    final path = await video.contentOrSafeFilePath();
    final fromFile = await pve.getMetadata(EditorVideo.file(file));
    final fromLibrary = await pve.getMetadata(video);

    expect(path, contains('/pro_video_editor_photo_library/'));
    expect(path, endsWith('.mov'));
    expect(await video.contentOrSafeFilePath(), path);
    // Exported as Photos plays it, with the slowed section.
    expect(fromLibrary.duration, greaterThan(fromFile.duration * 2));
  }, skip: !isSupported);
}
