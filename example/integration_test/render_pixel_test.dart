import 'dart:typed_data';
import 'dart:ui'
    show
        Canvas,
        Color,
        ImageByteFormat,
        Offset,
        Paint,
        PictureRecorder,
        Rect,
        Size,
        instantiateImageCodec;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Pixel-level verification that render effects actually transform the frame —
/// not just that the render completes. Each effect output is decoded back to a
/// frame (via a PNG thumbnail) and its pixels are compared against the source.
///
/// All assertions are deliberately *content-independent*: they compare the
/// effect output against the source (or against an internal invariant such as
/// "R == G == B") rather than hard-coding any expected colors, so they stay
/// robust against YUV/codec rounding.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;

  final h264Video = EditorVideo.asset(kVideoEditorExampleH264Path);
  final hevcVideo = EditorVideo.asset(kVideoEditorExampleHevcPath);

  /// Sample points that include the center axes — fine for color tests.
  const colorPoints = <Offset>[
    Offset(0.2, 0.3),
    Offset(0.5, 0.3),
    Offset(0.8, 0.3),
    Offset(0.2, 0.5),
    Offset(0.5, 0.5),
    Offset(0.8, 0.5),
    Offset(0.2, 0.7),
    Offset(0.5, 0.7),
    Offset(0.8, 0.7),
  ];

  /// Sample points that avoid both center axes (0.5) — required for mirror
  /// checks, where a center pixel maps onto itself.
  const geoPoints = <Offset>[
    Offset(0.15, 0.25),
    Offset(0.35, 0.25),
    Offset(0.65, 0.25),
    Offset(0.85, 0.25),
    Offset(0.15, 0.4),
    Offset(0.35, 0.4),
    Offset(0.65, 0.4),
    Offset(0.85, 0.4),
    Offset(0.15, 0.6),
    Offset(0.35, 0.6),
    Offset(0.65, 0.6),
    Offset(0.85, 0.6),
    Offset(0.15, 0.75),
    Offset(0.35, 0.75),
    Offset(0.65, 0.75),
    Offset(0.85, 0.75),
  ];

  /// Decodes a frame at [at], sized to the video's own aspect ratio so that
  /// `cover` performs no crop and relative coordinates map linearly.
  /// Decodes a frame, or returns null if no frame could be extracted (e.g. some
  /// devices cannot thumbnail 10-bit HDR HEVC at an arbitrary timestamp).
  Future<_Frame?> tryFrameOf(
    EditorVideo video, {
    Duration at = const Duration(seconds: 1),
  }) async {
    final meta = await pve.getMetadata(video);
    const baseHeight = 200.0;
    final width = (baseHeight * meta.resolution.aspectRatio).roundToDouble();
    final size = Size(width, baseHeight);

    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputFormat: ThumbnailFormat.png,
        timestamps: [at],
        outputSize: size,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    if (frames.isEmpty) return null;
    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    return _Frame(data!, image.width, image.height);
  }

  Future<_Frame> frameOf(
    EditorVideo video, {
    Duration at = const Duration(seconds: 1),
  }) async {
    final frame = await tryFrameOf(video, at: at);
    expect(frame, isNotNull, reason: 'no frame extracted');
    return frame!;
  }

  Future<Uint8List> renderFilter(EditorVideo video, List<double> matrix) {
    return pve.renderVideo(
      VideoRenderData(
        videoSegments: [VideoSegment(video: video)],
        outputFormat: VideoOutputFormat.mp4,
        colorFilters: [ColorFilter(matrix: matrix)],
      ),
    );
  }

  group('Color filters', () {
    testWidgets('identity matrix preserves the image', (tester) async {
      final bytes = await renderFilter(h264Video, _identity);
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      final meanError = _meanError(out, original, colorPoints, (o, s) => o);
      expect(
        meanError,
        lessThan(40),
        reason: 'identity filter should not noticeably alter pixels',
      );
    }, skip: kIsWeb);

    testWidgets('grayscale desaturates colored pixels', (tester) async {
      final bytes = await renderFilter(h264Video, _grayscale);
      final original = await frameOf(h264Video);
      final gray = await frameOf(EditorVideo.memory(bytes));

      var colored = 0;
      var desaturated = 0;
      for (final p in colorPoints) {
        if (_spread(original.at(p.dx, p.dy)) > 25) {
          colored++;
          if (_spread(gray.at(p.dx, p.dy)) <= 20) desaturated++;
        }
      }
      expect(colored, greaterThan(0), reason: 'no colored source pixels');
      expect(
        desaturated,
        equals(colored),
        reason: '$colored colored sample(s) stayed saturated',
      );
    }, skip: kIsWeb);

    testWidgets('invert produces the photographic negative', (tester) async {
      final bytes = await renderFilter(h264Video, _invert);
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      // Error against the expected negative must be far smaller than the
      // error a non-inverted (identity) output would show.
      final negError = _meanError(
        out,
        original,
        colorPoints,
        (o, s) => 255 - s,
      );
      final idError = _meanError(out, original, colorPoints, (o, s) => s);
      expect(negError, lessThan(55), reason: 'output is not a negative');
      expect(
        negError,
        lessThan(idError),
        reason: 'output matches the source more than its negative',
      );
    }, skip: kIsWeb);

    testWidgets('half-scale matrix darkens the image', (tester) async {
      final bytes = await renderFilter(h264Video, _darken);
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      expect(
        _meanLuma(out, colorPoints),
        lessThan(_meanLuma(original, colorPoints) * 0.75),
        reason: 'a 0.5 scale matrix must visibly darken the frame',
      );
    }, skip: kIsWeb);

    testWidgets('channel-swap matrix swaps red and blue', (tester) async {
      final bytes = await renderFilter(h264Video, _swapRB);
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      var tested = 0;
      var swapError = 0;
      var keepError = 0;
      for (final p in colorPoints) {
        final s = original.at(p.dx, p.dy);
        if ((s[0] - s[2]).abs() < 30) continue; // need R≠B to tell them apart
        tested++;
        final o = out.at(p.dx, p.dy);
        swapError += (o[0] - s[2]).abs() + (o[2] - s[0]).abs();
        keepError += (o[0] - s[0]).abs() + (o[2] - s[2]).abs();
      }
      expect(tested, greaterThan(0), reason: 'no R≠B pixels to test the swap');
      expect(
        swapError,
        lessThan(keepError),
        reason: 'output red/blue match the swapped source channels',
      );
    }, skip: kIsWeb);

    testWidgets('zero matrix blacks out the frame', (tester) async {
      final bytes = await renderFilter(h264Video, _blackout);
      final out = await frameOf(EditorVideo.memory(bytes));

      for (final p in colorPoints) {
        final c = out.at(p.dx, p.dy);
        expect(
          c[0] + c[1] + c[2],
          lessThan(100),
          reason: 'pixel ${p.dx},${p.dy} is not black: $c',
        );
      }
    }, skip: kIsWeb);
  });

  group('Geometric transforms', () {
    Future<Uint8List> renderTransform(ExportTransform transform) {
      return pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          transform: transform,
        ),
      );
    }

    testWidgets('flipX mirrors horizontally', (tester) async {
      final bytes = await renderTransform(const ExportTransform(flipX: true));
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      final mirror = _matchSum(
        out,
        original,
        geoPoints,
        (x, y) => Offset(1 - x, y),
      );
      final identity = _matchSum(out, original, geoPoints, Offset.new);
      expect(identity, greaterThan(0), reason: 'source frame is uniform');
      expect(
        mirror,
        lessThan(identity),
        reason: 'flipped frame matches the horizontally mirrored source',
      );
    }, skip: kIsWeb);

    testWidgets('flipY mirrors vertically', (tester) async {
      final bytes = await renderTransform(const ExportTransform(flipY: true));
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      final mirror = _matchSum(
        out,
        original,
        geoPoints,
        (x, y) => Offset(x, 1 - y),
      );
      final identity = _matchSum(out, original, geoPoints, Offset.new);
      expect(
        mirror,
        lessThan(identity),
        reason: 'flipped frame matches the vertically mirrored source',
      );
    }, skip: kIsWeb);

    testWidgets('flipX + flipY rotates 180°', (tester) async {
      final bytes = await renderTransform(
        const ExportTransform(flipX: true, flipY: true),
      );
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      final flipped = _matchSum(
        out,
        original,
        geoPoints,
        (x, y) => Offset(1 - x, 1 - y),
      );
      final identity = _matchSum(out, original, geoPoints, Offset.new);
      expect(
        flipped,
        lessThan(identity),
        reason: 'double flip matches the 180°-rotated source',
      );
    }, skip: kIsWeb);

    testWidgets('crop selects the requested source region', (tester) async {
      const cropX = 200, cropY = 150, cropW = 700, cropH = 300;
      final bytes = await renderTransform(
        const ExportTransform(x: cropX, y: cropY, width: cropW, height: cropH),
      );

      final srcMeta = await pve.getMetadata(h264Video);
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      // Map each output point into the source crop window, then compare with
      // the same point taken at face value (the wrong region).
      var regionSum = 0;
      var wrongSum = 0;
      for (final p in geoPoints) {
        final sx = (cropX + p.dx * cropW) / srcMeta.resolution.width;
        final sy = (cropY + p.dy * cropH) / srcMeta.resolution.height;
        final o = out.at(p.dx, p.dy);
        regionSum += _dist(o, original.at(sx, sy));
        wrongSum += _dist(o, original.at(p.dx, p.dy));
      }
      expect(
        regionSum,
        lessThan(wrongSum),
        reason: 'crop output matches the requested source sub-rectangle',
      );
    }, skip: kIsWeb);
  });

  group('Blur', () {
    testWidgets('reduces high-frequency detail', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 20,
        ),
      );
      final original = await frameOf(h264Video);
      final blurred = await frameOf(EditorVideo.memory(bytes));

      final sharpOriginal = _sharpness(original);
      final sharpBlurred = _sharpness(blurred);
      expect(sharpOriginal, greaterThan(0));
      expect(
        sharpBlurred,
        lessThan(sharpOriginal * 0.9),
        reason: 'blurred frame should be measurably smoother',
      );
    }, skip: kIsWeb);

    testWidgets('preserves overall brightness', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          blur: 20,
        ),
      );
      final original = await frameOf(h264Video);
      final blurred = await frameOf(EditorVideo.memory(bytes));

      final lumaOriginal = _meanLuma(original, colorPoints);
      final lumaBlurred = _meanLuma(blurred, colorPoints);
      expect(
        lumaBlurred,
        closeTo(lumaOriginal, lumaOriginal * 0.25 + 15),
        reason: 'blur must not significantly shift overall brightness',
      );
    }, skip: kIsWeb);
  });

  group('Timed color filter', () {
    testWidgets('applies only inside its time window', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: _grayscale,
              startTime: const Duration(seconds: 3),
              endTime: const Duration(seconds: 6),
            ),
          ],
        ),
      );

      const inside = Duration(milliseconds: 4500);
      const outside = Duration(seconds: 1);

      final srcInside = await frameOf(h264Video, at: inside);
      final srcOutside = await frameOf(h264Video, at: outside);
      final outInside = await frameOf(EditorVideo.memory(bytes), at: inside);
      final outOutside = await frameOf(EditorVideo.memory(bytes), at: outside);

      // Inside the window: colored source pixels become desaturated.
      var insideColored = 0, insideDesat = 0;
      for (final p in colorPoints) {
        if (_spread(srcInside.at(p.dx, p.dy)) > 25) {
          insideColored++;
          if (_spread(outInside.at(p.dx, p.dy)) <= 20) insideDesat++;
        }
      }
      expect(insideColored, greaterThan(0));
      expect(
        insideDesat,
        equals(insideColored),
        reason: 'filter did not apply inside its window',
      );

      // Outside the window: colored source pixels stay colored.
      var outsideColored = 0, outsideStillColored = 0;
      for (final p in colorPoints) {
        if (_spread(srcOutside.at(p.dx, p.dy)) > 25) {
          outsideColored++;
          if (_spread(outOutside.at(p.dx, p.dy)) > 20) outsideStillColored++;
        }
      }
      expect(outsideColored, greaterThan(0));
      expect(
        outsideStillColored,
        equals(outsideColored),
        reason: 'filter leaked outside its window',
      );
    }, skip: kIsWeb);
  });

  group('Combined effects', () {
    testWidgets('grayscale + flipX apply together', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: h264Video)],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [const ColorFilter(matrix: _grayscale)],
          transform: const ExportTransform(flipX: true),
        ),
      );
      final original = await frameOf(h264Video);
      final out = await frameOf(EditorVideo.memory(bytes));

      // Desaturated everywhere it was colored...
      var colored = 0, desaturated = 0;
      for (final p in colorPoints) {
        if (_spread(original.at(p.dx, p.dy)) > 25) {
          colored++;
          if (_spread(out.at(p.dx, p.dy)) <= 20) desaturated++;
        }
      }
      expect(colored, greaterThan(0));
      expect(desaturated, equals(colored), reason: 'grayscale not applied');

      // ...and mirrored (compare luminance, since color was removed).
      final mirror = _lumaMatchSum(
        out,
        original,
        geoPoints,
        (x, y) => Offset(1 - x, y),
      );
      final identity = _lumaMatchSum(out, original, geoPoints, Offset.new);
      expect(mirror, lessThan(identity), reason: 'flipX not applied');
    }, skip: kIsWeb);
  });

  group('HEVC source', () {
    testWidgets('grayscale desaturates an HEVC frame', (tester) async {
      final bytes = await renderFilter(hevcVideo, _grayscale);
      final original = await tryFrameOf(hevcVideo);
      final gray = await tryFrameOf(EditorVideo.memory(bytes));
      if (original == null || gray == null) {
        markTestSkipped('HDR HEVC frame not extractable on this device');
        return;
      }

      var colored = 0, desaturated = 0;
      for (final p in colorPoints) {
        if (_spread(original.at(p.dx, p.dy)) > 25) {
          colored++;
          if (_spread(gray.at(p.dx, p.dy)) <= 20) desaturated++;
        }
      }
      // Some devices tone-map the HDR HEVC frame to a near-gray image, leaving
      // no colored source pixels to verify desaturation against.
      if (colored == 0) {
        markTestSkipped('HEVC frame has no colored pixels on this device');
        return;
      }
      expect(desaturated, equals(colored));
    }, skip: kIsWeb);

    testWidgets('flipX mirrors an HEVC frame', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
          transform: const ExportTransform(flipX: true),
        ),
      );
      final original = await tryFrameOf(hevcVideo);
      final out = await tryFrameOf(EditorVideo.memory(bytes));
      if (original == null || out == null) {
        markTestSkipped('HDR HEVC frame not extractable on this device');
        return;
      }

      final mirror = _matchSum(
        out,
        original,
        geoPoints,
        (x, y) => Offset(1 - x, y),
      );
      final identity = _matchSum(out, original, geoPoints, Offset.new);
      expect(mirror, lessThan(identity), reason: 'HEVC flipX not applied');
    }, skip: kIsWeb);

    // The Darwin HDR pre-transcode once fed green into blue, so every frame it
    // produced had B == G. B - G depends on chroma alone, which 4:2:0
    // subsampling averages linearly, so the round trip keeps it at codec
    // noise: with that matrix no pixel of this frame differs by more than 4
    // (macOS), while the source's yellow and gold areas put ~15% of them past
    // the tolerance of 8 once blue is blue again.
    //
    // The count is weighed against R - G instead of the frame size, because
    // how saturated a tone-mapped HDR frame comes out varies by device and
    // scales both differences alike. R - G is untouched by the bug, so a
    // broken build keeps its colored pixels and can never take the skip below.
    testWidgets('HEVC render keeps its blue channel', (tester) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [VideoSegment(video: hevcVideo)],
          outputFormat: VideoOutputFormat.mp4,
        ),
      );
      final out = await tryFrameOf(EditorVideo.memory(bytes));
      if (out == null) {
        markTestSkipped('HDR HEVC frame not extractable on this device');
        return;
      }

      const tolerance = 8;
      final total = out.width * out.height;
      var blueApart = 0, redApart = 0;
      for (var i = 0; i < total; i++) {
        final r = out.data.getUint8(i * 4);
        final g = out.data.getUint8(i * 4 + 1);
        final b = out.data.getUint8(i * 4 + 2);
        if ((b - g).abs() > tolerance) blueApart++;
        if ((r - g).abs() > tolerance) redApart++;
      }
      if (redApart < total ~/ 100) {
        markTestSkipped('HEVC render has no colored pixels on this device');
        return;
      }
      // macOS: 3381 blue vs 5735 red pixels; the broken matrix: 0 vs 5832.
      expect(
        blueApart,
        greaterThan(redApart ~/ 20),
        reason:
            'B == G across the frame ($blueApart of $total pixels apart, '
            '$redApart differ in R): the blue channel was replaced',
      );
    }, skip: kIsWeb);
  });

  group('Animated layer offset', () {
    // Four solid frames of 500 ms each: red, green, blue, white.
    final steps = EditorLayerImage.asset('assets/tests/color_steps.gif');

    // One layer per quadrant of the 1280x720 source, so a single render
    // covers every case.
    ImageLayer quadrant(
      int column,
      int row, {
      required Duration start,
      Duration end = const Duration(seconds: 3),
      Duration animationOffset = Duration.zero,
      bool loop = true,
    }) {
      return ImageLayer(
        image: steps,
        offset: Offset(column * 640.0, row * 360.0),
        size: const Size(640, 360),
        startTime: start,
        endTime: end,
        animationOffset: animationOffset,
        loop: loop,
      );
    }

    testWidgets('starts playback at the offset and carries it across layers', (
      tester,
    ) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: h264Video, endTime: const Duration(seconds: 3)),
          ],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: [
            // Top left: no offset, opens on the first frame at 1 s.
            quadrant(0, 0, start: const Duration(seconds: 1)),
            // Top right: one animation split over two layers at 1 s.
            quadrant(
              1,
              0,
              start: Duration.zero,
              end: const Duration(seconds: 1),
            ),
            quadrant(
              1,
              0,
              start: const Duration(seconds: 1),
              animationOffset: const Duration(seconds: 1),
            ),
            // Bottom left: an offset past one playthrough wraps around.
            quadrant(
              0,
              1,
              start: const Duration(seconds: 1),
              animationOffset: const Duration(milliseconds: 2500),
            ),
            // Bottom right: an offset past the end holds the last frame.
            quadrant(
              1,
              1,
              start: const Duration(seconds: 1),
              animationOffset: const Duration(seconds: 5),
              loop: false,
            ),
          ],
        ),
      );
      final out = EditorVideo.memory(bytes);

      Future<List<String>> quadrantsAt(int ms) async {
        final f = await frameOf(out, at: Duration(milliseconds: ms));
        return [
          _colorName(f.at(0.25, 0.25)),
          _colorName(f.at(0.75, 0.25)),
          _colorName(f.at(0.25, 0.75)),
          _colorName(f.at(0.75, 0.75)),
        ];
      }

      expect(
        (await quadrantsAt(750))[1],
        'green',
        reason: 'the first layer plays from its first frame',
      );
      expect(await quadrantsAt(1250), ['red', 'blue', 'green', 'white']);
      expect(await quadrantsAt(1750), ['green', 'white', 'blue', 'white']);
    }, skip: kIsWeb);
  });

  group('Wiggle, bounce and animation ranges', () {
    // The 1280x720 source, read back at 200 px high; a point is given in
    // source pixels.
    bool magentaAt(_Frame f, double x, double y) =>
        _isMagenta(f.at(x / 1280, y / 720));

    Future<EditorVideo> render(List<ImageLayer> layers) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: h264Video, endTime: const Duration(seconds: 3)),
          ],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: layers,
        ),
      );
      return EditorVideo.memory(bytes);
    }

    testWidgets('a bounce lifts the layer by a multiple of its height', (
      tester,
    ) async {
      // 200x100 at rest on y 310..410; lifted by twice its height at first.
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(
            await _solidPng(_magenta, width: 200, height: 100),
          ),
          offset: const Offset(540, 310),
          size: const Size(200, 100),
          startTime: Duration.zero,
          endTime: const Duration(seconds: 3),
          animations: const [
            LayerAnimation(
              type: LayerAnimationType.bounce,
              phase: AnimationPhase.animateIn,
              duration: Duration(seconds: 2),
              bounceHeight: 2,
            ),
          ],
        ),
      ]);

      // Half way: lifted by one height, onto y 210..310.
      final mid = await frameOf(out, at: const Duration(milliseconds: 1000));
      expect(magentaAt(mid, 640, 260), isTrue, reason: 'lifted');
      expect(magentaAt(mid, 640, 380), isFalse, reason: 'not yet landed');

      final rest = await frameOf(out, at: const Duration(milliseconds: 2500));
      expect(magentaAt(rest, 640, 380), isTrue, reason: 'landed');
      expect(magentaAt(rest, 640, 260), isFalse, reason: 'landed');
    }, skip: kIsWeb);

    testWidgets('a wiggle loop tilts to one side and then the other', (
      tester,
    ) async {
      // A needle pointing up from the middle of the frame, turned around
      // the centre of its 40x400 box: 90° clockwise at a quarter of each 2 s
      // cycle, 90° counter-clockwise at three quarters.
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(await _needlePng()),
          offset: const Offset(620, 160),
          size: const Size(40, 400),
          startTime: Duration.zero,
          endTime: const Duration(seconds: 3),
          animations: const [
            LayerAnimation(
              type: LayerAnimationType.wiggle,
              phase: AnimationPhase.loop,
              duration: Duration(seconds: 2),
              wiggleAngle: 1.5707963267948966,
            ),
          ],
        ),
      ]);

      final right = await frameOf(out, at: const Duration(milliseconds: 500));
      expect(magentaAt(right, 740, 360), isTrue, reason: 'points right');
      expect(magentaAt(right, 640, 260), isFalse, reason: 'points right');

      final up = await frameOf(out, at: const Duration(milliseconds: 1000));
      expect(magentaAt(up, 640, 260), isTrue, reason: 'upright');

      final left = await frameOf(out, at: const Duration(milliseconds: 1500));
      expect(magentaAt(left, 540, 360), isTrue, reason: 'points left');
      expect(magentaAt(left, 740, 360), isFalse, reason: 'points left');
    }, skip: kIsWeb);

    testWidgets('layers sharing an animation range carry one animation on', (
      tester,
    ) async {
      final image = EditorLayerImage.memory(
        await _solidPng(_magenta, width: 200, height: 100),
      );
      // One overlay split at 1 s into two layers, the way a text that types
      // itself out is split into its steps. Both count the 2 s bounce from
      // 0 s; on its own, the second would start its bounce over at 1 s.
      ImageLayer part(Duration start, Duration end) => ImageLayer(
        image: image,
        offset: const Offset(540, 310),
        size: const Size(200, 100),
        startTime: start,
        endTime: end,
        animationStartTime: Duration.zero,
        animationEndTime: const Duration(seconds: 3),
        animations: const [
          LayerAnimation(
            type: LayerAnimationType.bounce,
            phase: AnimationPhase.animateIn,
            duration: Duration(seconds: 2),
            bounceHeight: 2,
          ),
        ],
      );
      final out = await render([
        part(Duration.zero, const Duration(seconds: 1)),
        part(const Duration(seconds: 1), const Duration(seconds: 3)),
      ]);

      // Three quarters in: lifted by half its height, onto y 260..360.
      // Restarted, it would be lifted by one and a half, onto y 160..260.
      final f = await frameOf(out, at: const Duration(milliseconds: 1500));
      expect(magentaAt(f, 640, 290), isTrue);
      expect(magentaAt(f, 640, 230), isFalse);
    }, skip: kIsWeb);
  });

  group('Keyframes and loop windows', () {
    // The 1280x720 source, read back at 200 px high; a point is given in
    // source pixels.
    bool magentaAt(_Frame f, double x, double y) =>
        _isMagenta(f.at(x / 1280, y / 720));

    Future<EditorVideo> render(List<ImageLayer> layers) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(video: h264Video, endTime: const Duration(seconds: 3)),
          ],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: layers,
        ),
      );
      return EditorVideo.memory(bytes);
    }

    testWidgets('keyframes move a layer and hold the last one', (tester) async {
      // 200x100 from (100, 100) at 0 s to (900, 500) at 2 s.
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(
            await _solidPng(_magenta, width: 200, height: 100),
          ),
          offset: const Offset(100, 100),
          size: const Size(200, 100),
          keyframes: const [
            TimelineKeyframe(time: Duration.zero, offset: Offset(100, 100)),
            TimelineKeyframe(
              time: Duration(seconds: 2),
              offset: Offset(900, 500),
            ),
          ],
        ),
      ]);

      // Half way: on (500, 300), centred on (600, 350).
      final mid = await frameOf(out, at: const Duration(milliseconds: 1000));
      expect(magentaAt(mid, 600, 350), isTrue, reason: 'half way');
      expect(magentaAt(mid, 200, 150), isFalse, reason: 'left its start');

      final end = await frameOf(out, at: const Duration(milliseconds: 2500));
      expect(magentaAt(end, 1000, 550), isTrue, reason: 'holds the last');
      expect(magentaAt(end, 600, 350), isFalse, reason: 'holds the last');
    }, skip: kIsWeb);

    testWidgets('keyframes turn and scale a layer around its centre', (
      tester,
    ) async {
      // The needle from the middle of the frame, turned a quarter clockwise
      // and halved by 1 s: it then points right, 100 px long.
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(await _needlePng()),
          offset: const Offset(620, 160),
          size: const Size(40, 400),
          keyframes: const [
            TimelineKeyframe(time: Duration.zero, offset: Offset(620, 160)),
            TimelineKeyframe(
              time: Duration(seconds: 1),
              offset: Offset(620, 160),
              rotation: 1.5707963267948966,
              scale: 0.5,
            ),
          ],
        ),
      ]);

      final start = await frameOf(out, at: Duration.zero);
      expect(magentaAt(start, 640, 260), isTrue, reason: 'upright');

      final turned = await frameOf(out, at: const Duration(milliseconds: 1500));
      expect(magentaAt(turned, 690, 360), isTrue, reason: 'points right');
      expect(magentaAt(turned, 790, 360), isFalse, reason: 'halved');
      expect(magentaAt(turned, 640, 260), isFalse, reason: 'no longer up');
    }, skip: kIsWeb);

    testWidgets('keyframes fade a layer', (tester) async {
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(
            await _solidPng(_magenta, width: 200, height: 100),
          ),
          offset: const Offset(540, 310),
          size: const Size(200, 100),
          keyframes: const [
            TimelineKeyframe(time: Duration.zero, offset: Offset(540, 310)),
            TimelineKeyframe(
              time: Duration(seconds: 2),
              offset: Offset(540, 310),
              opacity: 0,
            ),
          ],
        ),
      ]);

      final start = await frameOf(out, at: Duration.zero);
      expect(magentaAt(start, 640, 360), isTrue, reason: 'opaque');
      final end = await frameOf(out, at: const Duration(milliseconds: 2500));
      expect(magentaAt(end, 640, 360), isFalse, reason: 'faded out');
    }, skip: kIsWeb);

    testWidgets('turned layers centred off the frame show only their part '
        'on it', (tester) async {
      final square = EditorLayerImage.memory(
        await _solidPng(_magenta, width: 400, height: 400),
      );
      // A 400x400 square turned 45°: its corners reach 283 px from its
      // centre. Turned by a keyframe or by its own rotation.
      ImageLayer turned(Offset offset, {bool keyframed = true}) => ImageLayer(
        image: square,
        offset: offset,
        size: const Size(400, 400),
        rotation: keyframed ? 0 : 0.7853981633974483,
        keyframes: [
          if (keyframed)
            TimelineKeyframe(
              time: Duration.zero,
              offset: offset,
              rotation: 0.7853981633974483,
            ),
        ],
      );
      final out = await render([
        // Centred 800 px left of the frame, nowhere near it.
        turned(const Offset(-1000, 0)),
        // Centred 50 px left of the frame: its corner reaches 233 px in.
        turned(const Offset(-250, 360)),
        // Centred 50 px right of the frame: its corner reaches 233 px in.
        turned(const Offset(1130, 0), keyframed: false),
        // Centred 820 px right of the frame, nowhere near it.
        turned(const Offset(1900, 360), keyframed: false),
      ]);

      final f = await frameOf(out, at: const Duration(milliseconds: 500));
      expect(magentaAt(f, 20, 200), isFalse, reason: 'keyframed, off');
      expect(magentaAt(f, 100, 560), isTrue, reason: 'keyframed, partly on');
      expect(magentaAt(f, 1180, 200), isTrue, reason: 'rotated, partly on');
      expect(magentaAt(f, 1260, 560), isFalse, reason: 'rotated, off');
    }, skip: kIsWeb);

    testWidgets('a loop plays only within its window, from its start', (
      tester,
    ) async {
      // A 1 s wiggle between 1.5 s and 2.5 s: a quarter of a cycle in, at
      // 1.75 s, it points right; counted from 0 s it would point left.
      final out = await render([
        ImageLayer(
          image: EditorLayerImage.memory(await _needlePng()),
          offset: const Offset(620, 160),
          size: const Size(40, 400),
          startTime: Duration.zero,
          endTime: const Duration(seconds: 3),
          animations: const [
            LayerAnimation(
              type: LayerAnimationType.wiggle,
              phase: AnimationPhase.loop,
              duration: Duration(seconds: 1),
              wiggleAngle: 1.5707963267948966,
              loopStart: Duration(milliseconds: 1500),
              loopEnd: Duration(milliseconds: 2500),
            ),
          ],
        ),
      ]);

      final before = await frameOf(out, at: const Duration(milliseconds: 1250));
      expect(magentaAt(before, 640, 260), isTrue, reason: 'still before');

      final inside = await frameOf(out, at: const Duration(milliseconds: 1750));
      expect(magentaAt(inside, 740, 360), isTrue, reason: 'points right');
      expect(magentaAt(inside, 540, 360), isFalse, reason: 'points right');

      final after = await frameOf(out, at: const Duration(milliseconds: 2750));
      expect(magentaAt(after, 640, 260), isTrue, reason: 'over');
    }, skip: kIsWeb);
  });

  group('Sped-up segments', () {
    // The 1280x720 source, read back at 200 px high; a point is given in
    // source pixels.
    bool magentaAt(_Frame f, double x, double y) =>
        _isMagenta(f.at(x / 1280, y / 720));

    // The first 4 s of the source at double speed: 2 s of output.
    final spedUp = VideoSegment(
      video: h264Video,
      endTime: const Duration(seconds: 4),
      playbackSpeed: 2,
    );

    Future<EditorVideo> render(
      List<ImageLayer> layers, {
      List<VideoSegment>? segments,
    }) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: segments ?? [spedUp],
          outputFormat: VideoOutputFormat.mp4,
          imageLayers: layers,
        ),
      );
      return EditorVideo.memory(bytes);
    }

    Future<ImageLayer> box({
      Duration? start,
      Duration? end,
      List<TimelineKeyframe> keyframes = const [],
    }) async => ImageLayer(
      image: EditorLayerImage.memory(
        await _solidPng(_magenta, width: 200, height: 100),
      ),
      offset: const Offset(540, 310),
      size: const Size(200, 100),
      startTime: start,
      endTime: end,
      keyframes: keyframes,
    );

    testWidgets('an image layer shows over its output time range', (
      tester,
    ) async {
      final out = await render([
        await box(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
        ),
      ]);

      // At 0.5 s of output the source is at 1 s, where a layer timed on the
      // source would already show.
      final before = await frameOf(out, at: const Duration(milliseconds: 500));
      expect(magentaAt(before, 640, 360), isFalse, reason: 'not yet');
      final inside = await frameOf(out, at: const Duration(milliseconds: 1500));
      expect(magentaAt(inside, 640, 360), isTrue, reason: 'showing');
    }, skip: kIsWeb);

    testWidgets('keyframes move a layer on the output timeline', (
      tester,
    ) async {
      // From (100, 100) at 0 s to (900, 500) at 2 s of output.
      final out = await render([
        await box(
          keyframes: const [
            TimelineKeyframe(time: Duration.zero, offset: Offset(100, 100)),
            TimelineKeyframe(
              time: Duration(seconds: 2),
              offset: Offset(900, 500),
            ),
          ],
        ),
      ]);

      // Half way at 1 s, centred on (600, 350); timed on the source it would
      // already rest on (900, 500).
      final mid = await frameOf(out, at: const Duration(milliseconds: 1000));
      expect(magentaAt(mid, 600, 350), isTrue, reason: 'half way');
      expect(magentaAt(mid, 1000, 550), isFalse, reason: 'not there yet');
    }, skip: kIsWeb);

    testWidgets('a layer after a sped-up segment keeps its time', (
      tester,
    ) async {
      // 2 s of source at double speed, then 2 s at normal speed: the second
      // segment runs from 1 s to 3 s of output.
      final out = await render(
        [
          await box(
            start: const Duration(milliseconds: 1500),
            end: const Duration(seconds: 3),
          ),
        ],
        segments: [
          VideoSegment(
            video: h264Video,
            endTime: const Duration(seconds: 2),
            playbackSpeed: 2,
          ),
          VideoSegment(
            video: h264Video,
            startTime: const Duration(seconds: 2),
            endTime: const Duration(seconds: 4),
          ),
        ],
      );

      final first = await frameOf(out, at: const Duration(milliseconds: 800));
      expect(magentaAt(first, 640, 360), isFalse, reason: 'first segment');
      final early = await frameOf(out, at: const Duration(milliseconds: 1250));
      expect(magentaAt(early, 640, 360), isFalse, reason: 'not yet');
      final inside = await frameOf(out, at: const Duration(milliseconds: 2000));
      expect(magentaAt(inside, 640, 360), isTrue, reason: 'showing');
    }, skip: kIsWeb);

    testWidgets('a timed color filter applies over its output time range', (
      tester,
    ) async {
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [spedUp],
          outputFormat: VideoOutputFormat.mp4,
          colorFilters: [
            ColorFilter(
              matrix: _grayscale,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
      );
      final out = EditorVideo.memory(bytes);

      // Output time t shows the source at 2t.
      Future<(int, int)> coloredAt(Duration at) async {
        final source = await frameOf(h264Video, at: at * 2);
        final frame = await frameOf(out, at: at);
        var colored = 0, stillColored = 0;
        for (final p in colorPoints) {
          if (_spread(source.at(p.dx, p.dy)) > 25) {
            colored++;
            if (_spread(frame.at(p.dx, p.dy)) > 20) stillColored++;
          }
        }
        return (colored, stillColored);
      }

      final (outsideColored, outsideKept) = await coloredAt(
        const Duration(milliseconds: 500),
      );
      expect(outsideColored, greaterThan(0));
      expect(outsideKept, outsideColored, reason: 'filter applied too early');

      final (insideColored, insideKept) = await coloredAt(
        const Duration(milliseconds: 1500),
      );
      expect(insideColored, greaterThan(0));
      expect(insideKept, 0, reason: 'filter did not apply inside its window');
    }, skip: kIsWeb);
  });

  group('Dip transition on a letterboxed canvas', () {
    testWidgets('fadeToWhite dips the whole output frame, bars included', (
      tester,
    ) async {
      // A 16:9 source letterboxed onto a taller 9:16 canvas: the bars above
      // and below the picture are part of the output frame and must dip too.
      final bytes = await pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            VideoSegment(
              video: h264Video,
              endTime: const Duration(seconds: 2),
              transition: const ClipTransition(
                type: ClipTransitionType.fadeToWhite,
                duration: Duration(seconds: 1),
              ),
            ),
            VideoSegment(
              video: h264Video,
              startTime: const Duration(seconds: 2),
              endTime: const Duration(seconds: 4),
            ),
          ],
          outputFormat: VideoOutputFormat.mp4,
          qualityConfig: VideoQualityConfig.custom(
            bitrate: 4000000,
            resolution: const Size(720, 1280),
          ),
        ),
      );
      final out = EditorVideo.memory(bytes);

      const bars = [
        Offset(0.05, 0.05),
        Offset(0.5, 0.1),
        Offset(0.95, 0.2),
        Offset(0.05, 0.8),
        Offset(0.5, 0.9),
        Offset(0.95, 0.95),
      ];

      // Away from the seam the bars are black, so the check below means
      // something.
      final calm = await frameOf(out, at: const Duration(milliseconds: 500));
      expect(
        _meanLuma(calm, bars),
        lessThan(40),
        reason: 'expected black letterbox bars outside the dip',
      );

      final seam = await frameOf(out, at: const Duration(seconds: 2));
      for (final p in [...bars, const Offset(0.5, 0.5)]) {
        expect(
          _luma(seam.at(p.dx, p.dy)),
          greaterThan(180),
          reason: 'pixel ${p.dx},${p.dy} did not dip to white',
        );
      }
    }, skip: kIsWeb);
  });

  group('Image layers on segments of mixed resolution', () {
    // demo.mp4 is 1280x720 and demo_world.mp4 480x270: the same 16:9 shape,
    // so the small segment is scaled up 2.67x into the large one's frame.
    final worldVideo = EditorVideo.asset(kVideoEditorExampleAssetWorldPath);

    // Laid out in the 1280x720 frame the segments are composited into,
    // whichever comes first. On the 480x270 segment, the same pixels taken as
    // its own lie off the frame.
    const centre = Rect.fromLTWH(560, 300, 160, 120);
    const lower = Rect.fromLTWH(160, 560, 160, 120);

    /// With [naturalSize] the layers carry no `size` and are drawn at their
    /// image's own 160x120 pixels instead.
    Future<Uint8List> renderWithLayers(
      List<EditorVideo> videos, {
      bool withCropping = false,
      bool naturalSize = false,
      Duration? endTime,
    }) async {
      final magenta = EditorLayerImage.memory(
        naturalSize
            ? await _solidPng(_magenta, width: 160, height: 120)
            : await _solidPng(_magenta),
      );
      return pve.renderVideo(
        VideoRenderData(
          videoSegments: [
            for (final video in videos)
              VideoSegment(video: video, endTime: const Duration(seconds: 2)),
          ],
          outputFormat: VideoOutputFormat.mp4,
          endTime: endTime,
          imageBytesWithCropping: withCropping,
          qualityConfig: VideoQualityConfig.custom(
            bitrate: 4000000,
            resolution: const Size(1280, 720),
          ),
          imageLayers: [
            for (final rect in [centre, lower])
              ImageLayer(
                image: magenta,
                offset: rect.topLeft,
                size: naturalSize ? null : rect.size,
                startTime: Duration.zero,
              ),
          ],
        ),
      );
    }

    /// Checks that each rect is magenta just inside its edges and not just
    /// outside them, so both its place and its size are pinned.
    void expectLayersAt(_Frame frame, String segment) {
      for (final rect in [centre, lower]) {
        final r = Rect.fromLTRB(
          rect.left / 1280,
          rect.top / 720,
          rect.right / 1280,
          rect.bottom / 720,
        );
        final insetX = r.width * 0.2;
        final insetY = r.height * 0.2;
        final inside = [
          r.center,
          Offset(r.left + insetX, r.top + insetY),
          Offset(r.right - insetX, r.bottom - insetY),
        ];
        final outside = [
          Offset(r.left - insetX, r.center.dy),
          Offset(r.right + insetX, r.center.dy),
          Offset(r.center.dx, r.top - insetY),
          Offset(r.center.dx, r.bottom + insetY),
        ];
        for (final p in inside) {
          expect(
            _isMagenta(frame.at(p.dx, p.dy)),
            isTrue,
            reason:
                '$segment: $rect not drawn at ${p.dx},${p.dy} '
                '(${_colorName(frame.at(p.dx, p.dy))})',
          );
        }
        for (final p in outside) {
          expect(
            _isMagenta(frame.at(p.dx, p.dy)),
            isFalse,
            reason: '$segment: $rect drawn too large, reaching ${p.dx},${p.dy}',
          );
        }
      }
    }

    Future<void> expectBothSegments(Uint8List bytes) async {
      final out = EditorVideo.memory(bytes);
      expectLayersAt(
        await frameOf(out, at: const Duration(seconds: 1)),
        'first segment',
      );
      expectLayersAt(
        await frameOf(out, at: const Duration(seconds: 3)),
        'second segment',
      );
    }

    for (final withCropping in [false, true]) {
      testWidgets('keep their place and size on a smaller later segment '
          '(imageBytesWithCropping: $withCropping)', (tester) async {
        await expectBothSegments(
          await renderWithLayers([
            h264Video,
            worldVideo,
          ], withCropping: withCropping),
        );
      }, skip: kIsWeb);
    }

    testWidgets('are laid out in the frame of a larger later segment', (
      tester,
    ) async {
      await expectBothSegments(await renderWithLayers([worldVideo, h264Video]));
    }, skip: kIsWeb);

    testWidgets('keep their natural size on a smaller later segment', (
      tester,
    ) async {
      await expectBothSegments(
        await renderWithLayers([h264Video, worldVideo], naturalSize: true),
      );
    }, skip: kIsWeb);

    testWidgets('are laid out in the frame of a segment the trim drops', (
      tester,
    ) async {
      // Only the small segment is left, but the large one still sets the
      // frame, as iOS and macOS size the composition before trimming it.
      final bytes = await renderWithLayers([
        worldVideo,
        h264Video,
      ], endTime: const Duration(milliseconds: 1500));
      expectLayersAt(
        await frameOf(
          EditorVideo.memory(bytes),
          at: const Duration(seconds: 1),
        ),
        'trimmed render',
      );
    }, skip: kIsWeb);
  });
}

// ---------------------------------------------------------------------------
// 4x5 color matrices (offsets on a 0–255 scale).
// ---------------------------------------------------------------------------

const _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

const _grayscale = <double>[
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0, 0, 0, 1, 0, //
];

const _invert = <double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
];

const _darken = <double>[
  0.5, 0, 0, 0, 0, //
  0, 0.5, 0, 0, 0, //
  0, 0, 0.5, 0, 0, //
  0, 0, 0, 1, 0, //
];

const _swapRB = <double>[
  0, 0, 1, 0, 0, //
  0, 1, 0, 0, 0, //
  1, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
];

const _blackout = <double>[
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
];

// ---------------------------------------------------------------------------
// Frame + pixel helpers.
// ---------------------------------------------------------------------------

/// A decoded RGBA frame with pixel sampling helpers.
class _Frame {
  _Frame(this.data, this.width, this.height);

  final ByteData data;
  final int width;
  final int height;

  /// RGBA at the relative position ([fx], [fy]) in `0..1`.
  List<int> at(double fx, double fy) {
    final px = (fx * (width - 1)).round().clamp(0, width - 1);
    final py = (fy * (height - 1)).round().clamp(0, height - 1);
    final i = (py * width + px) * 4;
    return [
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ];
  }
}

/// Per-pixel RGB spread (max channel − min channel); 0 means a gray pixel.
int _spread(List<int> c) {
  final rgb = [c[0], c[1], c[2]]..sort();
  return rgb.last - rgb.first;
}

/// Sum of absolute per-channel RGB differences between two pixels.
int _dist(List<int> a, List<int> b) =>
    (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs();

/// Rec.601 luminance of a pixel.
double _luma(List<int> c) => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

/// Names a saturated primary or white, loosely enough to survive YUV coding.
String _colorName(List<int> c) {
  final r = c[0], g = c[1], b = c[2];
  if (r > 180 && g > 180 && b > 180) return 'white';
  if (r > 150 && g < 100 && b < 100) return 'red';
  if (g > 150 && r < 100 && b < 100) return 'green';
  if (b > 150 && r < 100 && g < 100) return 'blue';
  return 'other($r, $g, $b)';
}

const _magenta = Color(0xFFFF00FF);

/// Whether a pixel is the opaque magenta of [_magenta], loosely enough to
/// survive YUV coding. No test source contains it.
bool _isMagenta(List<int> c) => c[0] > 180 && c[1] < 90 && c[2] > 180;

/// An opaque [width] x [height] PNG filled with [color].
Future<Uint8List> _solidPng(
  Color color, {
  int width = 16,
  int height = 16,
}) async {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Mean luminance across [points].
double _meanLuma(_Frame f, List<Offset> points) {
  var sum = 0.0;
  for (final p in points) {
    sum += _luma(f.at(p.dx, p.dy));
  }
  return sum / points.length;
}

/// Mean per-channel error between [out] and an [expected] transform of the
/// matching [source] pixel.
double _meanError(
  _Frame out,
  _Frame source,
  List<Offset> points,
  int Function(int outChannel, int sourceChannel) expected,
) {
  var sum = 0;
  for (final p in points) {
    final o = out.at(p.dx, p.dy);
    final s = source.at(p.dx, p.dy);
    for (var c = 0; c < 3; c++) {
      sum += (o[c] - expected(o[c], s[c])).abs();
    }
  }
  return sum / (points.length * 3);
}

/// Sum of color distances between [out] at each point and [source] at the
/// point produced by [map].
int _matchSum(
  _Frame out,
  _Frame source,
  List<Offset> points,
  Offset Function(double x, double y) map,
) {
  var sum = 0;
  for (final p in points) {
    final m = map(p.dx, p.dy);
    sum += _dist(out.at(p.dx, p.dy), source.at(m.dx, m.dy));
  }
  return sum;
}

/// Like [_matchSum] but compares luminance only (for desaturated outputs).
double _lumaMatchSum(
  _Frame out,
  _Frame source,
  List<Offset> points,
  Offset Function(double x, double y) map,
) {
  var sum = 0.0;
  for (final p in points) {
    final m = map(p.dx, p.dy);
    sum += (_luma(out.at(p.dx, p.dy)) - _luma(source.at(m.dx, m.dy))).abs();
  }
  return sum;
}

/// Total horizontal gradient across the frame — a proxy for image sharpness.
int _sharpness(_Frame f) {
  var sum = 0;
  for (var y = 0; y < f.height; y++) {
    for (var x = 0; x < f.width - 1; x++) {
      final i = (y * f.width + x) * 4;
      final j = i + 4;
      sum += (f.data.getUint8(i) - f.data.getUint8(j)).abs();
      sum += (f.data.getUint8(i + 1) - f.data.getUint8(j + 1)).abs();
      sum += (f.data.getUint8(i + 2) - f.data.getUint8(j + 2)).abs();
    }
  }
  return sum;
}

/// A 40x400 PNG whose upper half is [_magenta] and lower half transparent: a
/// needle pointing up from the centre of its box.
Future<Uint8List> _needlePng() async {
  final recorder = PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 40, 200), Paint()..color = _magenta);
  final image = await recorder.endRecording().toImage(40, 400);
  final data = await image.toByteData(format: ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
