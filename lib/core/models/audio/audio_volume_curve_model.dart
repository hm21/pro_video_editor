import 'package:flutter/foundation.dart';

import '/shared/utils/parser/double_parser.dart';
import '/shared/utils/parser/int_parser.dart';

/// One point of an [AudioVolumeCurve]: the volume at [time].
@immutable
class AudioVolumePoint {
  /// Creates a point with a [volume] from 0 (silent) to 1 (unchanged).
  const AudioVolumePoint({required this.time, required this.volume})
    : assert(volume >= 0 && volume <= 1, '[volume] must be between 0 and 1');

  /// Creates a point from a map written by [toMap].
  factory AudioVolumePoint.fromMap(Map<String, dynamic> map) {
    return AudioVolumePoint(
      time: Duration(microseconds: safeParseInt(map['time'])),
      volume: safeParseDouble(map['volume'], fallback: 1),
    );
  }

  /// Where on the exported video the point sits.
  final Duration time;

  /// The volume multiplier at [time], from 0 (silent) to 1 (unchanged).
  final double volume;

  /// Converts the point into a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'time': time.inMicroseconds,
    'volume': volume,
  };

  @override
  bool operator ==(Object other) =>
      other is AudioVolumePoint && other.time == time && other.volume == volume;

  @override
  int get hashCode => Object.hash(time, volume);

  @override
  String toString() => 'AudioVolumePoint(time: $time, volume: $volume)';
}

/// A volume that changes over time on the exported video, moving in a
/// straight line from one of its [points] to the next.
///
/// Before the first point the volume stays at the first point's, and after
/// the last one at the last point's. A curve without points leaves the audio
/// unchanged.
///
/// Set one on [VideoAudioTrack.volumeCurve] to automate a track's volume,
/// for example the curve [AudioDucking.curve] builds to lower music while a
/// voice-over talks. Play the same curve in a preview through [volumeAt].
@immutable
class AudioVolumeCurve {
  /// Creates a curve through [points], which it sorts by
  /// [AudioVolumePoint.time].
  ///
  /// Two points may share a time; the volume then jumps there from the one
  /// given first to the one given second.
  AudioVolumeCurve(List<AudioVolumePoint> points)
    : points = List.unmodifiable(_sorted(points));

  /// Creates a curve from a map written by [toMap].
  factory AudioVolumeCurve.fromMap(Map<String, dynamic> map) {
    final points = map['points'] as List<dynamic>? ?? const [];
    return AudioVolumeCurve([
      for (final point in points)
        AudioVolumePoint.fromMap(Map<String, dynamic>.from(point as Map)),
    ]);
  }

  /// The points the volume moves through, sorted by time.
  final List<AudioVolumePoint> points;

  /// Whether the curve leaves the volume unchanged everywhere.
  bool get isFlat => points.every((point) => point.volume == 1);

  /// The volume multiplier at [time], from 0 to 1.
  ///
  /// It is exactly what the render applies at that time, so a preview that
  /// scales its own volume by it plays the same dips.
  double volumeAt(Duration time) {
    if (points.isEmpty) return 1;
    final micros = time.inMicroseconds;
    if (micros <= points.first.time.inMicroseconds) return points.first.volume;
    if (micros >= points.last.time.inMicroseconds) return points.last.volume;

    // The last point at or before [time]; the one after it is later.
    var low = 0;
    var high = points.length - 1;
    while (high - low > 1) {
      final middle = (low + high) >> 1;
      if (points[middle].time.inMicroseconds <= micros) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final from = points[low];
    final to = points[high];
    final span = to.time.inMicroseconds - from.time.inMicroseconds;
    if (span <= 0) return to.volume;
    final t = (micros - from.time.inMicroseconds) / span;
    return from.volume + (to.volume - from.volume) * t;
  }

  /// Converts the curve into a map.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'points': points.map((point) => point.toMap()).toList(),
  };

  /// The points as `[time in µs, volume, time in µs, volume, …]`, the form
  /// the native renderers read in one piece.
  Float64List toChannelData() => Float64List.fromList([
    for (final point in points) ...[
      point.time.inMicroseconds.toDouble(),
      point.volume,
    ],
  ]);

  @override
  bool operator ==(Object other) =>
      other is AudioVolumeCurve && listEquals(other.points, points);

  @override
  int get hashCode => Object.hashAll(points);

  @override
  String toString() => 'AudioVolumeCurve(points: $points)';

  /// [points] by time; points that share a time keep their order.
  static List<AudioVolumePoint> _sorted(List<AudioVolumePoint> points) {
    var isSorted = true;
    for (var i = 1; i < points.length && isSorted; i++) {
      isSorted = points[i].time >= points[i - 1].time;
    }
    if (isSorted) return points;
    // List.sort is not stable, so the index breaks ties.
    final indexed = [for (var i = 0; i < points.length; i++) (i, points[i])]
      ..sort((a, b) {
        final byTime = a.$2.time.compareTo(b.$2.time);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [for (final (_, point) in indexed) point];
  }
}
