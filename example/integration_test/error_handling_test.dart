import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final testVideo = EditorVideo.asset(kVideoEditorExampleH264Path);

  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final isLinux = defaultTargetPlatform == TargetPlatform.linux;
  final skipAudioTrack = kIsWeb || isWindows || isLinux;

  /// 1 KiB of zeros — a syntactically invalid video container.
  final garbageBytes = Uint8List(1024);

  group('Invalid input - getMetadata', () {
    testWidgets('throws on empty bytes', (tester) async {
      await expectLater(
        pve.getMetadata(EditorVideo.memory(Uint8List(0))),
        throwsA(anything),
      );
    });

    testWidgets('throws on garbage bytes', (tester) async {
      await expectLater(
        pve.getMetadata(EditorVideo.memory(garbageBytes)),
        throwsA(anything),
      );
    });

    testWidgets('throws on a non-existent asset path', (tester) async {
      await expectLater(
        pve.getMetadata(EditorVideo.asset('assets/does_not_exist.mp4')),
        throwsA(anything),
      );
    });
  });

  group('Invalid input - hasAudioTrack', () {
    testWidgets('throws on garbage bytes', (tester) async {
      await expectLater(
        pve.hasAudioTrack(EditorVideo.memory(garbageBytes)),
        throwsA(anything),
      );
    }, skip: skipAudioTrack);
  });

  group('Thumbnail edge cases', () {
    testWidgets('empty timestamp list yields no thumbnails', (tester) async {
      List<Uint8List>? result;
      Object? error;
      try {
        result = await pve.getThumbnails(
          ThumbnailConfigs(
            video: testVideo,
            outputFormat: ThumbnailFormat.jpeg,
            timestamps: const [],
            outputSize: const Size(64, 64),
            boxFit: ThumbnailBoxFit.cover,
          ),
        );
      } catch (e) {
        error = e;
      }

      /// Either an empty result or a thrown error is acceptable, but the
      /// plugin must not hang or return malformed data.
      expect(
        result?.isEmpty ?? error != null,
        isTrue,
        reason: 'empty timestamps must not produce thumbnails',
      );
    });

    testWidgets('timestamp beyond duration is handled', (tester) async {
      /// A timestamp far past the end of the clip must clamp to a valid frame
      /// or fail cleanly — never hang.
      Object? error;
      List<Uint8List>? result;
      try {
        result = await pve.getThumbnails(
          ThumbnailConfigs(
            video: testVideo,
            outputFormat: ThumbnailFormat.jpeg,
            timestamps: const [Duration(hours: 1)],
            outputSize: const Size(64, 64),
            boxFit: ThumbnailBoxFit.cover,
          ),
        );
      } catch (e) {
        error = e;
      }

      if (error == null) {
        expect(result, isNotNull);
        for (final thumb in result!) {
          expect(thumb.lengthInBytes, greaterThan(0));
        }
      }
    });
  });

  group('Render - invalid configuration', () {
    testWidgets('crop rect outside bounds fails cleanly or clamps', (
      tester,
    ) async {
      /// A crop window entirely outside the source frame should either be
      /// rejected with an exception or clamped — but must not crash the
      /// plugin or hang.
      Object? error;
      Uint8List? result;
      try {
        result = await pve.renderVideo(
          VideoRenderData(
            videoSegments: [VideoSegment(video: testVideo)],
            outputFormat: VideoOutputFormat.mp4,
            transform: const ExportTransform(
              x: 100000,
              y: 100000,
              width: 64,
              height: 64,
            ),
          ),
        );
      } catch (e) {
        error = e;
      }

      expect(
        error != null || (result != null && result.isNotEmpty),
        isTrue,
        reason: 'out-of-bounds crop must throw or produce a clamped output',
      );
    }, skip: kIsWeb);
  });
}
