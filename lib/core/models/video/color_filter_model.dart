import 'package:pro_video_editor/shared/models/time_range_mixin.dart';

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
  const ColorFilter({
    required this.matrix,
    this.startTime,
    this.endTime,
  }) : assert(
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
}
