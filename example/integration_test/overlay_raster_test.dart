import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size, instantiateImageCodec;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:pro_video_editor_example/core/constants/example_constants.dart';

/// Pixel-level verification that an overlay still lands where it was laid out
/// when the export downscales the composition.
///
/// An overlay is laid out in the *composition's* pixel space — the source
/// clip's own resolution — while a custom output resolution is applied after
/// it. Overlays are therefore rastered no larger than that downscale leaves
/// visible, and the shortfall is handed back to Media3 as an overlay scale.
/// That hands the whole placement to `StaticOverlaySettings.setScale`, which
/// these tests exercise on a device: the arithmetic is unit-tested, but whether
/// Media3 scales an overlay about its own centre, and honours a different
/// factor per axis, only a real render can answer.
///
/// The cap only engages when all three hold, so every test here sets them:
///   * the render goes through `videoSegments` (not a `composition`),
///   * `qualityConfig` is a custom resolution *smaller* than the source,
///   * no `transform.scaleX/scaleY` — those suppress the output resolution
///     entirely (see `VideoRenderData.toAsyncMap`).
///
/// Source is `demo.mp4` at 1280x720, so an output of 640x360 caps to exactly
/// half and 320x180 to a quarter. Both keep the source aspect, so the export
/// letterboxes nothing and output pixels map linearly onto composition pixels.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pve = ProVideoEditor.instance;
  final h264Video = EditorVideo.asset(kVideoEditorExampleH264Path);

  /// Renders [layers] over the first two seconds of the source, downscaled to
  /// [output], and decodes the frame at one second at exactly [output] pixels
  /// so a decoded pixel is an output pixel.
  Future<_Frame> renderAndDecode(
    List<ImageLayer> layers, {
    required Size output,
    ExportTransform? transform,
    bool withCropping = false,
  }) async {
    final bytes = await pve.renderVideo(
      VideoRenderData(
        videoSegments: [
          VideoSegment(video: h264Video, endTime: const Duration(seconds: 2)),
        ],
        outputFormat: VideoOutputFormat.mp4,
        qualityConfig: VideoQualityConfig.custom(
          bitrate: 8000000,
          resolution: output,
        ),
        transform: transform,
        imageBytesWithCropping: withCropping,
        imageLayers: layers,
      ),
    );

    final rendered = EditorVideo.memory(bytes);
    final meta = await pve.getMetadata(rendered);
    expect(
      meta.resolution,
      output,
      reason: 'the export did not land on the requested output resolution',
    );

    final frames = await pve.getThumbnails(
      ThumbnailConfigs(
        video: rendered,
        outputFormat: ThumbnailFormat.png,
        timestamps: const [Duration(seconds: 1)],
        outputSize: output,
        boxFit: ThumbnailBoxFit.cover,
      ),
    );
    expect(frames, isNotEmpty, reason: 'no frame extracted from the export');

    final codec = await instantiateImageCodec(frames.first);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    return _Frame(data!, image.width, image.height);
  }

  group('Overlay raster cap', () {
    testWidgets('a stretched overlay still covers the whole frame', (_) async {
      // The layer from the crash report: no offset, no size, so it is laid out
      // across the entire composition and rastered at the capped frame size.
      // Four quadrants rather than one colour, so the frame also reports
      // whether the overlay was scaled about its centre — a scale about any
      // other point slides the pattern and the corners read wrong.
      final overlay = ImageLayer(
        image: EditorLayerImage.memory(await _quadrantImage()),
      );

      final frame = await renderAndDecode([
        overlay,
      ], output: const Size(640, 360));

      expect(_classify(frame.at(0.25, 0.25)), _Hue.red, reason: 'top left');
      expect(_classify(frame.at(0.75, 0.25)), _Hue.green, reason: 'top right');
      expect(_classify(frame.at(0.25, 0.75)), _Hue.blue, reason: 'bottom left');
      expect(
        _classify(frame.at(0.75, 0.75)),
        _Hue.yellow,
        reason: 'bottom right',
      );

      // Right up to the edges: a scale that fell through would leave the
      // overlay at a quarter of the frame and show video in the corners.
      expect(_classify(frame.at(0.01, 0.02)), _Hue.red, reason: 'top-left px');
      expect(
        _classify(frame.at(0.99, 0.98)),
        _Hue.yellow,
        reason: 'bottom-right px',
      );
    });

    testWidgets('a positioned overlay keeps its box', (_) async {
      // 200x100 at (100, 50) in the composition; halved by the export, so the
      // box is x 50..150, y 25..75 of a 640x360 frame. The cap rasters it at
      // 100x50 and hands Media3 2x back on both axes — a scale applied about
      // anything but the overlay centre moves this box.
      final overlay = ImageLayer(
        image: EditorLayerImage.memory(await _solidImage(200, 100)),
        offset: const Offset(100, 50),
        size: const Size(200, 100),
      );

      final frame = await renderAndDecode([
        overlay,
      ], output: const Size(640, 360));
      final box = _boundsOf(frame);

      expect(box, isNotNull, reason: 'the overlay is not in the frame at all');
      _expectBox(box!, left: 50, top: 25, right: 150, bottom: 75);
    });

    testWidgets('a thin overlay is not squashed by the cap', (_) async {
      // The cap rounds each axis to a whole pixel on its own, so the two axes
      // do not land on the same fraction of what they asked for: 7x600 halves
      // to 4x300, which needs 1.75x back across and 2x down. Undoing both with
      // the width's factor renders this 262 output pixels tall instead of 300.
      final overlay = ImageLayer(
        image: EditorLayerImage.memory(await _solidImage(7, 600)),
        offset: const Offset(100, 60),
        size: const Size(7, 600),
      );

      final frame = await renderAndDecode([
        overlay,
      ], output: const Size(640, 360));
      final box = _boundsOf(frame);

      expect(box, isNotNull, reason: 'the overlay is not in the frame at all');
      // Centre stays at composition (103.5, 360) → output (51.75, 180), and the
      // 600-tall layer covers 300 output rows around it. A shared factor would
      // cover 262 of them, so the top and bottom edges land 19 pixels off.
      _expectBox(box!, left: 50, top: 30, right: 53, bottom: 330);
    });

    testWidgets('a rotated overlay stays centred on its anchor', (_) async {
      // A square rotated 45° grows its bounding box by sqrt(2), symmetrically
      // about the centre the layer was anchored at. The corners of that box
      // fall outside the diamond, so they must show video.
      final overlay = ImageLayer(
        image: EditorLayerImage.memory(await _solidImage(200, 200)),
        offset: const Offset(540, 260),
        size: const Size(200, 200),
        rotation: math.pi / 4,
      );

      final frame = await renderAndDecode([
        overlay,
      ], output: const Size(640, 360));
      final box = _boundsOf(frame);

      expect(box, isNotNull, reason: 'the overlay is not in the frame at all');
      // Composition centre (640, 360) → output (320, 180); 200 * sqrt(2) / 2
      // ≈ 141 output pixels across, so 71 either side of that centre.
      _expectBox(
        box!,
        left: 249,
        top: 109,
        right: 391,
        bottom: 251,
        tolerance: 10,
      );
      expect(
        _isSolid(frame.at(0.5, 0.5)),
        isTrue,
        reason: 'the centre of a rotated square is still the square',
      );
      expect(
        _isSolid(frame.at(250 / 640, 110 / 360)),
        isFalse,
        reason: 'the corner of the bounding box is outside the diamond',
      );
    });

    testWidgets('a cropped-along overlay keeps its full resolution', (_) async {
      // withCropping lays the overlay out before the crop, but only the crop
      // rectangle is scaled into the output — 160x90 out of 1280x720, into a
      // 160x90 export, so nothing is downscaled at all and the cap must be 1.
      // Read off the full composition instead it caps to an eighth.
      //
      // Placement survives either way: a smaller raster comes with a larger
      // compensating scale, so the box lands where it should and only its
      // resolution differs. What cannot survive an eighth is 4-pixel stripes,
      // so this asserts the detail rather than the geometry the other tests
      // already cover. The reduction is deliberately far past the pattern's
      // own pitch: a factor that lands on it can round-trip a stripe exactly.
      final overlay = ImageLayer(
        image: EditorLayerImage.memory(await _stripedImage(120, 60)),
        offset: const Offset(580, 330),
        size: const Size(120, 60),
      );

      final frame = await renderAndDecode(
        [overlay],
        output: const Size(160, 90),
        withCropping: true,
        transform: const ExportTransform(
          width: 160,
          height: 90,
          x: 560,
          y: 315,
        ),
      );

      // The overlay covers x 20..140, y 15..75 of the crop; sample inside.
      expect(
        _rowContrast(frame, 45, 30, 130),
        greaterThan(120),
        reason:
            'the stripes were averaged away by a raster cap that should '
            'not have applied here',
      );
    });

    testWidgets('many layers render at a downscaled output', (_) async {
      // The shape of the reported crash: one layer per drawing stroke, every
      // one of them full-frame. Reproducing the OutOfMemoryError itself needs a
      // 4K source — the bundled assets top out at 720p, where the per-layer
      // buffers are far too small to reach the growth limit. What this does
      // cover is that the capped path survives the layer count and still
      // composites, which is where a per-layer arithmetic slip would show.
      final image = EditorLayerImage.memory(await _quadrantImage());
      final layers = List.generate(40, (_) => ImageLayer(image: image));

      final frame = await renderAndDecode(layers, output: const Size(640, 360));

      expect(_classify(frame.at(0.25, 0.25)), _Hue.red);
      expect(_classify(frame.at(0.75, 0.75)), _Hue.yellow);
    });
  });
}

// ---------------------------------------------------------------------------
// Overlay images.
// ---------------------------------------------------------------------------

/// An opaque magenta rectangle — a hue the source footage does not carry, so
/// [_isSolid] can tell overlay from video without knowing the content.
Future<Uint8List> _solidImage(int width, int height) =>
    _encode(width, height, (canvas) {
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFF00FF),
      );
    });

/// Four saturated quadrants: red, green, blue, yellow clockwise from top left.
/// Stretched over the frame they report coverage and placement at once.
Future<Uint8List> _quadrantImage({int size = 200}) =>
    _encode(size, size, (canvas) {
      final half = size / 2;
      void quad(double x, double y, int color) => canvas.drawRect(
        ui.Rect.fromLTWH(x, y, half, half),
        ui.Paint()..color = ui.Color(color),
      );
      quad(0, 0, 0xFFFF0000);
      quad(half, 0, 0xFF00FF00);
      quad(0, half, 0xFF0000FF);
      quad(half, half, 0xFFFFFF00);
    });

/// Opaque black with vertical white stripes [stripe] pixels wide.
///
/// A pattern rather than a colour: it survives a 1:1 export and is averaged to
/// flat grey by a raster cap, so [_rowContrast] reads off whether one hit.
Future<Uint8List> _stripedImage(int width, int height, {int stripe = 4}) =>
    _encode(width, height, (canvas) {
      final w = width.toDouble(), h = height.toDouble();
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, w, h),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
      final white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
      for (var x = 0; x < width; x += stripe * 2) {
        canvas.drawRect(
          ui.Rect.fromLTWH(x.toDouble(), 0, stripe.toDouble(), h),
          white,
        );
      }
    });

Future<Uint8List> _encode(
  int width,
  int height,
  void Function(ui.Canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  draw(ui.Canvas(recorder));
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Frame + pixel helpers.
// ---------------------------------------------------------------------------

/// A decoded RGBA frame with pixel sampling helpers.
class _Frame {
  _Frame(this.data, this.width, this.height);

  final ByteData data;
  final int width;
  final int height;

  /// RGBA at the absolute pixel ([x], [y]).
  List<int> pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return [
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ];
  }

  /// RGBA at the relative position ([fx], [fy]) in `0..1`.
  List<int> at(double fx, double fy) => pixel(
    (fx * (width - 1)).round().clamp(0, width - 1),
    (fy * (height - 1)).round().clamp(0, height - 1),
  );
}

/// Whether a pixel is the magenta [_solidImage] draws.
///
/// Wide enough to survive the round-trip through subsampled YUV, which bleeds a
/// hue across an edge without moving it, but tight enough that only a saturated
/// magenta passes — the footage carries pinkish pixels of its own.
bool _isSolid(List<int> c) => c[0] > 170 && c[2] > 170 && c[1] < 95;

/// Rec.601 luminance of a pixel.
double _luma(List<int> c) => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];

/// Largest luminance swing along row [y] between [left] and [right].
///
/// Full contrast means the stripes came through; a flat row means they were
/// resampled below their own pitch and averaged out.
int _rowContrast(_Frame f, int y, int left, int right) {
  var lo = 255.0, hi = 0.0;
  for (var x = left; x <= right; x++) {
    final l = _luma(f.pixel(x, y));
    if (l < lo) lo = l;
    if (l > hi) hi = l;
  }
  return (hi - lo).round();
}

enum _Hue { red, green, blue, yellow, other }

/// Which quadrant colour a pixel carries, or [_Hue.other] for video.
_Hue _classify(List<int> c) {
  final r = c[0], g = c[1], b = c[2];
  if (r > 120 && g < 100 && b < 100) return _Hue.red;
  if (g > 110 && r < 120 && b < 120) return _Hue.green;
  if (b > 120 && r < 100 && g < 110) return _Hue.blue;
  if (r > 120 && g > 110 && b < 100) return _Hue.yellow;
  return _Hue.other;
}

/// Bounding box of the overlay in [frame], or null if it holds none.
///
/// A box rather than sample points: it reports where the overlay is *and* how
/// large, so a mispositioned overlay and a mis-scaled one fail differently.
///
/// A pixel counts only when its four neighbours match as well. The footage
/// carries scattered single pixels that pass [_isSolid] on their own, and
/// against a raw mask one of them at the frame edge decides the whole box.
/// Eroding keeps the solid block the overlay is; the box is grown back by the
/// one pixel the erosion costs it.
_Box? _boundsOf(_Frame frame) {
  bool core(int x, int y) =>
      x > 0 &&
      y > 0 &&
      x < frame.width - 1 &&
      y < frame.height - 1 &&
      _isSolid(frame.pixel(x, y)) &&
      _isSolid(frame.pixel(x - 1, y)) &&
      _isSolid(frame.pixel(x + 1, y)) &&
      _isSolid(frame.pixel(x, y - 1)) &&
      _isSolid(frame.pixel(x, y + 1));

  var left = frame.width, top = frame.height, right = -1, bottom = -1;
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      if (!core(x, y)) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  return right < 0 ? null : _Box(left - 1, top - 1, right + 1, bottom + 1);
}

class _Box {
  _Box(this.left, this.top, this.right, this.bottom);

  final int left, top, right, bottom;

  @override
  String toString() =>
      'l=$left t=$top r=$right b=$bottom '
      '(${right - left + 1}x${bottom - top + 1})';
}

void _expectBox(
  _Box box, {
  required int left,
  required int top,
  required int right,
  required int bottom,
  int tolerance = 6,
}) {
  expect(box.left, closeTo(left, tolerance), reason: 'left edge — box is $box');
  expect(box.top, closeTo(top, tolerance), reason: 'top edge — box is $box');
  expect(
    box.right,
    closeTo(right, tolerance),
    reason: 'right edge — box is $box',
  );
  expect(
    box.bottom,
    closeTo(bottom, tolerance),
    reason: 'bottom edge — box is $box',
  );
}
