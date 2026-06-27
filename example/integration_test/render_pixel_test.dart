import 'dart:typed_data';
import 'dart:ui' show Offset, Size, instantiateImageCodec;

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
