import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';

/// A speed that changes while a `VideoSegment` plays, for example fast into a
/// jump, slow motion on its peak and fast again on the landing.
///
/// Each of the [points] puts a speed at a position along the segment: `0` is
/// its first frame and `1` its last, in the order the segment plays, so the
/// positions run along the source between `startTime` and `endTime` (from
/// `endTime` back to `startTime` when the segment is reversed). Between two
/// points the speed eases from one to the other on a smooth curve that never
/// goes past either of them; before the first point and after the last one it
/// holds that point's speed. The curve is flat at the first and the last point,
/// so the segment eases into and out of the ramp.
///
/// The renderers play the curve as [steps], short stretches at one speed each,
/// fine enough that motion and sound follow the curve. Every duration this
/// class reports is measured on those steps, so an editor that lays out its
/// timeline with [outputDuration], [sourceToOutput] and [outputToSource] puts
/// every frame where the render puts it.
///
/// Sound follows the speed like a tape running faster or slower: it sounds
/// lower while the segment slows down and higher while it speeds up. A
/// constant `VideoSegment.playbackSpeed` keeps the pitch instead.
@immutable
class VideoSpeedRamp {
  /// Creates a [VideoSpeedRamp] from [points] sorted by position.
  ///
  /// [points] must not be empty; their positions must lie between `0` and `1`
  /// and increase, and their speeds must be greater than `0`.
  const VideoSpeedRamp(this.points) : _source = null, _start = 0, _end = 1;

  /// The stretch of [_source] from [_start] to [_end], see [cropped].
  const VideoSpeedRamp._crop(
    this.points,
    VideoSpeedRamp this._source,
    this._start,
    this._end,
  );

  /// Creates a [VideoSpeedRamp] from a map written by [toMap].
  factory VideoSpeedRamp.fromMap(Map<String, dynamic> map) {
    final raw = map['points'] as List<dynamic>? ?? const [];
    final points = [
      for (final point in raw)
        VideoSpeedRampPoint.fromMap(Map<String, dynamic>.from(point as Map)),
    ];
    final crop = map['crop'];
    if (crop is Map && crop['source'] is Map) {
      final source = VideoSpeedRamp.fromMap(
        Map<String, dynamic>.from(crop['source'] as Map),
      );
      final start = safeParseDouble(crop['start']);
      final end = safeParseDouble(crop['end'], fallback: 1);
      // Without a usable original ramp, play the points like an old reader.
      if (source.points.isNotEmpty && 0 <= start && start < end && end <= 1) {
        return VideoSpeedRamp._crop(points, source, start, end);
      }
    }
    return VideoSpeedRamp(points);
  }

  /// The speeds the curve passes through, sorted by
  /// [VideoSpeedRampPoint.position].
  ///
  /// For a [cropped] ramp these are the curve's speeds at both cut edges and
  /// the points of the original ramp between them, which is what an editor
  /// draws for it.
  final List<VideoSpeedRampPoint> points;

  /// The uncropped ramp a [cropped] ramp plays a stretch of, or `null`.
  final VideoSpeedRamp? _source;

  /// Where the stretch a [cropped] ramp plays starts and ends on [_source].
  final double _start;
  final double _end;

  /// The largest change of speed between two neighbouring [steps], as a
  /// factor.
  ///
  /// 5 % is below a change anyone notices between two frames, while a common
  /// ramp from 1× down to 0.3× stays under forty steps.
  static const double maxStepChange = 1.05;

  /// The most [steps] a stretch between two points is split into; only a
  /// steep stretch, such as an ease between two speeds more than eightfold
  /// apart, reaches it.
  static const int maxStepsBetweenPoints = 64;

  static final Expando<List<VideoSpeedRampStep>> _stepCache = Expando(
    'VideoSpeedRamp.steps',
  );

  /// Whether the segment plays at one speed throughout, which is then
  /// [averageSpeed].
  ///
  /// A [cropped] ramp inside a single one of the [steps] plays at one speed
  /// even though its [points] differ slightly.
  bool get isConstant => _source == null
      ? points.every((p) => p.speed == points.first.speed)
      : steps.every((s) => s.speed == steps.first.speed);

  /// The speed of the smooth curve at [position], between `0` and `1`.
  ///
  /// This is the curve to draw in an editor; the render plays its [steps].
  double speedAt(double position) {
    final source = _source;
    if (source != null) return source.speedAt(_sourcePosition(position));
    _debugCheckPoints();
    return math.exp(_logSpeedAt(position.clamp(0.0, 1.0)));
  }

  /// The curve as the renderers play it: back-to-back stretches of the
  /// segment, from position `0` to `1`, each at a constant speed.
  ///
  /// A stretch between two points with the same speed is a single step; a
  /// stretch that changes speed is split finely enough that two neighbouring
  /// steps differ by at most [maxStepChange].
  List<VideoSpeedRampStep> get steps {
    return _stepCache[this] ??= List.unmodifiable(
      _source == null ? _buildSteps() : _cropSteps(_source),
    );
  }

  /// How long the segment plays compared to its source: `2.0` when the ramp
  /// makes it play twice as long, `0.5` when it plays in half the time.
  double get durationFactor {
    var factor = 0.0;
    for (final step in steps) {
      factor += (step.end - step.start) / step.speed;
    }
    return factor;
  }

  /// The constant speed that would play the segment in the same time.
  double get averageSpeed => 1 / durationFactor;

  /// How long a segment with [sourceDuration] of source plays with this ramp.
  Duration outputDuration(Duration sourceDuration) {
    return Duration(
      microseconds: (sourceDuration.inMicroseconds * durationFactor).round(),
    );
  }

  /// Where the frame [sourceOffset] into the segment's source plays, measured
  /// from the segment's start.
  ///
  /// [sourceOffset] counts in the order the segment plays, like the points'
  /// positions, and is clamped to the segment.
  Duration sourceToOutput(
    Duration sourceOffset, {
    required Duration sourceDuration,
  }) {
    final sourceUs = sourceDuration.inMicroseconds;
    if (sourceUs <= 0) return Duration.zero;
    final target = (sourceOffset.inMicroseconds / sourceUs).clamp(0.0, 1.0);

    var output = 0.0;
    for (final step in steps) {
      if (target <= step.start) break;
      final end = math.min(target, step.end);
      output += (end - step.start) / step.speed;
    }
    return Duration(microseconds: (output * sourceUs).round());
  }

  /// Which frame of the segment's source plays [outputOffset] after the
  /// segment's start; the inverse of [sourceToOutput].
  ///
  /// The result counts in the order the segment plays and is clamped to the
  /// segment, as is [outputOffset].
  Duration outputToSource(
    Duration outputOffset, {
    required Duration sourceDuration,
  }) {
    final sourceUs = sourceDuration.inMicroseconds;
    if (sourceUs <= 0) return Duration.zero;
    var remaining = math.max(0.0, outputOffset.inMicroseconds / sourceUs);

    for (final step in steps) {
      final stepOutput = (step.end - step.start) / step.speed;
      if (remaining <= stepOutput) {
        final position = step.start + remaining * step.speed;
        return Duration(microseconds: (position * sourceUs).round());
      }
      remaining -= stepOutput;
    }
    return sourceDuration;
  }

  /// The ramp of the part of the segment from [start] to [end] (positions
  /// between `0` and `1`), stretched back onto `0` to `1`: what a segment
  /// split or trimmed down to that part plays.
  ///
  /// The part plays the very steps the whole played there, cut at its edges,
  /// so every frame keeps its speed and its place: the parts of a split play
  /// for exactly as long as the whole did, and a cut lands on the frame it
  /// was made on. [points] show the stretch of the curve the part covers.
  VideoSpeedRamp cropped(double start, double end) {
    assert(
      0 <= start && start < end && end <= 1,
      'cropped needs 0 <= start < end <= 1',
    );
    if (start <= 0 && end >= 1) return this;
    final source = _source;
    if (source != null) {
      // A crop of a crop is a stretch of the same original ramp.
      return source.cropped(_sourcePosition(start), _sourcePosition(end));
    }
    final width = end - start;
    return VideoSpeedRamp._crop(
      [
        VideoSpeedRampPoint(position: 0, speed: speedAt(start)),
        for (final point in points)
          if (point.position > start && point.position < end)
            VideoSpeedRampPoint(
              position: (point.position - start) / width,
              speed: point.speed,
            ),
        VideoSpeedRampPoint(position: 1, speed: speedAt(end)),
      ],
      this,
      start,
      end,
    );
  }

  /// The ramp of the segment played backwards, so every frame keeps its
  /// speed: the slow motion stays on the same moment.
  VideoSpeedRamp get reversed {
    final source = _source;
    if (source != null) return source.reversed.cropped(1 - _end, 1 - _start);
    return VideoSpeedRamp([
      for (final point in points.reversed)
        VideoSpeedRampPoint(position: 1 - point.position, speed: point.speed),
    ]);
  }

  /// Converts this ramp to a map that [VideoSpeedRamp.fromMap] reads back.
  ///
  /// A [cropped] ramp adds its original ramp and where it was cut under
  /// `crop`. A reader that does not know it plays [points] instead, eased as
  /// a ramp of its own.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'points': [for (final point in points) point.toMap()],
    if (_source case final source?)
      'crop': <String, dynamic>{
        'source': source.toMap(),
        'start': _start,
        'end': _end,
      },
  };

  /// The [steps] as the native renderers read them.
  List<Map<String, double>> toChannelSteps() => [
    for (final step in steps) step.toMap(),
  ];

  /// Where [position] of a [cropped] ramp lies on [_source]. Both edges map
  /// exactly onto the cut, so trimming one end of a crop keeps the other.
  double _sourcePosition(double position) {
    if (position <= 0) return _start;
    if (position >= 1) return _end;
    return _start + (_end - _start) * position;
  }

  /// [source]'s steps between [_start] and [_end], stretched onto `0` to `1`.
  List<VideoSpeedRampStep> _cropSteps(VideoSpeedRamp source) {
    final width = _end - _start;
    final steps = <VideoSpeedRampStep>[];
    for (final step in source.steps) {
      final start = math.max(step.start, _start);
      final end = math.min(step.end, _end);
      if (end <= start) continue;
      steps.add(
        VideoSpeedRampStep(
          start: (start - _start) / width,
          end: (end - _start) / width,
          speed: step.speed,
        ),
      );
    }
    return steps;
  }

  List<VideoSpeedRampStep> _buildSteps() {
    _debugCheckPoints();
    final steps = <VideoSpeedRampStep>[];
    void add(double start, double end, double speed) {
      if (end <= start) return;
      if (steps.isNotEmpty && steps.last.speed == speed) {
        steps[steps.length - 1] = VideoSpeedRampStep(
          start: steps.last.start,
          end: end,
          speed: speed,
        );
      } else {
        steps.add(VideoSpeedRampStep(start: start, end: end, speed: speed));
      }
    }

    final first = points.first;
    final last = points.last;
    add(0, first.position, first.speed);
    for (var k = 0; k < points.length - 1; k++) {
      final a = points[k];
      final b = points[k + 1];
      final flat = a.speed == b.speed;
      // The steepest part of the stretch sets the step size.
      final count = flat
          ? 1
          : ((b.position - a.position) *
                    _maxLogSlope(k) /
                    math.log(maxStepChange))
                .ceil()
                .clamp(1, maxStepsBetweenPoints);
      double boundary(int i) => i == count
          ? b.position
          : a.position + (b.position - a.position) * i / count;
      for (var i = 0; i < count; i++) {
        final start = boundary(i);
        final end = boundary(i + 1);
        final speed = flat ? a.speed : math.exp(_logSpeedAt((start + end) / 2));
        add(start, end, speed);
      }
    }
    add(last.position, 1, last.speed);
    return steps;
  }

  /// The natural logarithm of the curve's speed at [position], on a monotone
  /// cubic through the points' log speeds: in log space a slow-down to 0.5×
  /// and a speed-up to 2× feel equally strong, and a monotone curve never
  /// overshoots a point.
  double _logSpeedAt(double position) {
    final first = points.first;
    final last = points.last;
    if (position <= first.position) return math.log(first.speed);
    if (position >= last.position) return math.log(last.speed);

    var k = 0;
    while (points[k + 1].position < position) {
      k++;
    }
    final a = points[k];
    final b = points[k + 1];
    final h = b.position - a.position;
    final t = (position - a.position) / h;
    final t2 = t * t;
    final t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * math.log(a.speed) +
        (t3 - 2 * t2 + t) * h * _tangent(k) +
        (-2 * t3 + 3 * t2) * math.log(b.speed) +
        (t3 - t2) * h * _tangent(k + 1);
  }

  /// The steepest slope of the log-speed curve between point [k] and the next
  /// one, per unit of position.
  ///
  /// The cubic's derivative is a parabola, so it peaks at either end of the
  /// stretch or at the parabola's vertex.
  double _maxLogSlope(int k) {
    final a = points[k];
    final b = points[k + 1];
    final h = b.position - a.position;
    final y0 = math.log(a.speed);
    final y1 = math.log(b.speed);
    final m0 = h * _tangent(k);
    final m1 = h * _tangent(k + 1);
    // d/dt of the Hermite cubic, as qa·t² + qb·t + qc.
    final qa = 6 * y0 + 3 * m0 - 6 * y1 + 3 * m1;
    final qb = -6 * y0 - 4 * m0 + 6 * y1 - 2 * m1;
    final qc = m0;
    double derivative(double t) => (qa * t * t + qb * t + qc).abs();
    var steepest = math.max(derivative(0), derivative(1));
    if (qa != 0) {
      final vertex = -qb / (2 * qa);
      if (vertex > 0 && vertex < 1) {
        steepest = math.max(steepest, derivative(vertex));
      }
    }
    return steepest / h;
  }

  /// The slope of the log-speed curve at point [k], by the weighted harmonic
  /// mean of Fritsch and Butland. Zero at both ends and at every turning
  /// point, which is what keeps the curve from overshooting.
  double _tangent(int k) {
    if (k == 0 || k == points.length - 1) return 0;
    final prev = points[k - 1];
    final point = points[k];
    final next = points[k + 1];
    final h0 = point.position - prev.position;
    final h1 = next.position - point.position;
    final d0 = (math.log(point.speed) - math.log(prev.speed)) / h0;
    final d1 = (math.log(next.speed) - math.log(point.speed)) / h1;
    if (d0 == 0 || d1 == 0 || d0.sign != d1.sign) return 0;
    final w0 = 2 * h1 + h0;
    final w1 = h1 + 2 * h0;
    return (w0 + w1) / (w0 / d0 + w1 / d1);
  }

  void _debugCheckPoints() {
    assert(() {
      if (points.isEmpty) {
        throw ArgumentError.value(points, 'points', 'must not be empty');
      }
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        if (!(point.speed > 0) || !point.speed.isFinite) {
          throw ArgumentError.value(
            point.speed,
            'points[$i].speed',
            'must be a finite number greater than 0',
          );
        }
        if (point.position < 0 || point.position > 1) {
          throw ArgumentError.value(
            point.position,
            'points[$i].position',
            'must be between 0 and 1',
          );
        }
        if (i > 0 && point.position <= points[i - 1].position) {
          throw ArgumentError.value(
            point.position,
            'points[$i].position',
            'must be greater than the position of the point before it',
          );
        }
      }
      return true;
    }());
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoSpeedRamp &&
        listEquals(other.points, points) &&
        other._source == _source &&
        other._start == _start &&
        other._end == _end;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(points), _source, _start, _end);

  @override
  String toString() => _source == null
      ? 'VideoSpeedRamp(points: $points)'
      : 'VideoSpeedRamp(points: $points, cropped from $_source at '
            '$_start to $_end)';
}

/// One speed a [VideoSpeedRamp] passes through.
@immutable
class VideoSpeedRampPoint {
  /// Creates a [VideoSpeedRampPoint].
  const VideoSpeedRampPoint({required this.position, required this.speed});

  /// Creates a [VideoSpeedRampPoint] from a map written by [toMap].
  factory VideoSpeedRampPoint.fromMap(Map<String, dynamic> map) {
    return VideoSpeedRampPoint(
      position: safeParseDouble(map['position']),
      speed: safeParseDouble(map['speed'], fallback: 1),
    );
  }

  /// Where along the segment the speed applies, from `0` at its first frame
  /// to `1` at its last, in the order the segment plays.
  final double position;

  /// The speed there, for example `0.5` for half speed or `2.0` for double
  /// speed.
  final double speed;

  /// Converts this point to a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'position': position,
    'speed': speed,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoSpeedRampPoint &&
        other.position == position &&
        other.speed == speed;
  }

  @override
  int get hashCode => Object.hash(position, speed);

  @override
  String toString() =>
      'VideoSpeedRampPoint(position: $position, speed: $speed)';
}

/// A stretch of a segment that a [VideoSpeedRamp] plays at one speed.
@immutable
class VideoSpeedRampStep {
  /// Creates a [VideoSpeedRampStep].
  const VideoSpeedRampStep({
    required this.start,
    required this.end,
    required this.speed,
  });

  /// Where the stretch starts, from `0` to `1` along the segment.
  final double start;

  /// Where the stretch ends, from `0` to `1` along the segment.
  final double end;

  /// The speed the stretch plays at.
  final double speed;

  /// Converts this step to a map, as the native renderers read it.
  Map<String, double> toMap() => <String, double>{
    'start': start,
    'end': end,
    'speed': speed,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoSpeedRampStep &&
        other.start == start &&
        other.end == end &&
        other.speed == speed;
  }

  @override
  int get hashCode => Object.hash(start, end, speed);

  @override
  String toString() =>
      'VideoSpeedRampStep(start: $start, end: $end, speed: $speed)';
}
