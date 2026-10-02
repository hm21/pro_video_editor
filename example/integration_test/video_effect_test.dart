import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// End-to-end verification that video effects land in the exported file where
/// the spec puts them, on the platform the test runs on.
///
/// Sources are synthesized in-test (a painted PNG laid over a real clip), so
/// every pixel is known. Expected positions are derived from the same
/// `VideoEffectFrame` the renderer receives, so the checks follow the spec
/// rather than today's look. Values stay tolerant of codec rounding.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  const canvas = Size(640, 360);

  Future<Uint8List> paintPng(void Function(Canvas, Size) paint) async {
    final recorder = PictureRecorder();
    paint(Canvas(recorder), canvas);
    final image = await recorder.endRecording().toImage(
      canvas.width.toInt(),
      canvas.height.toInt(),
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// A grey ramp from black to white, left to right or top to bottom.
  Future<Uint8List> rampPng({required bool horizontal}) {
    return paintPng((c, size) {
      final rect = Offset.zero & size;
      c.drawRect(
        rect,
        Paint()
          ..shader = Gradient.linear(
            rect.topLeft,
            horizontal ? rect.topRight : rect.bottomLeft,
            const [Color(0xFF000000), Color(0xFFFFFFFF)],
          ),
      );
    });
  }

  /// A white vertical stripe on black.
  Future<Uint8List> stripePng() {
    return paintPng((c, size) {
      c
        ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000))
        ..drawRect(
          Rect.fromLTWH(size.width * 0.4, 0, size.width * 0.2, size.height),
          Paint()..color = const Color(0xFFFFFFFF),
        );
    });
  }

  /// One flat color over the whole frame.
  Future<Uint8List> solidPng(Color color) {
    return paintPng((c, size) {
      c.drawRect(Offset.zero & size, Paint()..color = color);
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

  Future<Uint8List> render(EditorVideo source, List<VideoEffect> effects) {
    return pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: source)],
        effects: effects,
      ),
    );
  }

  /// The RGBA pixels of the frame of [video] at [at], at [size], which is
  /// the canvas unless the output was turned.
  Future<({ByteData data, int width})> frameOf(
    Uint8List video,
    Duration at, {
    Size size = canvas,
  }) async {
    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.memory(video),
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: size,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    expect(frames, isNotEmpty, reason: 'No frame extracted from the output');
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, size.width.toInt());
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
    late EditorVideo horizontalRamp;
    late EditorVideo verticalRamp;

    setUpAll(() async {
      horizontalRamp = await videoFromImage(await rampPng(horizontal: true));
      verticalRamp = await videoFromImage(await rampPng(horizontal: false));
    });

    // 640 * 0.05 = 32 px blocks.
    const effect = VideoEffect.pixelate();

    testWidgets('fills each block with one color, from the left edge', (
      tester,
    ) async {
      final out = await frameOf(
        await render(horizontalRamp, const [effect]),
        const Duration(milliseconds: 500),
      );
      const y = 180;
      // Inside one block: the same grey, although the ramp climbs ~11 levels.
      expect(
        (grey(pixel(out, 34, y)) - grey(pixel(out, 61, y))).abs(),
        lessThan(5),
      );
      // Across a block edge: a full block's step of the ramp.
      expect(grey(pixel(out, 65, y)) - grey(pixel(out, 62, y)), greaterThan(8));
    });

    testWidgets('counts blocks from the top edge, not the bottom', (
      tester,
    ) async {
      final out = await frameOf(
        await render(verticalRamp, const [effect]),
        const Duration(milliseconds: 500),
      );
      const x = 320;
      // Rows 32..63 are one block when counted from the top. Counted from the
      // bottom (360 - 32k), a block edge would fall at row 40.
      expect(
        (grey(pixel(out, x, 34)) - grey(pixel(out, x, 61))).abs(),
        lessThan(5),
      );
      expect(grey(pixel(out, x, 66)) - grey(pixel(out, x, 61)), greaterThan(8));
    });

    testWidgets('applies only inside its time range', (tester) async {
      final video = await render(horizontalRamp, const [
        VideoEffect.pixelate(
          startTime: Duration(milliseconds: 500),
          endTime: Duration(milliseconds: 1200),
        ),
      ]);
      bool isPixelated(({ByteData data, int width}) frame) =>
          (grey(pixel(frame, 34, 180)) - grey(pixel(frame, 61, 180))).abs() < 5;

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

  group('glitch', () {
    late EditorVideo stripe;

    setUpAll(() async {
      stripe = await videoFromImage(await stripePng());
    });

    testWidgets('splits the channels and shifts its bands', (tester) async {
      const effect = VideoEffect.glitch();
      final frame = effect.frameAt(Duration.zero);
      expect(frame.bands, isNotEmpty, reason: 'The glitch opens on a burst');

      final out = await frameOf(
        await render(stripe, const [effect]),
        Duration.zero,
      );
      const width = 640;
      const height = 360;
      int toPixels(double f, int size) => (f * size + 0.5).floor();

      // A row outside every band: only the channel split applies. The stripe
      // spans x = 256..383; red is read `split` pixels to the right.
      final bandRows = [
        for (final band in frame.bands)
          (toPixels(band.top, height), toPixels(band.bottom, height)),
      ];
      final row = List.generate(
        height,
        (y) => y,
      ).firstWhere((y) => bandRows.every((r) => y < r.$1 - 4 || y >= r.$2 + 4));
      final split = toPixels(frame.rgbShift, width);
      expect(split.abs(), greaterThan(6));
      // Just outside the stripe on the side red moves toward: red only.
      final redSide = split < 0 ? 384 + split.abs() ~/ 2 : 255 - split ~/ 2;
      final fringe = pixel(out, redSide, row);
      expect(fringe[0], greaterThan(150), reason: 'red fringe $fringe');
      expect(fringe[2], lessThan(100), reason: 'no blue in $fringe');

      // Inside the first band the stripe moves by the band's shift. Green is
      // read in place, so it shows the band without the channel split: the
      // strip the stripe moved into turns white, the strip it left turns black.
      final bandRow = (bandRows.first.$1 + bandRows.first.$2) ~/ 2;
      final shift = toPixels(frame.bands.first.shift, width);
      expect(shift.abs(), greaterThan(10));
      final movedInto = shift > 0 ? 384 + shift ~/ 2 : 256 + shift ~/ 2;
      final movedOutOf = shift > 0 ? 256 + shift ~/ 2 : 384 + shift ~/ 2;
      expect(pixel(out, movedInto, bandRow)[1], greaterThan(150));
      expect(pixel(out, movedOutOf, bandRow)[1], lessThan(100));
    });

    // With imageBytesWithCropping, iOS and macOS rotate the frame only after
    // the effects, which still have to run along the exported frame's rows.
    // Turned a quarter, the stripe runs across the frame: a split along the
    // exported rows leaves its edges alone, one along the source rows would
    // put a red and a blue fringe on its top and bottom edges.
    testWidgets('splits along the exported rows when rotated', (tester) async {
      for (final withCropping in [false, true]) {
        final out = await frameOf(
          await pve.renderVideo(
            VideoRenderData(
              videoSegments: [VideoSegment(video: stripe)],
              effects: const [VideoEffect.rgbSplit()],
              transform: const ExportTransform(rotateTurns: 1),
              imageBytesWithCropping: withCropping,
            ),
          ),
          Duration.zero,
          size: const Size(360, 640),
        );
        // Rows 256..383 of 640 are the stripe.
        final column = [for (var y = 0; y < 640; y++) pixel(out, 180, y)];
        expect(grey(column[320]), greaterThan(200));
        expect(grey(column[100]), lessThan(50));
        for (final (y, rgb) in column.indexed) {
          expect(
            (rgb[0] - rgb[2]).abs(),
            lessThan(60),
            reason:
                'fringe at row $y: $rgb, imageBytesWithCropping: '
                '$withCropping',
          );
        }
      }
    });
  });

  group('geometry', () {
    late EditorVideo stripe;
    late EditorVideo ramp;

    setUpAll(() async {
      stripe = await videoFromImage(await stripePng());
      ramp = await videoFromImage(await rampPng(horizontal: true));
    });

    testWidgets('mirror shows the left half mirrored on the right', (
      tester,
    ) async {
      final out = await frameOf(
        await render(ramp, const [VideoEffect.mirror()]),
        Duration.zero,
      );
      for (final x in [20, 100, 250]) {
        final left = grey(pixel(out, x, 180));
        final right = grey(pixel(out, 639 - x, 180));
        expect((left - right).abs(), lessThan(12), reason: 'column $x');
      }
      expect(grey(pixel(out, 600, 180)), lessThan(60));
    });

    // A phone stores a portrait video as landscape pixels plus a rotation
    // flag. The geometry belongs to the picture as it is shown, so the mirror
    // runs along the shown rows: left and right match, top and bottom do not.
    testWidgets('mirror follows the shown picture of a rotated clip', (
      tester,
    ) async {
      // 640x360 pixels, shown as 360x640.
      final rotated = EditorVideo.asset('assets/tests/test_g.mp4');
      for (final withCropping in [false, true]) {
        final out = await frameOf(
          await pve.renderVideo(
            VideoRenderData(
              videoSegments: [VideoSegment(video: rotated)],
              effects: const [VideoEffect.mirror()],
              imageBytesWithCropping: withCropping,
            ),
          ),
          Duration.zero,
          size: const Size(360, 640),
        );
        var across = 0;
        var down = 0;
        var count = 0;
        for (var y = 20; y < 320; y += 20) {
          for (var x = 10; x < 180; x += 20) {
            final here = grey(pixel(out, x, y));
            across += (here - grey(pixel(out, 359 - x, y))).abs();
            down += (here - grey(pixel(out, x, 639 - y))).abs();
            count++;
          }
        }
        final reason = 'imageBytesWithCropping: $withCropping';
        expect(across / count, lessThan(8), reason: reason);
        expect(down / count, greaterThan(20), reason: reason);
      }
    });

    testWidgets('splitScreen shows the picture four times at half size', (
      tester,
    ) async {
      final out = await frameOf(
        await render(stripe, const [VideoEffect.splitScreen()]),
        Duration.zero,
      );
      // The stripe, x = 256..383, lands at 128..191 in the left copies and at
      // 448..511 in the right ones.
      for (final (x, y) in [(160, 90), (480, 90), (160, 270), (480, 270)]) {
        expect(grey(pixel(out, x, y)), greaterThan(200), reason: '($x, $y)');
      }
      for (final (x, y) in [(60, 90), (320, 90), (580, 270), (320, 270)]) {
        expect(grey(pixel(out, x, y)), lessThan(50), reason: '($x, $y)');
      }
    });

    testWidgets('zoomPulse opens zoomed in on the center', (tester) async {
      final out = await frameOf(
        await render(stripe, const [VideoEffect.zoomPulse()]),
        Duration.zero,
      );
      // Zoomed by 1.25 around x = 320, the stripe spans 240..400.
      expect(grey(pixel(out, 246, 180)), greaterThan(200));
      expect(grey(pixel(out, 394, 180)), greaterThan(200));
      expect(grey(pixel(out, 410, 180)), lessThan(50));
    });

    testWidgets('wave bends the rows along the wave', (tester) async {
      const effect = VideoEffect.wave();
      final frame = effect.frameAt(Duration.zero);
      final out = await frameOf(
        await render(stripe, const [effect]),
        Duration.zero,
      );
      // The wave is half the frame tall: its crest is an eighth of the way
      // down, at row 45, and its trough at row 135. There it moves the
      // stripe right, and left, by the amplitude, 16 pixels. The zoom that
      // follows, by 1.055 around the center, puts those rows at 38 and 132,
      // and the stripe, x = 256..383, at 252..387 where the wave crosses
      // zero, at row 85.
      final reach = frame.waveAmplitude * 640;
      expect(reach, closeTo(16, 1e-9));
      expect(frame.zoom, closeTo(0.055, 1e-9));
      // The crest: 269..403.
      expect(grey(pixel(out, 262, 38)), lessThan(60));
      expect(grey(pixel(out, 396, 38)), greaterThan(190));
      // The trough: 236..370.
      expect(grey(pixel(out, 244, 132)), greaterThan(190));
      expect(grey(pixel(out, 378, 132)), lessThan(60));
      expect(grey(pixel(out, 258, 85)), greaterThan(190));
      expect(grey(pixel(out, 246, 85)), lessThan(60));
    });
  });

  group('tones', () {
    late EditorVideo darkGrey;
    late EditorVideo midGrey;

    setUpAll(() async {
      darkGrey = await videoFromImage(await solidPng(const Color(0xFF404040)));
      midGrey = await videoFromImage(await solidPng(const Color(0xFF808080)));
    });

    testWidgets('strobe flashes white and dims in between', (tester) async {
      final video = await render(darkGrey, const [VideoEffect.strobe()]);
      // Bucket 0 is fully white; bucket 6 is dimmed to half.
      final flash = await frameOf(video, Duration.zero);
      final dark = await frameOf(video, const Duration(milliseconds: 250));
      expect(grey(pixel(flash, 320, 180)), greaterThan(235));
      expect(grey(pixel(dark, 320, 180)), inInclusiveRange(22, 42));
    });

    // Effects follow the exported timeline, so a sped-up segment keeps the
    // strobe at two flashes a second instead of speeding it up with the
    // footage.
    testWidgets('strobe keeps its rate on a sped-up segment', (tester) async {
      final video = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: darkGrey, playbackSpeed: 2)],
          effects: const [VideoEffect.strobe()],
        ),
      );
      // 270 ms in is bucket 6, between two flashes; timed by the footage it
      // would be bucket 12, the next flash. That flash is at 500 ms.
      final between = await frameOf(video, const Duration(milliseconds: 270));
      final flash = await frameOf(video, const Duration(milliseconds: 510));
      expect(grey(pixel(between, 320, 180)), inInclusiveRange(22, 42));
      expect(grey(pixel(flash, 320, 180)), greaterThan(235));
    });

    testWidgets('negativeFlash turns the picture into its negative', (
      tester,
    ) async {
      final video = await render(darkGrey, const [VideoEffect.negativeFlash()]);
      final negative = await frameOf(video, Duration.zero);
      final normal = await frameOf(video, const Duration(milliseconds: 400));
      expect(grey(pixel(negative, 320, 180)), inInclusiveRange(181, 201));
      expect(grey(pixel(normal, 320, 180)), inInclusiveRange(54, 74));
    });

    testWidgets('vignette darkens the corners and keeps the center', (
      tester,
    ) async {
      const at = Duration(milliseconds: 500);
      final plain = await frameOf(await render(midGrey, const []), at);
      final out = await frameOf(
        await render(midGrey, const [VideoEffect.vignette()]),
        at,
      );
      final center = grey(pixel(plain, 320, 180));
      expect((grey(pixel(out, 320, 180)) - center).abs(), lessThan(6));
      // Near the corner t is almost 1, so almost none of the grey remains.
      expect(grey(pixel(out, 2, 2)), lessThan(center * 0.3));
      // Symmetric: the opposite corner matches.
      expect(
        (grey(pixel(out, 2, 2)) - grey(pixel(out, 637, 357))).abs(),
        lessThan(8),
      );
    });

    testWidgets('oldFilm tones the picture sepia', (tester) async {
      final out = await frameOf(
        await render(midGrey, const [VideoEffect.oldFilm()]),
        const Duration(milliseconds: 500),
      );
      // Average a patch, so the grain cancels out.
      var r = 0;
      var g = 0;
      var b = 0;
      for (var y = 170; y < 190; y++) {
        for (var x = 310; x < 330; x++) {
          final p = pixel(out, x, y);
          r += p[0];
          g += p[1];
          b += p[2];
        }
      }
      // Sepia over grey: red above green above blue, by about 16 and 29
      // levels at full intensity.
      expect(r - g, greaterThan(8 * 400), reason: 'rgb sums $r $g $b');
      expect(g - b, greaterThan(15 * 400), reason: 'rgb sums $r $g $b');
    });
  });
}
