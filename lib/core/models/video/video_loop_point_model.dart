import 'package:flutter/foundation.dart';

/// Where to cut a video so that it loops without a visible jump, found by
/// `VideoLoopPointFinder`.
///
/// The loop plays the source from [start] up to, but not including, [end],
/// and then starts over at [start]. All times are source timestamps: the
/// position in the video file, not on a rendered timeline. When the loop
/// starts over in another file than it ends in, [start] is a time in that
/// file.
@immutable
class VideoLoopPoint {
  /// Creates a [VideoLoopPoint].
  const VideoLoopPoint({
    required this.start,
    required this.end,
    required this.difference,
    required this.currentDifference,
  });

  /// The first frame the loop shows.
  final Duration start;

  /// The source time of the first frame the loop no longer shows: the frame
  /// that looks most like the one at [start], so that cutting right before
  /// it makes the restart look like one more step of the motion.
  final Duration end;

  /// How different the picture is at the seam: the mean absolute luma
  /// difference between the frames on both sides of the cut, from 0 for
  /// identical frames to 1 for black against white.
  ///
  /// The frames next to the seam count too, so a pendulum that is in the
  /// same place but swinging the other way does not match.
  final double difference;

  /// [difference] for the seam the video had before, with the start and end
  /// the search was asked about.
  ///
  /// When the video has no frame at that end, its last frame is compared
  /// with the first one instead, which reads somewhat higher than a cut at
  /// the same place would: it includes one frame of motion.
  final double currentDifference;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoLoopPoint &&
          other.start == start &&
          other.end == end &&
          other.difference == difference &&
          other.currentDifference == currentDifference;

  @override
  int get hashCode => Object.hash(start, end, difference, currentDifference);

  @override
  String toString() =>
      'VideoLoopPoint(start: $start, end: $end, '
      'difference: ${difference.toStringAsFixed(4)}, '
      'currentDifference: ${currentDifference.toStringAsFixed(4)})';
}
