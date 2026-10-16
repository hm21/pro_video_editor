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
import 'similarity_estimator.dart';
import 'similarity_transform.dart';

/// Follows an object through a sequence of frames.
///
/// Mark the object with a [region] on the first frame added, then add the
/// frames that follow it, in order. The tracking is classical motion
/// estimation and runs entirely in Dart, without an ML model:
///
/// - Corners inside the region are tracked from frame to frame, checked by
///   tracking them back and by comparing their surroundings. Each one keeps
///   where it sat in the region when it was found, and so tells where the
///   region is now, how large it is and how far it turned; a robust fit to
///   all of them places the region. A point's errors do not add up from
///   frame to frame, so the region does not drift off the object.
/// - The motion of the scene around the region (the camera) is measured too.
///   Only points that move against the scene count as the object, so a
///   region drawn loosely around it, with background inside, still follows
///   the object rather than the background. While nothing in the region
///   moves against the scene, the object moves with it, and so does the
///   region.
///
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
  /// first frame at or after [anchorTime] (the source time), or on the last
  /// frame when none follows it. [startTime] and [endTime] limit the range as
  /// in a `VideoSegment`; the start and the end of the video when null. An
  /// [anchorTime] outside the range counts as the range's nearest end.
  /// Tracking stops early in a direction once the object is lost, e.g.
  /// because it left the frame.
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

  /// Fewest points a step may rest on.
  static const int _minPoints = 4;

  /// How many points must have moved against the scene before they count
  /// as the object: with only [_minPoints], dropping one would leave too few
  /// to follow it by, and the object would be lost.
  static const int _minObjectPoints = 2 * _minPoints;

  /// Most points followed inside the region at once.
  static const int _maxPoints = 80;

  /// New points are found once fewer than this are left: of the object's
  /// own, once it is known.
  static const int _refillBelow = 40;

  /// Closest two points inside the region may sit, in pixels.
  static const double _minSpacing = 4;

  /// Points in a region with fewer corners than this are topped up with a
  /// grid, whose flat points the point tracker rejects on its own.
  static const int _minCorners = 12;

  /// A point whose backward track misses its start by more pixels than this
  /// is dropped.
  static const double _maxForwardBackwardError = 1.5;

  /// A point whose surroundings changed more than this between two frames
  /// (normalized cross-correlation) is dropped: something passed in front of
  /// it, or it slid off an edge.
  static const double _minCorrelation = 0.6;

  /// How far, in pixels, a point must have moved against the scene since it
  /// was found to count as part of the object, at least.
  static const double _objectMotion = 2;

  /// The most a region may grow or shrink between two frames; more is a
  /// wrong estimate rather than motion.
  static const double _maxScaleStep = 1.25;

  /// How far, in pixels, a point may land from where the region's motion
  /// puts it and still count as moving with it.
  static const double _maxDeviation = 0.75;

  /// How closely, in pixels, points must agree on a motion to back it: tight,
  /// since points on an object's outline move nearly with it.
  static const double _fitTolerance = 0.4;

  /// How closely, in pixels, the points of the object must agree on where
  /// the region is now. Looser than [_fitTolerance], since each point also
  /// carries the error of the region's place when it was found.
  static const double _placeTolerance = 0.75;

  /// How far, in pixels, a point of the object may fall behind or run ahead
  /// of the region over its life. A point whose window sees part of the
  /// background moves only part of the way, a little each frame; this is
  /// what tells it from the object.
  static const double _maxDrift = 3;

  /// Half the size of the patches compared around a point, in pixels.
  static const int _patchRadius = 3;

  final LucasKanadeTracker _tracker = LucasKanadeTracker(radius: 4);
  final LucasKanadeTracker _sceneTracker = LucasKanadeTracker();

  /// The last frame the object was found in.
  LumaPyramid? _reference;

  /// The region in [_reference]: centered on ([_cx], [_cy]), [_scale] times
  /// its size on the marked frame, turned by [_angle] since then.
  double _cx = 0;
  double _cy = 0;
  double _scale = 1;
  double _angle = 0;

  /// The region's size on the marked frame, in pixels.
  double _w0 = 0;
  double _h0 = 0;

  /// How far the region moved per frame in the last step, as a guess for
  /// the next one.
  double _vx = 0;
  double _vy = 0;

  /// The points followed inside the region, at their place in [_reference].
  final List<_Point> _points = [];

  /// The scene's motion in the last step, as a guess for the next one.
  SimilarityTransform? _lastScene;

  /// How far, in pixels, points of the scene stray from its fitted motion
  /// from frame to frame: the tracking noise.
  double _sceneNoise = 0.3;

  /// Whether points have moved against the scene: from then on the region
  /// rests on them, and losing them all loses the object.
  bool _foundObject = false;

  int _skipped = 0;
  bool _lost = false;

  /// Whether the object is lost: it left the frame, or could not be found
  /// for more than [maxSkippedFrames] frames in a row. Frames added after
  /// that are ignored.
  bool get isLost => _lost;

  /// How many of the frames added last, in a row, the object was not found
  /// in. While this is above 0 it may still turn up again, unless [isLost].
  int get missedFrames => _skipped;

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
      _w0 = region.width * width;
      _h0 = region.height * height;
      _addPoints(pyramid.levels.first);
      return _sample(time);
    }

    if (!_step(reference, pyramid, _skipped + 1)) {
      if (++_skipped > maxSkippedFrames) _lost = true;
      return null;
    }
    _skipped = 0;
    _reference = pyramid;
    if (_cx < 0 || _cy < 0 || _cx > width || _cy > height) {
      // Its middle left the frame: what is left in view is not the object.
      _lost = true;
      return null;
    }
    _addPoints(pyramid.levels.first);
    return _sample(time);
  }

  ObjectTrackSample _sample(Duration time) => ObjectTrackSample(
    time: time,
    center: Offset(_cx / width, _cy / height),
    size: Size(_w0 * _scale / width, _h0 * _scale / height),
    scale: _scale,
    rotation: _angle,
  );

  /// Moves the region from [reference] to [next], [gap] frames later.
  /// Returns false, leaving everything as it was, when the frames gave no
  /// reliable answer.
  bool _step(LumaPyramid reference, LumaPyramid next, int gap) {
    final count = _points.length;
    if (count < _minPoints) return false;
    final from = Float32List(2 * count);
    final guess = Float32List(2 * count);
    for (var i = 0; i < count; i++) {
      from[2 * i] = _points[i].x;
      from[2 * i + 1] = _points[i].y;
      guess[2 * i] = _points[i].x + _vx * gap;
      guess[2 * i + 1] = _points[i].y + _vy * gap;
    }
    final to = Float32List(2 * count);
    final forwardOk = _tracker.track(reference, next, from, to, guess: guess);
    final back = Float32List(2 * count);
    final backOk = _tracker.track(next, reference, to, back, guess: from);
    final base = reference.levels.first;
    final nextBase = next.levels.first;
    final alive = <int>[];
    for (var i = 0; i < count; i++) {
      if (forwardOk[i] == 0 || backOk[i] == 0) continue;
      final ex = back[2 * i] - from[2 * i];
      final ey = back[2 * i + 1] - from[2 * i + 1];
      if (ex * ex + ey * ey >
          _maxForwardBackwardError * _maxForwardBackwardError) {
        continue;
      }
      final correlation = _patchCorrelation(
        base,
        from[2 * i],
        from[2 * i + 1],
        nextBase,
        to[2 * i],
        to[2 * i + 1],
      );
      if (correlation < _minCorrelation) continue;
      alive.add(i);
    }
    if (alive.length < _minPoints) return false;

    // Which points move against the scene: those are the object. Worked out
    // aside and only kept once the step succeeds, so a frame that fails
    // leaves the points as they were and the next one is measured once.
    final scene = _sceneMotion(reference, next);
    final cx0 = (width - 1) / 2;
    final cy0 = (height - 1) / 2;
    final relX = Float64List(count);
    final relY = Float64List(count);
    final age = Int32List(count);
    final onObject = [for (final point in _points) point.onObject];
    final moved = [for (final point in _points) point.movedAgainstScene];
    for (final i in alive) {
      final point = _points[i];
      relX[i] = point.relX;
      relY[i] = point.relY;
      age[i] = point.age;
      if (scene == null) continue;
      final x = from[2 * i] - cx0;
      final y = from[2 * i + 1] - cy0;
      relX[i] += to[2 * i] - cx0 - scene.mapX(x, y);
      relY[i] += to[2 * i + 1] - cy0 - scene.mapY(x, y);
      age[i] += gap;
      // The noise of every step adds up like a random walk.
      final limit = math.max(
        _objectMotion,
        3 * _sceneNoise * math.sqrt(age[i]),
      );
      if (!point.onObject &&
          relX[i] * relX[i] + relY[i] * relY[i] > limit * limit) {
        // Once the object is known, a point joins it only when it moved
        // with it since it was found; one on its outline lags behind.
        moved[i] = true;
        onObject[i] =
            !_foundObject ||
            _followsRegion(point, to[2 * i], to[2 * i + 1], gap);
      }
    }
    var object = [
      for (final i in alive)
        if (onObject[i]) i,
    ];
    var takeover = false;
    if (object.length < _minPoints && _foundObject) {
      // The points the object was found on are gone. In a loosely drawn
      // region those can be a part that moved first, like an arm swinging
      // off a body that then turns; the points that moved against the scene
      // since are the object now. With none left, it left the region, or
      // something covers it.
      final movers = [
        for (final i in alive)
          if (moved[i]) i,
      ];
      if (movers.length < _minPoints) return false;
      for (final i in movers) {
        onObject[i] = true;
      }
      object = movers;
      takeover = true;
    }
    // Once enough points moved against the scene and agree on how, they
    // alone are the object; a few that moved in different ways (an arm
    // swinging, a leg) are not yet. Until then the region moves the way most
    // of what is inside it does: the object when it fills the region, the
    // scene when it does not, which is then where the object is too as long
    // as nothing moves against it.
    var motion =
        _foundObject || (scene != null && object.length >= _minObjectPoints)
        ? _objectStep(object, from, to, gap, fresh: takeover)
        : null;
    if (motion == null && _foundObject) return false;
    if (!_foundObject &&
        motion != null &&
        object.length - motion.deviating.length < _minObjectPoints) {
      motion = null;
    }
    final byObject = motion != null;
    final transform =
        motion?.transform ?? _regionMotion(alive, from, to, gap)?.$1;
    if (transform == null) return false;
    var cx = _cx + transform.tx;
    var cy = _cy + transform.ty;
    var scale = _scale * transform.scale;
    var angle = _angle + transform.angle;
    // A point of the object that does not move with the rest is not on it
    // (any more): it sits on its outline, where its window sees the
    // background too, or something passed in front of it. Unless dropping
    // them leaves too few to follow the object by.
    final deviating = motion?.deviating ?? const <int>{};
    final dropped = object.length - deviating.length >= _minPoints
        ? deviating
        : const <int>{};
    if (byObject) {
      // The step's motion only tells how the region moved since the last
      // frame, and its small errors would add up. Where the points sat when
      // they were found tells where the region is now.
      final placed = _placeRegion([
        for (final i in object)
          if (!dropped.contains(i)) i,
      ], to);
      final maxStep = math.pow(_maxScaleStep, gap);
      if (placed != null &&
          placed.scale <= maxStep &&
          placed.scale >= 1 / maxStep) {
        cx = _cx + placed.tx;
        cy = _cy + placed.ty;
        scale = _scale * placed.scale;
        angle = _angle + placed.angle;
      }
    }

    final survivors = <_Point>[];
    final halfW = 0.5 * _w0 * scale;
    final halfH = 0.5 * _h0 * scale;
    for (final i in alive) {
      if (dropped.contains(i)) continue;
      final x = to[2 * i];
      final y = to[2 * i + 1];
      // Background the region moved away from frees its place for new
      // points on the object.
      if (!onObject[i] && ((x - cx).abs() > halfW || (y - cy).abs() > halfH)) {
        continue;
      }
      final point = _points[i]
        ..x = x
        ..y = y
        ..relX = relX[i]
        ..relY = relY[i]
        ..age = age[i]
        ..movedAgainstScene = moved[i]
        ..onObject = onObject[i];
      if (motion != null && onObject[i]) {
        point
          ..driftX = motion.drift[2 * i]
          ..driftY = motion.drift[2 * i + 1];
      }
      survivors.add(point);
    }
    if (byObject) _foundObject = true;
    _points
      ..clear()
      ..addAll(survivors);
    _vx = (cx - _cx) / gap;
    _vy = (cy - _cy) / gap;
    _cx = cx;
    _cy = cy;
    _scale = scale;
    _angle = angle;
    return true;
  }

  /// Whether [point], now at ([x], [y]), [gap] frames after the last one,
  /// moved the way the region did since the point was found, give or take
  /// [_maxDrift].
  ///
  /// The region's step to this frame is not known yet, so the last one
  /// stands in for it.
  bool _followsRegion(_Point point, double x, double y, int gap) {
    final scale = _scale / point.bornScale;
    final turn = _angle - point.bornAngle;
    final cos = math.cos(turn) * scale;
    final sin = math.sin(turn) * scale;
    final rx = point.bornX - point.bornCx;
    final ry = point.bornY - point.bornCy;
    // Where the region's motion since then puts it, a step further on.
    final dx = x - (_cx + cos * rx - sin * ry + _vx * gap);
    final dy = y - (_cy + sin * rx + cos * ry + _vy * gap);
    return dx * dx + dy * dy <= _maxDrift * _maxDrift;
  }

  /// Where the points [indices], now at [to], place the region: the
  /// similarity that maps where each sat in the region when it was found
  /// onto where it is now, relative to the region in the last frame (in
  /// pixels centered on it), or null when too few agree.
  ///
  /// Unlike [_regionMotion], it does not add up the motion of every step,
  /// so the errors of the steps do not add up either.
  SimilarityTransform? _placeRegion(List<int> indices, Float32List to) {
    final count = indices.length;
    if (count < _minPoints) return null;
    final src = Float32List(2 * count);
    final dst = Float32List(2 * count);
    for (var k = 0; k < count; k++) {
      final i = indices[k];
      final point = _points[i];
      // Where the point sat in the region, turned and sized as the region
      // was in the last frame.
      final scale = _scale / point.bornScale;
      final turn = _angle - point.bornAngle;
      final cos = math.cos(turn) * scale;
      final sin = math.sin(turn) * scale;
      final rx = point.bornX - point.bornCx;
      final ry = point.bornY - point.bornCy;
      src[2 * k] = cos * rx - sin * ry;
      src[2 * k + 1] = sin * rx + cos * ry;
      dst[2 * k] = to[2 * i] - _cx;
      dst[2 * k + 1] = to[2 * i + 1] - _cy;
    }
    return fitSimilarityRansac(
      src,
      dst,
      count,
      threshold: _placeTolerance,
      minInliers: _minPoints,
    )?.transform;
  }

  /// How the object's points [object] move from [from] to [to] across [gap]
  /// frames (see [_regionMotion]), which of them do not follow that motion,
  /// and how far each strayed from the region's motion since it joined the
  /// object (`drift`: x and y by point index), or null as [_regionMotion].
  ///
  /// [fresh] points just took over as the object: what they strayed before
  /// counts for nothing.
  ({SimilarityTransform transform, Set<int> deviating, Float64List drift})?
  _objectStep(
    List<int> object,
    Float32List from,
    Float32List to,
    int gap, {
    bool fresh = false,
  }) {
    final motion = _regionMotion(object, from, to, gap);
    if (motion == null) return null;
    final (transform, errors) = motion;
    final drift = Float64List(2 * _points.length);
    final deviating = <int>{};
    for (var k = 0; k < object.length; k++) {
      final i = object[k];
      final ex = errors[2 * k];
      final ey = errors[2 * k + 1];
      final driftX = drift[2 * i] = (fresh ? 0 : _points[i].driftX) + ex;
      final driftY = drift[2 * i + 1] = (fresh ? 0 : _points[i].driftY) + ey;
      if (ex * ex + ey * ey > _maxDeviation * _maxDeviation ||
          driftX * driftX + driftY * driftY > _maxDrift * _maxDrift) {
        deviating.add(i);
      }
    }
    return (transform: transform, deviating: deviating, drift: drift);
  }

  /// How the region moves with the points [candidates], from [from] to
  /// [to] across [gap] frames: the similarity most of them agree on, in
  /// pixels centered on the region, and how far each lands from where it
  /// puts it (x and y by candidate).
  ///
  /// RANSAC rather than a median: points whose window sees part of the
  /// background move only part of the way, all by different amounts, and so
  /// never agree with each other, while a median leans towards them. With
  /// too few points for RANSAC, the median of their motion is used. Returns
  /// null when the motion grows or shrinks the region more than an object
  /// can between two frames.
  (SimilarityTransform, Float32List)? _regionMotion(
    List<int> candidates,
    Float32List from,
    Float32List to,
    int gap,
  ) {
    final count = candidates.length;
    final src = Float32List(2 * count);
    final dst = Float32List(2 * count);
    for (var k = 0; k < count; k++) {
      final i = candidates[k];
      src[2 * k] = from[2 * i] - _cx;
      src[2 * k + 1] = from[2 * i + 1] - _cy;
      dst[2 * k] = to[2 * i] - _cx;
      dst[2 * k + 1] = to[2 * i + 1] - _cy;
    }
    var transform = fitSimilarityRansac(
      src,
      dst,
      count,
      threshold: _fitTolerance,
      minInliers: _minPoints,
    )?.transform;
    if (transform == null) {
      final dx = [for (var k = 0; k < count; k++) dst[2 * k] - src[2 * k]];
      final dy = [
        for (var k = 0; k < count; k++) dst[2 * k + 1] - src[2 * k + 1],
      ];
      transform = SimilarityTransform(1, 0, _median(dx), _median(dy));
    }
    final maxStep = math.pow(_maxScaleStep, gap);
    if (transform.scale > maxStep || transform.scale < 1 / maxStep) {
      return null;
    }
    final errors = Float32List(2 * count);
    for (var k = 0; k < count; k++) {
      final x = src[2 * k];
      final y = src[2 * k + 1];
      errors[2 * k] = dst[2 * k] - transform.mapX(x, y);
      errors[2 * k + 1] = dst[2 * k + 1] - transform.mapY(x, y);
    }
    return (transform, errors);
  }

  /// How the scene around the region moved from [reference] to [next], in
  /// pixels centered on the frame, or null when there is too little of it
  /// to tell, or it gave no clear answer.
  ///
  /// The same estimate as stabilization's: corners tracked there and back,
  /// and a similarity fitted to them with RANSAC, here with every corner on
  /// or near the region left out.
  SimilarityTransform? _sceneMotion(LumaPyramid reference, LumaPyramid next) {
    final corners = detectCorners(reference.levels.first);
    final halfW = 0.6 * _w0 * _scale;
    final halfH = 0.6 * _h0 * _scale;
    final outside = <double>[];
    for (var i = 0; i < corners.length; i += 2) {
      if ((corners[i] - _cx).abs() <= halfW &&
          (corners[i + 1] - _cy).abs() <= halfH) {
        continue;
      }
      outside
        ..add(corners[i])
        ..add(corners[i + 1]);
    }
    final count = outside.length >> 1;
    if (count < 8) return _lastScene = null;
    final points = Float32List.fromList(outside);
    final cx0 = (width - 1) / 2;
    final cy0 = (height - 1) / 2;
    final last = _lastScene;
    Float32List? guess;
    if (last != null) {
      guess = Float32List(points.length);
      for (var i = 0; i < points.length; i += 2) {
        final x = points[i] - cx0;
        final y = points[i + 1] - cy0;
        guess[i] = last.mapX(x, y) + cx0;
        guess[i + 1] = last.mapY(x, y) + cy0;
      }
    }
    final to = Float32List(points.length);
    final forwardOk = _sceneTracker.track(
      reference,
      next,
      points,
      to,
      guess: guess,
    );
    final back = Float32List(points.length);
    final backOk = _sceneTracker.track(
      next,
      reference,
      to,
      back,
      guess: points,
    );
    final src = <double>[];
    final dst = <double>[];
    for (var i = 0; i < count; i++) {
      if (forwardOk[i] == 0 || backOk[i] == 0) continue;
      final ex = back[2 * i] - points[2 * i];
      final ey = back[2 * i + 1] - points[2 * i + 1];
      if (ex * ex + ey * ey > 0.49) continue;
      src
        ..add(points[2 * i] - cx0)
        ..add(points[2 * i + 1] - cy0);
      dst
        ..add(to[2 * i] - cx0)
        ..add(to[2 * i + 1] - cy0);
    }
    final tracked = src.length >> 1;
    final srcList = Float32List.fromList(src);
    final dstList = Float32List.fromList(dst);
    final fit = fitSimilarityRansac(srcList, dstList, tracked);
    if (fit == null || fit.inliers < 0.3 * tracked) return _lastScene = null;

    // The scatter of the points that follow the fitted motion.
    var sum = 0.0;
    var inliers = 0;
    final transform = fit.transform;
    for (var i = 0; i < tracked; i++) {
      final x = srcList[2 * i];
      final y = srcList[2 * i + 1];
      final ex = transform.mapX(x, y) - dstList[2 * i];
      final ey = transform.mapY(x, y) - dstList[2 * i + 1];
      final error = ex * ex + ey * ey;
      if (error < 1) {
        sum += error;
        inliers++;
      }
    }
    if (inliers > 0) {
      final noise = math.sqrt(sum / inliers);
      _sceneNoise = (0.8 * _sceneNoise + 0.2 * noise).clamp(0.05, 1.0);
    }
    return _lastScene = transform;
  }

  /// Finds new points inside the region in [level], the frame the region was
  /// just placed in: its corners, topped up with a grid when it has few, and
  /// none closer than [_minSpacing] to a point already followed.
  ///
  /// Each point is tracked by the window around it, so points are kept a
  /// window's reach inside the region's edge, and at least a tenth of its
  /// size, where a loosely drawn region shows the background.
  void _addPoints(LumaPyramidLevel level) {
    // Topped up only when few are left: every new point near the object's
    // outline needs a while to show it does not move with it. Once the
    // object is known only its own points count, or background that stays
    // inside a loosely drawn region would keep new points off the object.
    final followed = _foundObject
        ? _points.where((point) => point.onObject).length
        : _points.length;
    if (followed >= _refillBelow || _points.length >= _maxPoints) return;
    double inner(double half) {
      final inset = math.max(half * 0.1, _tracker.radius + 1.0);
      return math.max(half * 0.3, half - inset);
    }

    final halfW = inner(_w0 * _scale / 2);
    final halfH = inner(_h0 * _scale / 2);
    final left = _cx - halfW;
    final top = _cy - halfH;
    final right = _cx + halfW;
    final bottom = _cy + halfH;
    final candidates = <double>[
      ...detectCornersInRect(
        level,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      ),
    ];
    if (candidates.length >> 1 < _minCorners) {
      const columns = 6;
      const rows = 6;
      final margin = _tracker.radius + 1;
      for (var row = 0; row < rows; row++) {
        final y = top + (row + 0.5) * (bottom - top) / rows;
        if (y < margin || y > level.height - 1 - margin) continue;
        for (var column = 0; column < columns; column++) {
          final x = left + (column + 0.5) * (right - left) / columns;
          if (x < margin || x > level.width - 1 - margin) continue;
          candidates
            ..add(x)
            ..add(y);
        }
      }
    }

    const spacing = _minSpacing * _minSpacing;
    for (var i = 0; i < candidates.length; i += 2) {
      if (_points.length >= _maxPoints) break;
      final x = candidates[i];
      final y = candidates[i + 1];
      var crowded = false;
      for (final p in _points) {
        final dx = p.x - x;
        final dy = p.y - y;
        if (dx * dx + dy * dy < spacing) {
          crowded = true;
          break;
        }
      }
      if (crowded) continue;
      _points.add(
        _Point(
          x,
          y,
          bornCx: _cx,
          bornCy: _cy,
          bornScale: _scale,
          bornAngle: _angle,
        ),
      );
    }
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

  static double _median(List<double> values) {
    values.sort();
    final mid = values.length >> 1;
    return values.length.isOdd
        ? values[mid]
        : (values[mid - 1] + values[mid]) / 2;
  }
}

/// A point followed inside the region of a [VideoObjectTracker].
class _Point {
  _Point(
    this.x,
    this.y, {
    required this.bornCx,
    required this.bornCy,
    required this.bornScale,
    required this.bornAngle,
  }) : bornX = x,
       bornY = y;

  /// Where the point is in the last frame the region was found in.
  double x;
  double y;

  /// Where the point and the region were when it was found.
  final double bornX;
  final double bornY;
  final double bornCx;
  final double bornCy;
  final double bornScale;
  final double bornAngle;

  /// How far the point moved against the scene since it was found.
  double relX = 0;
  double relY = 0;

  /// How far it strayed from the region's motion while it counted for it.
  double driftX = 0;
  double driftY = 0;

  /// How many frames it has been followed for.
  int age = 0;

  /// Whether it moved far enough against the scene to count as the object,
  /// whether or not it moved the way the object did.
  bool movedAgainstScene = false;

  /// Whether it counts as the object.
  bool onObject = false;
}
