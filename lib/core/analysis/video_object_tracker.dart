import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../models/video/editor_video_model.dart';
import '../models/video/video_object_track_model.dart';
import 'corner_detector.dart';
import 'lucas_kanade_tracker.dart';
import 'luma_pyramid.dart';
import 'object_tracking_worker_web.dart'
    if (dart.library.io) 'object_tracking_worker_native.dart';

/// Follows an object through a sequence of frames.
///
/// Mark the object with a [region] on the first frame added, then add the
/// frames that follow it, in order. The tracking is classical motion
/// estimation and runs entirely in Dart, without an ML model: corners inside
/// the region are tracked into the next frame, checked by tracking them back
/// and by comparing their surroundings, and the median of what the reliable
/// ones did moves, scales and turns the region (the "median flow" tracker).
/// It is CPU-bound, so run it in a background isolate; [trackVideo] does.
///
/// The frames can run backward in time just as well, which follows the
/// object from the marked frame towards the start of a video.
///
/// The frames must be upright (as displayed), all the same size, and shaped
/// like the video, since the results are fractions of the frame size.
class VideoObjectTracker {
  /// Creates a tracker for frames of [width] × [height] pixels that follows
  /// [region], given as fractions of the frame (`Rect.fromLTRB(0, 0, 1, 1)`
  /// is the whole frame).
  VideoObjectTracker({
    required this.width,
    required this.height,
    required this.region,
    this.maxSkippedFrames = 5,
    this.pyramidLevels = 4,
  }) : assert(
         region.width > 0 && region.height > 0,
         '[region] must not be empty',
       ),
       assert(maxSkippedFrames >= 0, '[maxSkippedFrames] must not be negative');

  /// Follows [region] through [video], forward from [anchorTime] to
  /// [endTime] and backward from it to [startTime].
  ///
  /// [region] marks the object, as fractions of the upright frame, on the
  /// first frame at or after [anchorTime] (the source time). [startTime] and
  /// [endTime] limit the range as in a `VideoSegment`; the start and the end
  /// of the video when null. Tracking stops early in a direction once the
  /// object is lost, e.g. because it left the frame.
  ///
  /// [frameSize] bounds the analyzed frames; around 480 pixels on the long
  /// side follows small objects well. [smoothing] is the standard deviation
  /// of the Gaussian that steadies the path (see
  /// [VideoObjectTrack.smoothed]); [Duration.zero] keeps the raw path.
  /// [onProgress] reports the share of the range done so far.
  ///
  /// Cancel with [cancel] and the same [id]; the future then fails with a
  /// `RenderCanceledException`.
  ///
  /// Throws a `PlatformException` when the video cannot be decoded and an
  /// [UnsupportedError] on the web.
  static Future<VideoObjectTrack> trackVideo(
    EditorVideo video, {
    required Rect region,
    required Duration anchorTime,
    Duration? startTime,
    Duration? endTime,
    Size frameSize = const Size(480, 480),
    Duration smoothing = const Duration(milliseconds: 50),
    double? maxFrameRate,
    int? maxParallelDecoders,
    String? id,
    void Function(double progress)? onProgress,
  }) => trackVideoInBackground(
    video: video,
    region: region,
    anchorTime: anchorTime,
    startTime: startTime,
    endTime: endTime,
    frameSize: frameSize,
    smoothing: smoothing,
    maxFrameRate: maxFrameRate,
    maxParallelDecoders: maxParallelDecoders,
    id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    onProgress: onProgress,
  );

  /// Cancels the [trackVideo] call started with [id], including the frame
  /// decoding it runs. The call then fails with a `RenderCanceledException`.
  /// Does nothing when no such call runs.
  static Future<void> cancel(String id) => cancelTrackVideo(id);

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// The object on the first frame, as fractions of the frame.
  final Rect region;

  /// How many frames in a row may fail to show the object before it counts
  /// as lost. A frame that fails is skipped and the next one is compared
  /// with the last frame the object was found in, so a blurred frame or a
  /// hand passing in front does not end the track.
  final int maxSkippedFrames;

  /// Pyramid depth. Each level doubles the motion between two frames the
  /// tracker can follow.
  final int pyramidLevels;

  /// Fewest reliable points a step may rest on.
  static const int _minPoints = 4;

  /// A point whose backward track misses its start by more pixels than this
  /// is never trusted.
  static const double _maxForwardBackwardError = 3;

  /// Points in a region that has fewer corners than this are topped up with
  /// a grid, whose flat points the point tracker rejects on its own.
  static const int _minCorners = 12;

  /// The most a region may grow or shrink between two frames; more is a
  /// wrong estimate rather than motion.
  static const double _maxScaleStep = 1.25;

  /// Half the size of the patches compared around a point, in pixels.
  static const int _patchRadius = 3;

  final LucasKanadeTracker _tracker = LucasKanadeTracker(radius: 7);

  /// The last frame the object was found in.
  LumaPyramid? _reference;

  /// The region in [_reference], in pixels, centered on ([_cx], [_cy]),
  /// [_w] × [_h] before it is turned by [_angle].
  double _cx = 0;
  double _cy = 0;
  double _w = 0;
  double _h = 0;
  double _angle = 0;
  double _w0 = 1;

  /// How far the object moved per frame in the last step, as a guess for
  /// the next one.
  double _vx = 0;
  double _vy = 0;

  int _skipped = 0;
  bool _lost = false;

  /// Whether the object is lost: it left the frame, or could not be found
  /// for more than [maxSkippedFrames] frames in a row. Frames added after
  /// that are ignored.
  bool get isLost => _lost;

  /// Adds the next frame and returns where the object is in it, or null when
  /// it could not be found there.
  ///
  /// The first frame added is the one [region] marks the object on. [luma] is
  /// row-major, one byte per pixel; [time] is the frame's source timestamp.
  ObjectTrackSample? addFrame(Uint8List luma, Duration time) {
    if (luma.length < width * height) {
      throw ArgumentError.value(
        luma.length,
        'luma',
        'expected $width x $height = ${width * height} bytes',
      );
    }
    if (_lost) return null;
    final pyramid = LumaPyramid.fromLuma(
      luma,
      width,
      height,
      levelCount: pyramidLevels,
    );
    final reference = _reference;
    if (reference == null) {
      _reference = pyramid;
      _cx = region.center.dx * width;
      _cy = region.center.dy * height;
      _w = region.width * width;
      _h = region.height * height;
      _w0 = _w;
      return _sample(time);
    }

    final step = _step(reference, pyramid, _skipped + 1);
    if (step == null) {
      if (++_skipped > maxSkippedFrames) _lost = true;
      return null;
    }
    final gap = _skipped + 1;
    _vx = (step.cx - _cx) / gap;
    _vy = (step.cy - _cy) / gap;
    _cx = step.cx;
    _cy = step.cy;
    _w *= step.scale;
    _h *= step.scale;
    _angle += step.rotation;
    _skipped = 0;
    _reference = pyramid;
    if (_cx < 0 || _cy < 0 || _cx > width || _cy > height) {
      // Its middle left the frame: what is left in view is not the object.
      _lost = true;
      return null;
    }
    return _sample(time);
  }

  ObjectTrackSample _sample(Duration time) => ObjectTrackSample(
    time: time,
    center: Offset(_cx / width, _cy / height),
    size: Size(_w / width, _h / height),
    scale: _w / _w0,
    rotation: _angle,
  );

  /// Where the region in [reference] went in [next], [gap] frames later, or
  /// null when the frames gave no reliable answer.
  _Step? _step(LumaPyramid reference, LumaPyramid next, int gap) {
    final base = reference.levels.first;
    final points = _pointsInRegion(base);
    final count = points.length >> 1;
    if (count < _minPoints) return null;

    final guess = Float32List(points.length);
    for (var i = 0; i < points.length; i += 2) {
      guess[i] = points[i] + _vx * gap;
      guess[i + 1] = points[i + 1] + _vy * gap;
    }
    final forward = Float32List(points.length);
    final forwardOk = _tracker.track(
      reference,
      next,
      points,
      forward,
      guess: guess,
    );
    final back = Float32List(points.length);
    final backOk = _tracker.track(
      next,
      reference,
      forward,
      back,
      guess: points,
    );

    final kept = <int>[];
    final errors = <double>[];
    final similarity = <double>[];
    final nextBase = next.levels.first;
    for (var i = 0; i < count; i++) {
      if (forwardOk[i] == 0 || backOk[i] == 0) continue;
      final ex = back[2 * i] - points[2 * i];
      final ey = back[2 * i + 1] - points[2 * i + 1];
      final error = math.sqrt(ex * ex + ey * ey);
      if (error > _maxForwardBackwardError) continue;
      kept.add(i);
      errors.add(error);
      similarity.add(
        _patchCorrelation(
          base,
          points[2 * i],
          points[2 * i + 1],
          nextBase,
          forward[2 * i],
          forward[2 * i + 1],
        ),
      );
    }
    if (kept.length < _minPoints) return null;

    // Median flow: keep the half that tracked back best, then the half of
    // those whose surroundings stayed most alike; points on the background
    // or on something passing in front of the object drop out here.
    final byError = [for (var k = 0; k < kept.length; k++) k]
      ..sort((p, q) => errors[p].compareTo(errors[q]));
    final bestTracked = byError.sublist(0, _half(byError.length))
      ..sort((p, q) => similarity[q].compareTo(similarity[p]));
    final reliable = [
      for (final k in bestTracked.sublist(0, _half(bestTracked.length)))
        kept[k],
    ];

    final ratios = <double>[];
    final turns = <double>[];
    for (var a = 0; a < reliable.length; a++) {
      final i = reliable[a];
      for (var b = a + 1; b < reliable.length; b++) {
        final j = reliable[b];
        final dx = points[2 * j] - points[2 * i];
        final dy = points[2 * j + 1] - points[2 * i + 1];
        final before = dx * dx + dy * dy;
        // Points closer than 3 px give unstable ratios and angles.
        if (before < 9) continue;
        final ux = forward[2 * j] - forward[2 * i];
        final uy = forward[2 * j + 1] - forward[2 * i + 1];
        ratios.add(math.sqrt((ux * ux + uy * uy) / before));
        var turn = math.atan2(uy, ux) - math.atan2(dy, dx);
        if (turn > math.pi) turn -= 2 * math.pi;
        if (turn < -math.pi) turn += 2 * math.pi;
        turns.add(turn);
      }
    }
    final scale = ratios.isEmpty ? 1.0 : _median(ratios);
    final rotation = turns.isEmpty ? 0.0 : _median(turns);
    final maxStep = math.pow(_maxScaleStep, gap);
    if (scale > maxStep || scale < 1 / maxStep) return null;

    // Each point predicts where the middle went once the region is scaled
    // and turned like the points around it; the median of those predictions
    // does not depend on the points sitting evenly around the middle.
    final cos = math.cos(rotation) * scale;
    final sin = math.sin(rotation) * scale;
    final centersX = <double>[];
    final centersY = <double>[];
    for (final i in reliable) {
      final rx = points[2 * i] - _cx;
      final ry = points[2 * i + 1] - _cy;
      centersX.add(forward[2 * i] - (cos * rx - sin * ry));
      centersY.add(forward[2 * i + 1] - (sin * rx + cos * ry));
    }
    return _Step(
      cx: _median(centersX),
      cy: _median(centersY),
      scale: scale,
      rotation: rotation,
    );
  }

  /// Points to track inside the region in [level]: its corners, topped up
  /// with a grid when it has few.
  ///
  /// Each point is tracked by the window around it, so points are kept a
  /// window's reach inside the region's edge, and at least a tenth of its
  /// size, where a loosely drawn region shows the background. A window that
  /// reached across the object's outline would follow the background in
  /// part, and pull every measured motion towards standing still.
  Float32List _pointsInRegion(LumaPyramidLevel level) {
    double inner(double half) {
      final inset = math.max(half * 0.1, _tracker.radius + 1.0);
      return math.max(half * 0.3, half - inset);
    }

    final halfW = inner(_w / 2);
    final halfH = inner(_h / 2);
    final left = _cx - halfW;
    final top = _cy - halfH;
    final right = _cx + halfW;
    final bottom = _cy + halfH;
    final corners = detectCornersInRect(
      level,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
    if (corners.length >> 1 >= _minCorners) return corners;

    const columns = 6;
    const rows = 6;
    final margin = _tracker.radius + 1;
    final grid = <double>[...corners];
    for (var row = 0; row < rows; row++) {
      final y = top + (row + 0.5) * (bottom - top) / rows;
      if (y < margin || y > level.height - 1 - margin) continue;
      for (var column = 0; column < columns; column++) {
        final x = left + (column + 0.5) * (right - left) / columns;
        if (x < margin || x > level.width - 1 - margin) continue;
        grid
          ..add(x)
          ..add(y);
      }
    }
    return Float32List.fromList(grid);
  }

  /// Normalized cross-correlation of the patches around (ax, ay) in [a] and
  /// around (bx, by) in [b], from -1 to 1.
  static double _patchCorrelation(
    LumaPyramidLevel a,
    double ax,
    double ay,
    LumaPyramidLevel b,
    double bx,
    double by,
  ) {
    const r = _patchRadius;
    const n = (2 * r + 1) * (2 * r + 1);
    var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        final va = _bilinear(a, ax + dx, ay + dy);
        final vb = _bilinear(b, bx + dx, by + dy);
        sa += va;
        sb += vb;
        saa += va * va;
        sbb += vb * vb;
        sab += va * vb;
      }
    }
    final cov = sab - sa * sb / n;
    final varA = saa - sa * sa / n;
    final varB = sbb - sb * sb / n;
    final denominator = math.sqrt(varA * varB);
    return denominator < 1e-6 ? 0 : cov / denominator;
  }

  static double _bilinear(LumaPyramidLevel level, double x, double y) {
    final w = level.width;
    final h = level.height;
    final cx = x.clamp(0.0, w - 1.0);
    final cy = y.clamp(0.0, h - 1.0);
    final x0 = cx.floor();
    final y0 = cy.floor();
    final x1 = x0 + 1 < w ? x0 + 1 : x0;
    final y1 = y0 + 1 < h ? y0 + 1 : y0;
    final fx = cx - x0;
    final fy = cy - y0;
    final p = level.pixels;
    return (1 - fx) * (1 - fy) * p[y0 * w + x0] +
        fx * (1 - fy) * p[y0 * w + x1] +
        (1 - fx) * fy * p[y1 * w + x0] +
        fx * fy * p[y1 * w + x1];
  }

  /// The better half of [count] points, but never fewer than the fewest a
  /// step rests on while there are that many.
  static int _half(int count) =>
      math.min(count, math.max(_minPoints, (count + 1) >> 1));

  static double _median(List<double> values) {
    values.sort();
    final mid = values.length >> 1;
    return values.length.isOdd
        ? values[mid]
        : (values[mid - 1] + values[mid]) / 2;
  }
}

/// Where the region went in one step of [VideoObjectTracker].
class _Step {
  const _Step({
    required this.cx,
    required this.cy,
    required this.scale,
    required this.rotation,
  });

  final double cx;
  final double cy;
  final double scale;
  final double rotation;
}
