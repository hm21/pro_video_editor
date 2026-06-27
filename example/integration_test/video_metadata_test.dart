import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;

  /// `hasAudioTrack` is only implemented on Android, iOS, and macOS.
  final skipAudioTrack = kIsWeb || isWindows || isLinux;

  /// A H.264 video without any audio track.
  const mutedVideoPath = 'assets/demo_muted.mp4';

  /// Portrait 720×1280, 30fps, carries rotation metadata.
  const portraitVideoPath = 'assets/tests/test_b.mp4';

  /// Carries an AC3 (Dolby Digital) audio track.
  const ac3VideoPath = 'assets/tests/test_f.mp4';

  testWidgets('plugin getMetadata returns correct values', (tester) async {
    final video = EditorVideo.asset(kVideoEditorExampleH264Path);

    final metadata = await pve.getMetadata(video);

    expect(metadata.duration.inSeconds, equals(29));
    expect(metadata.resolution, equals(const Size(1280.0, 720.0)));
    expect(metadata.extension, equals('mp4'));
    expect(metadata.rotation, equals(0));
    expect(metadata.fileSize, equals(5253880));

    if (isIOS || isMacOS) {
      /// AVFoundation can't return the exact duration in milliseconds, so we
      /// can't get the exact bitrate but very near to it.
      expect(metadata.bitrate, closeTo(1421504, 500));
    } else {
      expect(metadata.bitrate, equals(1421504));
    }
  });

  group('getMetadata - codecs & sources', () {
    testWidgets('reads HEVC video metadata', (tester) async {
      final video = EditorVideo.asset(kVideoEditorExampleHevcPath);

      final metadata = await pve.getMetadata(video);

      expect(metadata.duration.inMilliseconds, greaterThan(0));
      expect(metadata.resolution.width, greaterThan(0));
      expect(metadata.resolution.height, greaterThan(0));
      expect(metadata.extension, equals('mp4'));
      expect(metadata.bitrate, greaterThan(0));
    });

    testWidgets('reads portrait video with rotation metadata', (tester) async {
      final video = EditorVideo.asset(portraitVideoPath);

      final metadata = await pve.getMetadata(video);

      expect(metadata.duration.inMilliseconds, greaterThan(0));

      /// Regardless of how the rotation is stored, the displayed frame must
      /// resolve to portrait orientation.
      expect(
        metadata.resolution.height,
        greaterThan(metadata.resolution.width),
        reason: 'displayed resolution should be portrait',
      );
    });

    testWidgets('memory source matches asset source', (tester) async {
      final bytes = (await rootBundle.load(
        kVideoEditorExampleH264Path,
      )).buffer.asUint8List();

      final fromAsset = await pve.getMetadata(
        EditorVideo.asset(kVideoEditorExampleH264Path),
      );
      final fromMemory = await pve.getMetadata(EditorVideo.memory(bytes));

      expect(fromMemory.resolution, equals(fromAsset.resolution));
      expect(
        fromMemory.duration.inSeconds,
        equals(fromAsset.duration.inSeconds),
      );
    });
  });

  group('getMetadata - audio presence', () {
    testWidgets('video with audio reports an audio duration', (tester) async {
      final metadata = await pve.getMetadata(
        EditorVideo.asset(kVideoEditorExampleH264Path),
      );

      expect(metadata.audioDuration, isNotNull);
      expect(metadata.audioDuration!.inMilliseconds, greaterThan(0));
    });

    testWidgets('video without audio has no audio duration', (tester) async {
      final metadata = await pve.getMetadata(EditorVideo.asset(mutedVideoPath));

      expect(
        metadata.audioDuration == null ||
            metadata.audioDuration == Duration.zero,
        isTrue,
        reason: 'muted video should not expose an audio duration',
      );
    });

    testWidgets('reads AC3 audio video', (tester) async {
      final metadata = await pve.getMetadata(EditorVideo.asset(ac3VideoPath));

      expect(metadata.duration.inMilliseconds, greaterThan(0));
      expect(metadata.audioDuration, isNotNull);
    });
  });

  group('getMetadata - streaming optimization', () {
    testWidgets('populates isOptimizedForStreaming when requested', (
      tester,
    ) async {
      final metadata = await pve.getMetadata(
        EditorVideo.asset(kVideoEditorExampleH264Path),
        checkStreamingOptimization: true,
      );

      expect(
        metadata.isOptimizedForStreaming,
        isNotNull,
        reason: 'flag should be resolved to a bool when requested',
      );
    }, skip: kIsWeb);

    testWidgets('leaves isOptimizedForStreaming null by default', (
      tester,
    ) async {
      final metadata = await pve.getMetadata(
        EditorVideo.asset(kVideoEditorExampleH264Path),
      );

      expect(metadata.isOptimizedForStreaming, isNull);
    }, skip: kIsWeb);
  });

  group('hasAudioTrack', () {
    testWidgets('returns true for a video with an audio track', (tester) async {
      final result = await pve.hasAudioTrack(
        EditorVideo.asset(kVideoEditorExampleH264Path),
      );

      expect(result, isTrue);
    }, skip: skipAudioTrack);

    testWidgets('returns false for a video without an audio track', (
      tester,
    ) async {
      final result = await pve.hasAudioTrack(EditorVideo.asset(mutedVideoPath));

      expect(result, isFalse);
    }, skip: skipAudioTrack);

    testWidgets('returns true for an AC3 audio track', (tester) async {
      final result = await pve.hasAudioTrack(EditorVideo.asset(ac3VideoPath));

      expect(result, isTrue);
    }, skip: skipAudioTrack);

    testWidgets('works with a memory source', (tester) async {
      final bytes = (await rootBundle.load(
        kVideoEditorExampleH264Path,
      )).buffer.asUint8List();

      final result = await pve.hasAudioTrack(EditorVideo.memory(bytes));

      expect(result, isTrue);
    }, skip: skipAudioTrack);
  });
}
