import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import 'keyframe_clock_point_model.dart';
import 'layer_animation_model.dart';

/// Where a layer is, how big it is, how far it is turned and how opaque it is
/// at one point of the video's timeline.
///
/// [ImageLayer.keyframes] and `VideoLayer.keyframes` move a layer between
/// them: before the first keyframe the layer holds the first one's placement,
/// after the last one the last one's, and between two of them it travels from
/// the earlier to the later one along the earlier one's [curve], eased like a
/// [LayerAnimation]. An elastic or bounce curve may overshoot either keyframe;
/// only the opacity is kept within 0–1 and the scale at 0 or more.
///
/// A keyframed placement replaces the layer's own one: [offset] its top-left
/// corner, [rotation] its rotation and [opacity] its opacity, while [scale]
/// grows or shrinks its size around its center. The layer's animations play
/// on top of it.
@immutable
class TimelineKeyframe {
  /// Creates a [TimelineKeyframe].
  const TimelineKeyframe({
    required this.time,
    required this.offset,
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.curve = AnimationCurve.linear,
  }) : assert(scale >= 0, '[scale] must not be negative'),
       assert(
         opacity >= 0 && opacity <= 1,
         '[opacity] must be between 0 and 1',
       );

  /// Creates a [TimelineKeyframe] from a map written by [toMap].
  factory TimelineKeyframe.fromMap(Map<String, dynamic> map) {
    final curveName = map['curve'];
    return TimelineKeyframe(
      time: Duration(microseconds: safeParseInt(map['timeUs'])),
      offset: Offset(safeParseDouble(map['x']), safeParseDouble(map['y'])),
      scale: safeParseDouble(map['scale'], fallback: 1),
      rotation: safeParseDouble(map['rotation']),
      opacity: safeParseDouble(map['opacity'], fallback: 1),
      curve: AnimationCurve.values.firstWhere(
        (curve) => curve.name == curveName,
        orElse: () => AnimationCurve.linear,
      ),
    );
  }

  /// When the placement applies, on the same timeline as the layer's start
  /// and end time, or on the layer's keyframe clock when it has one (see
  /// [KeyframeClockPoint]).
  final Duration time;

  /// The top-left corner of the layer's unscaled box, in pixels from the
  /// top-left corner of the video frame, like the layer's own offset.
  final Offset offset;

  /// How much the layer is grown (above 1) or shrunk (below 1) around its
  /// center, relative to its own size.
  final double scale;

  /// The layer's clockwise rotation around its center, in radians.
  ///
  /// The layer turns the whole difference to the next keyframe, so going from
  /// `0` to `2 * pi` is a full turn rather than staying still.
  final double rotation;

  /// How opaque the layer is, from 0 (invisible) to 1.
  final double opacity;

  /// How the layer travels from this keyframe to the next one.
  final AnimationCurve curve;

  /// Converts this keyframe to a map, as the native renderers read it.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'timeUs': time.inMicroseconds,
    'x': offset.dx,
    'y': offset.dy,
    'scale': scale,
    'rotation': rotation,
    'opacity': opacity,
    'curve': curve.name,
  };

  /// Creates a copy with the given fields replaced.
  TimelineKeyframe copyWith({
    Duration? time,
    Offset? offset,
    double? scale,
    double? rotation,
    double? opacity,
    AnimationCurve? curve,
  }) {
    return TimelineKeyframe(
      time: time ?? this.time,
      offset: offset ?? this.offset,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      curve: curve ?? this.curve,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TimelineKeyframe &&
        other.time == time &&
        other.offset == offset &&
        other.scale == scale &&
        other.rotation == rotation &&
        other.opacity == opacity &&
        other.curve == curve;
  }

  @override
  int get hashCode =>
      Object.hash(time, offset, scale, rotation, opacity, curve);

  @override
  String toString() =>
      'TimelineKeyframe(time: $time, offset: $offset, scale: $scale, '
      'rotation: $rotation, opacity: $opacity, curve: $curve)';
}

/// [keyframes] sorted by [TimelineKeyframe.time], as a new list.
List<TimelineKeyframe> sortTimelineKeyframes(
  Iterable<TimelineKeyframe> keyframes,
) {
  final sorted = keyframes.toList();
  mergeSort(sorted, compare: (a, b) => a.time.compareTo(b.time));
  return sorted;
}
