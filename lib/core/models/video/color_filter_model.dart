// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:pro_video_editor/shared/models/time_range_mixin.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// A model representing a color filter with timing information.
///
/// Each [ColorFilter] applies a 4x5 color transformation matrix to the
/// video during a specific time range.
///
/// If [startTime] and [endTime] are both `null`, the filter is applied for the
/// entire duration of the video.
class ColorFilter with TimeRangeMixin {
  /// Creates a [ColorFilter] with the given [matrix], [startTime],
  /// and optional [endTime].
  const ColorFilter({required this.matrix, this.startTime, this.endTime})
    : assert(
        startTime == null || endTime == null || startTime < endTime,
        'startTime must be before endTime',
      );

  /// A 4x5 color matrix used to apply color filters
  /// (e.g., saturation, brightness).
  final List<double> matrix;

  @override
  final Duration? startTime;

  @override
  final Duration? endTime;

  ColorFilter copyWith({
    List<double>? matrix,
    Duration? startTime,
    Duration? endTime,
  }) {
    return ColorFilter(
      matrix: matrix ?? this.matrix,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'matrix': matrix,
      'startTime': startTime?.inMicroseconds,
      'endTime': endTime?.inMicroseconds,
    };
  }

  factory ColorFilter.fromMap(Map<String, dynamic> map) {
    return ColorFilter(
      matrix: List<double>.from(map['matrix'] as List),
      startTime: map['startTime'] != null
          ? Duration(microseconds: safeParseInt(map['startTime']))
          : null,
      endTime: map['endTime'] != null
          ? Duration(microseconds: safeParseInt(map['endTime']))
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory ColorFilter.fromJson(String source) =>
      ColorFilter.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'ColorFilter(matrix: $matrix, startTime: $startTime, endTime: $endTime)';

  @override
  bool operator ==(covariant ColorFilter other) {
    if (identical(this, other)) return true;

    return listEquals(other.matrix, matrix) &&
        other.startTime == startTime &&
        other.endTime == endTime;
  }

  @override
  int get hashCode => matrix.hashCode ^ startTime.hashCode ^ endTime.hashCode;
}
