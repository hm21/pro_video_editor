import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that censor layers blur or pixelate exactly the
/// area they cover, in their place among the image layers and only inside
/// their time range, on the platform the test runs on.
///
/// Sources are synthesized in-test (a painted PNG laid over a real clip), so
/// every pixel is known. Values stay tolerant of codec rounding.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const canvas = Size(640, 360);

  /// The area every test hides: whole 32 px blocks from the frame's corner.
  const area = Rect.fromLTWH(128, 96, 256, 160);

  Future<Uint8List> paintPng(
    Size size,
    void Function(Canvas, Size) paint,
  ) async {
    final recorder = PictureRecorder();
    paint(Canvas(recorder), size);
    final image = await recorder.endRecording().toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<Uint8List> solidPng(Color color, {Size size = const Size(64, 64)}) {
    return paintPng(size, (c, size) {
      c.drawRect(Offset.zero & size, Paint()..color = color);
    });
  }

  /// A grey ramp from black to white, left to right.
  Future<Uint8List> rampPng() {
    return paintPng(canvas, (c, size) {
      final rect = Offset.zero & size;
      c.drawRect(
        rect,
        Paint()
          ..shader = Gradient.linear(rect.topLeft, rect.topRight, const [
            Color(0xFF000000),
            Color(0xFFFFFFFF),
          ]),
      );
    });
  }

  /// A white vertical stripe from x = 256 to 384 on black.
  Future<Uint8List> stripePng() {
    return paintPng(canvas, (c, size) {
      c
        ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000))
        ..drawRect(
          Rect.fromLTWH(256, 0, 128, size.height),
          Paint()..color = const Color(0xFFFFFFFF),
        );
    });
  }

  /// Turns a still image into a normal clip whose every pixel is known.
  Future<EditorVideo> videoFromImage(Uint8List png) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(
            // A two-second clip.
            video: EditorVideo.asset('assets/tests/test_d.mp4'),
          ),
        ],
        imageLayers: [ImageLayer(image: EditorLayerImage.memory(png))],
        transform: ExportTransform(
          width: canvas.width.toInt(),
          height: canvas.height.toInt(),
        ),
      ),
    );
    return EditorVideo.memory(bytes);
  }

  Future<Uint8List> render(EditorVideo source, List<ImageLayer> layers) {
    return pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: source)],
        imageLayers: layers,
      ),
    );
  }

  Future<ImageLayer> censorLayer(
    LayerCensor censor, {
    Rect rect = area,
    Duration? startTime,
    Duration? endTime,
  }) async {
    return ImageLayer(
      image: EditorLayerImage.memory(await solidPng(const Color(0xFFFFFFFF))),
      offset: rect.topLeft,
      size: rect.size,
      censor: censor,
      startTime: startTime,
      endTime: endTime,
    );
  }

  /// The RGBA pixels of the frame of [video] at [at].
  Future<({ByteData data, int width})> frameOf(
    Uint8List video, [
    Duration at = const Duration(milliseconds: 500),
  ]) async {
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
    expect(image.width, canvas.width.toInt());
    return (data: (await image.toByteData())!, width: image.width);
  }

  List<int> pixel(({ByteData data, int width}) frame, int x, int y) {
    final i = (y * frame.width + x) * 4;
    return [
      frame.data.getUint8(i),
      frame.data.getUint8(i + 1),
      frame.data.getUint8(i + 2),
    ];
  }

  int grey(List<int> rgb) => (rgb[0] + rgb[1] + rgb[2]) ~/ 3;

  group('pixelate', () {
    late EditorVideo ramp;
    late ({ByteData data, int width}) source;

    setUpAll(() async {
      ramp = await videoFromImage(await rampPng());
      source = await frameOf(await render(ramp, const []));
    });

    bool isPixelated(({ByteData data, int width}) frame) =>
        (grey(pixel(frame, 162, 180)) - grey(pixel(frame, 189, 180))).abs() < 5;

    testWidgets('fills each block inside the area with one color', (
      tester,
    ) async {
      final out = await frameOf(
        await render(ramp, [
          await censorLayer(const LayerCensor.pixelate(blockSize: 32)),
        ]),
      );

      // Inside one block (x 160..191): the same grey, although the ramp
      // climbs ~11 levels across it.
      expect(isPixelated(out), isTrue);
      // Across a block edge: a full block's step of the ramp.
      expect(
        grey(pixel(out, 194, 180)) - grey(pixel(out, 189, 180)),
        greaterThan(8),
      );
    });

    testWidgets('starts its blocks at the area\'s corner', (tester) async {
      // An area 12 px off the 32 px grid of the frame's corner: blocks counted
      // from the frame would split x 140..171 at 160.
      final out = await frameOf(
        await render(ramp, [
          await censorLayer(
            const LayerCensor.pixelate(blockSize: 32),
            rect: const Rect.fromLTWH(140, 96, 256, 160),
          ),
        ]),
      );

      expect(
        (grey(pixel(out, 142, 180)) - grey(pixel(out, 169, 180))).abs(),
        lessThan(5),
      );
      expect(
        grey(pixel(out, 174, 180)) - grey(pixel(out, 169, 180)),
        greaterThan(8),
      );
    });

    testWidgets('leaves the picture outside the area as it is', (tester) async {
      final out = await frameOf(
        await render(ramp, [
          await censorLayer(const LayerCensor.pixelate(blockSize: 32)),
        ]),
      );

      for (final (x, y) in [(60, 180), (420, 180), (200, 60), (200, 300)]) {
        expect(
          (grey(pixel(out, x, y)) - grey(pixel(source, x, y))).abs(),
          lessThan(6),
          reason: 'pixel ($x, $y) changed',
        );
      }
    });

    testWidgets('follows the layer\'s rotation', (tester) async {
      // A square turned by 45°: its center is hidden, while the corners of
      // its unturned box lie outside the diamond and stay as they are.
      final out = await frameOf(
        await render(ramp, [
          ImageLayer(
            image: EditorLayerImage.memory(
              await solidPng(const Color(0xFFFFFFFF)),
            ),
            offset: const Offset(192, 64),
            size: const Size(224, 224),
            rotation: 0.785398,
            censor: const LayerCensor.pixelate(blockSize: 32),
          ),
        ]),
      );

      // The blocks start at the turned square's bounding box, x 146 and y 18,
      // so x 178..209 is one block on row 180.
      expect(
        (grey(pixel(out, 180, 180)) - grey(pixel(out, 207, 180))).abs(),
        lessThan(5),
      );
      for (final (x, y) in [(200, 72), (408, 72), (200, 280), (408, 280)]) {
        expect(
          (grey(pixel(out, x, y)) - grey(pixel(source, x, y))).abs(),
          lessThan(6),
          reason: 'pixel ($x, $y) outside the turned square changed',
        );
      }
    });

    testWidgets('applies only inside its time range', (tester) async {
      final video = await render(ramp, [
        await censorLayer(
          const LayerCensor.pixelate(blockSize: 32),
          startTime: const Duration(milliseconds: 500),
          endTime: const Duration(milliseconds: 1200),
        ),
      ]);

      expect(
        isPixelated(await frameOf(video, const Duration(milliseconds: 250))),
        isFalse,
      );
      expect(
        isPixelated(await frameOf(video, const Duration(milliseconds: 800))),
        isTrue,
      );
      expect(
        isPixelated(await frameOf(video, const Duration(milliseconds: 1600))),
        isFalse,
      );
    });
  });

  group('edges', () {
    late EditorVideo flat;

    setUpAll(() async {
      flat = await videoFromImage(
        await solidPng(const Color(0xFF20F020), size: canvas),
      );
    });

    for (final censor in const [
      LayerCensor.pixelate(blockSize: 32),
      LayerCensor.blur(sigma: 8),
    ]) {
      testWidgets('leave no seam around a ${censor.type.name} area', (
        tester,
      ) async {
        // Over one flat color the hidden picture is that color too, so any
        // pixel that differs is a seam the blend left along the edge.
        final out = await frameOf(
          await render(flat, [
            await censorLayer(
              censor,
              rect: const Rect.fromLTWH(100.4, 50.6, 300.3, 200.2),
            ),
          ]),
        );

        final inside = pixel(out, 250, 150);
        for (final (x, y) in [
          for (var x = 96; x < 106; x++) (x, 150),
          for (var x = 396; x < 404; x++) (x, 150),
          for (var y = 46; y < 56; y++) (250, y),
          for (var y = 246; y < 255; y++) (250, y),
        ]) {
          final c = pixel(out, x, y);
          expect(
            [
              for (var i = 0; i < 3; i++) (c[i] - inside[i]).abs(),
            ].reduce((a, b) => a > b ? a : b),
            lessThan(6),
            reason: 'pixel ($x, $y) is $c, the area is $inside',
          );
        }
      });
    }
  });

  group('blur', () {
    late EditorVideo stripe;

    setUpAll(() async {
      stripe = await videoFromImage(await stripePng());
    });

    testWidgets('softens the edges inside the area only', (tester) async {
      final out = await frameOf(
        await render(stripe, [
          await censorLayer(const LayerCensor.blur(sigma: 16)),
        ]),
      );

      // Inside the area the stripe's edge at x = 256 bleeds into the black:
      // 16 px out, a Gaussian of sigma 16 still carries ~16% of the white.
      expect(grey(pixel(out, 240, 180)), inInclusiveRange(20, 90));
      expect(grey(pixel(out, 272, 180)), inInclusiveRange(165, 235));
      // Above the area the edge stays sharp.
      expect(grey(pixel(out, 240, 40)), lessThan(12));
      expect(grey(pixel(out, 272, 40)), greaterThan(243));
    });

    testWidgets('hides the image layers before it, not the ones after it', (
      tester,
    ) async {
      final out = await frameOf(
        await render(stripe, [
          // Beneath the censor: a red square on the black left of the area.
          ImageLayer(
            image: EditorLayerImage.memory(
              await solidPng(const Color(0xFFFF0000)),
            ),
            offset: const Offset(150, 160),
            size: const Size(24, 24),
          ),
          await censorLayer(const LayerCensor.blur(sigma: 16)),
          // On top of it: a green square on the white stripe.
          ImageLayer(
            image: EditorLayerImage.memory(
              await solidPng(const Color(0xFF00FF00)),
            ),
            offset: const Offset(300, 160),
            size: const Size(24, 24),
          ),
        ]),
      );

      final red = pixel(out, 162, 172);
      expect(red[0], lessThan(200), reason: 'the red square was not blurred');
      expect(
        red[0],
        greaterThan(red[1] + 20),
        reason: 'the red square is gone',
      );

      final green = pixel(out, 312, 172);
      expect(green[1], greaterThan(200));
      expect(green[0], lessThan(70));
      expect(green[2], lessThan(70));
    });
  });
}
