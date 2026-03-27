import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;

  testWidgets('plugin getMetadata returns correct values', (tester) async {
    final video = EditorVideo.asset(kVideoEditorExampleH264Path);

    final metadata = await ProVideoEditor.instance.getMetadata(video);

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
}
