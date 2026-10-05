import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that a render runs the custom video effects the
/// app registered natively, with their params, inside their time range, and
/// with the earlier frames they ask for, on the platform the test runs on.
///
/// The effects are the example app's own: `example.invert` (Android
/// `ExampleVideoEffects.kt`, iOS `AppDelegate.swift`, macOS
/// `MainFlutterWindow.swift`) inverts the colors, and `example.delay` shows
/// the frame from `delayMs` earlier. Sources are solid colors, so every pixel
/// is known; values stay tolerant of codec rounding, and of the Android
/// emulator's encoder darkening red to ~190 over two encodes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const canvas = Size(640, 360);

  Future<Uint8List> solidPng(Color color) async {
    final recorder = PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & canvas, Paint()..color = color);
    final image = await recorder.endRecording().toImage(
      canvas.width.toInt(),
      canvas.height.toInt(),
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// A two-second clip of a single color.
  Future<EditorVideo> solidVideo(Color color) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: EditorVideo.asset('assets/tests/test_d.mp4')),
        ],
        imageLayers: [
          ImageLayer(image: EditorLayerImage.memory(await solidPng(color))),
        ],
        transform: ExportTransform(
          width: canvas.width.toInt(),
          height: canvas.height.toInt(),
        ),
      ),
    );
    return EditorVideo.memory(bytes);
  }

  Future<Uint8List> render(
    EditorVideo source,
    List<CustomVideoEffect> effects, {
    double? playbackSpeed,
  }) {
    return pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: source, playbackSpeed: playbackSpeed),
        ],
        customEffects: effects,
      ),
    );
  }

  /// The RGB color at the center of the frame of [video] at [at].
  Future<List<int>> colorAt(Uint8List video, Duration at) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.memory(video),
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: canvas,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    expect(frames, isNotEmpty, reason: 'No frame extracted from the output');
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    final data = (await image.toByteData())!;
    final i = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
    return [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  }

  Matcher isRed() =>
      predicate<List<int>>((c) => c[0] > 150 && c[1] < 60 && c[2] < 60, 'red');
  Matcher isBlue() =>
      predicate<List<int>>((c) => c[0] < 60 && c[1] < 60 && c[2] > 150, 'blue');
  Matcher isCyan() => predicate<List<int>>(
    (c) => c[0] < 60 && c[1] > 150 && c[2] > 150,
    'cyan, inverted red',
  );

  const ms = Duration(milliseconds: 1);

  late EditorVideo red;

  /// Red for two seconds, then blue for two, as one clip.
  late EditorVideo redThenBlue;

  setUpAll(() async {
    red = await solidVideo(const Color(0xFFFF0000));
    final blue = await solidVideo(const Color(0xFF0000FF));
    redThenBlue = EditorVideo.memory(
      await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: red),
            VideoSegment(video: blue),
          ],
        ),
      ),
    );
  });

  group('the current frame', () {
    testWidgets('is drawn by the registered effect', (tester) async {
      final out = await render(red, const [
        CustomVideoEffect(id: 'example.invert'),
      ]);

      expect(await colorAt(out, ms * 500), isCyan());
    });

    testWidgets('is drawn with the effect\'s params', (tester) async {
      final out = await render(red, const [
        CustomVideoEffect(id: 'example.invert', params: {'amount': 0.5}),
      ]);

      // Half way between red and cyan is a grey. Android mixes the encoded
      // values and Core Image linear light, so only its evenness is fixed.
      final color = await colorAt(out, ms * 500);
      expect(color.reduce((a, b) => a > b ? a : b), lessThan(230));
      expect(color.reduce((a, b) => a < b ? a : b), greaterThan(70));
      expect((color[0] - color[1]).abs(), lessThan(40));
      expect((color[1] - color[2]).abs(), lessThan(40));
    });

    testWidgets('is drawn by the effect only inside its time range', (
      tester,
    ) async {
      final out = await render(red, const [
        CustomVideoEffect(
          id: 'example.invert',
          startTime: Duration(seconds: 1),
        ),
      ]);

      expect(await colorAt(out, ms * 500), isRed());
      expect(await colorAt(out, ms * 1500), isCyan());
    });
  });

  group('earlier frames', () {
    testWidgets('lie as far back as the effect asks', (tester) async {
      final out = await render(redThenBlue, const [
        CustomVideoEffect(id: 'example.delay', params: {'delayMs': 500}),
      ]);

      // The clip turns blue at 2 s; the effect shows it half a second later.
      expect(await colorAt(out, ms * 2250), isRed());
      expect(await colorAt(out, ms * 2750), isBlue());
    });

    testWidgets('lie that far back on the rendered video', (tester) async {
      final out = await render(redThenBlue, const [
        CustomVideoEffect(id: 'example.delay', params: {'delayMs': 500}),
      ], playbackSpeed: 2);

      // At twice the speed, 1.375 s of output is 2.75 s of the clip, and
      // half a second of output back is a whole second of the clip: still
      // red. Counted on the clip instead, it would be 2.25 s, already blue.
      expect(await colorAt(out, ms * 1375), isRed());
      expect(await colorAt(out, ms * 1750), isBlue());
    });
  });

  testWidgets('a render naming an unregistered effect fails', (tester) async {
    await expectLater(
      render(red, const [CustomVideoEffect(id: 'example.unregistered')]),
      throwsA(anything),
    );
  });
}
