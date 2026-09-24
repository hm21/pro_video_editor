import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_filters.dart';

/// HDR sources on a GPU driver without `GL_EXT_YUV_target`.
///
/// Below Android 12 Media3 turns HDR into SDR only through its OpenGL
/// tone-mapper, which needs that extension, so a driver without it — most
/// below API 31, and the API 30 emulator — failed every such render with
/// `ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED`. The clip is 8-bit HEVC tagged
/// BT.2020 / HLG: an emulator's software decoder cannot decode 10-bit HEVC,
/// and the tag alone is what routes a clip to the tone-mapper. On a device
/// with the extension these renders take the OpenGL tone-mapper instead, and
/// must pass there too.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hlgVideo = EditorVideo.asset('assets/tests/hevc_hlg_8bit.mp4');

  Future<void> expectRenders(VideoRenderData renderModel) async {
    final result = await ProVideoEditor.instance.renderVideo(renderModel);
    expect(result.lengthInBytes, greaterThan(10000));
  }

  group('HDR source', () {
    testWidgets('renders without effects', (_) async {
      await expectRenders(
        VideoRenderData(videoSegments: [VideoSegment(video: hlgVideo)]),
      );
    });

    testWidgets('renders with a color filter', (_) async {
      await expectRenders(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hlgVideo)],
          colorFilters: kComplexFilterMatrix,
        ),
      );
    });

    testWidgets('renders with an image layer', (_) async {
      await expectRenders(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hlgVideo)],
          imageLayers: [
            ImageLayer(image: EditorLayerImage.memory(await _overlayPng())),
          ],
        ),
      );
    });
  });
}

/// A small opaque PNG to composite over the clip.
Future<Uint8List> _overlayPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 120, 60),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(120, 60);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
