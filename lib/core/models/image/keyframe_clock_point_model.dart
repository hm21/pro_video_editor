import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// One point of the clock a layer's keyframes are timed on: the layer is at
/// [keyframe] on that clock when the rendered video is at [output].
///
/// [ImageLayer.keyframeClock] and `VideoLayer.keyframeClock` map every frame's
/// time to the keyframes' clock, linearly between two points. Before the first
/// point and after the last one the clock runs as fast as the video; without
/// points the keyframes are timed on the video's own timeline.
///
/// Lets keyframes keep the timing they were made on. An editor that shows a
/// clip transition one clip after the other, while the video plays both clips
/// at once, runs at twice the video's pace through it; a point at either end
/// of the transition keeps every eased motion on the curve the editor shows,
/// however short the stretch between two keyframes is.
@immutable
class KeyframeClockPoint {
  /// Creates a [KeyframeClockPoint].
  const KeyframeClockPoint({required this.output, required this.keyframe});

  /// Creates a [KeyframeClockPoint] from a map written by [toMap].
  factory KeyframeClockPoint.fromMap(Map<String, dynamic> map) {
    return KeyframeClockPoint(
      output: Duration(microseconds: safeParseInt(map['outputUs'])),
      keyframe: Duration(microseconds: safeParseInt(map['keyframeUs'])),
    );
  }

  /// The time on the rendered video.
  final Duration output;

  /// The time on the keyframes' clock at [output].
  final Duration keyframe;

  /// Converts this point to a map, as the native renderers read it.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'outputUs': output.inMicroseconds,
    'keyframeUs': keyframe.inMicroseconds,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyframeClockPoint &&
        other.output == output &&
        other.keyframe == keyframe;
  }

  @override
  int get hashCode => Object.hash(output, keyframe);

  @override
  String toString() =>
      'KeyframeClockPoint(output: $output, keyframe: $keyframe)';
}

/// The points in the `keyframeClock` [raw] from a layer map, or none.
List<KeyframeClockPoint> keyframeClockFromMap(Object? raw) {
  return (raw as List<dynamic>?)
          ?.map(
            (point) => KeyframeClockPoint.fromMap(
              Map<String, dynamic>.from(point as Map),
            ),
          )
          .toList() ??
      const [];
}
