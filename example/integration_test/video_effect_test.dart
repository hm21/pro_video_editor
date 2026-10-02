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

  group('texture effects', () {
    late EditorVideo stripe;
    late EditorVideo midGrey;

    setUpAll(() async {
      stripe = await videoFromImage(await stripePng());
      midGrey = await videoFromImage(await solidPng(const Color(0xFF808080)));
    });

    const width = 640;
    const height = 360;
    int toPixels(double f, int size) => (f * size + 0.5).floor();

    testWidgets('blockGlitch opens on coarse blocks', (tester) async {
      const effect = VideoEffect.blockGlitch();
      final frame = effect.frameAt(Duration.zero);
      final block = toPixels(frame.pixelSize, width);
      expect(block, greaterThan(10), reason: 'The effect opens on a burst');

      final out = await frameOf(
        await render(stripe, const [effect]),
        Duration.zero,
      );
      // The middle row of a row of blocks, clear of every slice. Green is
      // read in place, so it shows the blocks without the channel split.
      final bandRows = [
        for (final band in frame.bands)
          (toPixels(band.top, height), toPixels(band.bottom, height)),
      ];
      bool clear(int y) => bandRows.every((r) => y < r.$1 - 4 || y >= r.$2 + 4);
      final y = [
        for (var row = block ~/ 2; row < height; row += block) row,
      ].firstWhere(clear);
      // Each block takes the color of its center pixel, so the stripe's left
      // edge, x = 256, moves to the edge of the block it falls in.
      final start = 256 ~/ block * block;
      final edge = start + block ~/ 2 < 256 ? start + block : start;
      expect(edge, isNot(256));
      expect(pixel(out, edge - 3, y)[1], lessThan(100), reason: 'edge $edge');
      expect(pixel(out, edge + 2, y)[1], greaterThan(150));
    });

    testWidgets('signalInterference shifts its slices', (tester) async {
      const effect = VideoEffect.signalInterference();
      final frame = effect.frameAt(Duration.zero);
      final out = await frameOf(
        await render(stripe, const [effect]),
        Duration.zero,
      );
      // Inside each slice the stripe moves by the slice's shift; green, read
      // in place, shows it without the channel split. Slices thinner than a
      // few rows are left to the codec.
      var checked = 0;
      for (final band in frame.bands) {
        final top = toPixels(band.top, height);
        final bottom = toPixels(band.bottom, height);
        if (bottom - top < 5) continue;
        final row = (top + bottom) ~/ 2;
        final shift = toPixels(band.shift, width);
        final movedInto = shift > 0 ? 384 + shift ~/ 2 : 256 + shift ~/ 2;
        final movedOutOf = shift > 0 ? 256 + shift ~/ 2 : 384 + shift ~/ 2;
        expect(pixel(out, movedInto, row)[1], greaterThan(150));
        expect(pixel(out, movedOutOf, row)[1], lessThan(100));
        checked++;
      }
      expect(checked, greaterThan(0));
    });

    testWidgets('filmGrain adds grain, not brightness', (tester) async {
      const at = Duration(milliseconds: 500);
      final plain = await frameOf(await render(midGrey, const []), at);
      final out = await frameOf(
        await render(midGrey, const [VideoEffect.filmGrain()]),
        at,
      );
      var plainSum = 0;
      var sum = 0;
      var sumOfSquares = 0;
      for (var y = 160; y < 200; y++) {
        for (var x = 300; x < 340; x++) {
          final g = grey(pixel(out, x, y));
          plainSum += grey(pixel(plain, x, y));
          sum += g;
          sumOfSquares += g * g;
        }
      }
      const n = 1600;
      final mean = sum / n;
      final variance = sumOfSquares / n - mean * mean;
      // The grain moves each pixel by up to 7% either way, a spread of about
      // 10 levels, and averages out over the patch. The encoder keeps only
      // part of grain this fine: about 4 levels on a Galaxy S26, 8 on macOS.
      expect((mean - plainSum / n).abs(), lessThan(3));
      expect(variance, greaterThan(4), reason: 'variance $variance');
    });

    testWidgets('crt darkens its scanlines', (tester) async {
      const at = Duration(milliseconds: 500);
      const effect = VideoEffect.crt();
      // 360 / 200 rounds to a period of two rows: every odd row is dark.
      expect(toPixels(effect.frameAt(at).scanlinePeriod, height), 2);
      final plain = await frameOf(await render(midGrey, const []), at);
      final out = await frameOf(await render(midGrey, const [effect]), at);
      // A patch at the center, where the corners' darkening has not started.
      var plainSum = 0;
      var dark = 0;
      var bright = 0;
      for (var y = 160; y < 200; y++) {
        for (var x = 300; x < 340; x++) {
          plainSum += grey(pixel(plain, x, y));
          final g = grey(pixel(out, x, y));
          if (y.isOdd) {
            dark += g;
          } else {
            bright += g;
          }
        }
      }
      // The bright rows are lifted by 12%, the dark ones keep 45% of that;
      // the encoder blurs rows this thin a little towards each other.
      final base = plainSum / 1600;
      expect(bright / 800, greaterThan(base), reason: 'base $base');
      expect(dark / 800, lessThan(base * 0.75), reason: 'base $base');
    });
  });
}
