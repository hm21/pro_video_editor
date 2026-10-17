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
  const VideoSpeedRamp(this.points);

  /// Creates a [VideoSpeedRamp] from a map written by [toMap].
  factory VideoSpeedRamp.fromMap(Map<String, dynamic> map) {
    final raw = map['points'] as List<dynamic>? ?? const [];
    return VideoSpeedRamp([
      for (final point in raw)
        VideoSpeedRampPoint.fromMap(Map<String, dynamic>.from(point as Map)),
    ]);
  }

  /// The speeds the curve passes through, sorted by
  /// [VideoSpeedRampPoint.position].
  final List<VideoSpeedRampPoint> points;

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

  /// Whether every point has the same speed, so the segment plays at one
  /// speed throughout.
  bool get isConstant => points.every((p) => p.speed == points.first.speed);

  /// The speed of the smooth curve at [position], between `0` and `1`.
  ///
  /// This is the curve to draw in an editor; the render plays its [steps].
  double speedAt(double position) {
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
    return _stepCache[this] ??= List.unmodifiable(_buildSteps());
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
  /// Keeps the points inside the part and pins the speed the curve has at
  /// both cut edges, so every frame plays at about the speed it had. The curve
  /// eases into and out of the new ends, which can move the part's timing by a
  /// few frames.
  VideoSpeedRamp cropped(double start, double end) {
    assert(
      0 <= start && start < end && end <= 1,
      'cropped needs 0 <= start < end <= 1',
    );
    if (start <= 0 && end >= 1) return this;
    final width = end - start;
    return VideoSpeedRamp([
      VideoSpeedRampPoint(position: 0, speed: speedAt(start)),
      for (final point in points)
        if (point.position > start && point.position < end)
          VideoSpeedRampPoint(
            position: (point.position - start) / width,
            speed: point.speed,
          ),
      VideoSpeedRampPoint(position: 1, speed: speedAt(end)),
    ]);
  }

  /// The ramp of the segment played backwards, so every frame keeps its
  /// speed: the slow motion stays on the same moment.
  VideoSpeedRamp get reversed => VideoSpeedRamp([
    for (final point in points.reversed)
      VideoSpeedRampPoint(position: 1 - point.position, speed: point.speed),
  ]);

  /// Converts this ramp to a map that [VideoSpeedRamp.fromMap] reads back.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'points': [for (final point in points) point.toMap()],
  };

  /// The [steps] as the native renderers read them.
  List<Map<String, double>> toChannelSteps() => [
    for (final step in steps) step.toMap(),
  ];

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
    return other is VideoSpeedRamp && listEquals(other.points, points);
  }

  @override
  int get hashCode => Object.hashAll(points);

  @override
  String toString() => 'VideoSpeedRamp(points: $points)';
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
