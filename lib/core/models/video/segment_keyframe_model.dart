import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import '../image/layer_animation_model.dart';

/// Where a segment's picture is moved, how far it is zoomed and how far it is
/// turned at one frame of its source video.
///
/// [VideoSegment.keyframes] moves the picture between them, for a pan, a zoom
/// into a detail or a turning camera move: each frame takes the placement of
/// its own source timestamp, so the motion stays on the frames it was set on
/// however the segment is trimmed, split, sped up or played into a
/// transition. Before the first keyframe the picture holds the first one's
/// placement, after the last one the last one's, and between two of them it
/// travels from the earlier to the later one along the earlier one's [curve].
/// An elastic or bounce curve may overshoot either keyframe; only the scale is
/// kept at 0 or more.
///
/// The frame is scaled by [scale] and turned by [rotation] around its center,
/// then shifted by [offset], in its own upright pixel space with the origin
/// top left, as the video is displayed.
@immutable
class SegmentKeyframe {
  /// Creates a [SegmentKeyframe].
  const SegmentKeyframe({
    required this.time,
    this.offset = Offset.zero,
    this.scale = 1,
    this.rotation = 0,
    this.curve = AnimationCurve.linear,
  }) : assert(scale >= 0, '[scale] must not be negative');

  /// Creates a [SegmentKeyframe] from a map written by [toMap].
  factory SegmentKeyframe.fromMap(Map<String, dynamic> map) {
    final curveName = map['curve'];
    return SegmentKeyframe(
      time: Duration(microseconds: safeParseInt(map['timeUs'])),
      offset: Offset(safeParseDouble(map['x']), safeParseDouble(map['y'])),
      scale: safeParseDouble(map['scale'], fallback: 1),
      rotation: safeParseDouble(map['rotation']),
      curve: AnimationCurve.values.firstWhere(
        (curve) => curve.name == curveName,
        orElse: () => AnimationCurve.linear,
      ),
    );
  }

  /// The source timestamp of the frame this placement belongs to: the
  /// position in the video file, not on the rendered timeline.
  final Duration time;

  /// The shift, as a fraction of the frame's width (dx) and height (dy). A
  /// positive dx moves the picture right, a positive dy moves it down.
  final Offset offset;

  /// How far the picture is zoomed around the frame's center: 1 shows it as
  /// it is, 2 shows the middle half of it across the whole frame.
  ///
  /// Below 1, and wherever [rotation] or [offset] moves the picture off part
  /// of the frame, the uncovered part is black.
  final double scale;

  /// The picture's clockwise rotation around the frame's center, in radians.
  ///
  /// The picture turns the whole difference to the next keyframe, so going
  /// from `0` to `2 * pi` is a full turn rather than staying still.
  final double rotation;

  /// How the picture travels from this keyframe to the next one.
  final AnimationCurve curve;

  /// Converts this keyframe to a map, as the native renderers read it.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'timeUs': time.inMicroseconds,
    'x': offset.dx,
    'y': offset.dy,
    'scale': scale,
    'rotation': rotation,
    'curve': curve.name,
  };

  /// Creates a copy with the given fields replaced.
  SegmentKeyframe copyWith({
    Duration? time,
    Offset? offset,
    double? scale,
    double? rotation,
    AnimationCurve? curve,
  }) {
    return SegmentKeyframe(
      time: time ?? this.time,
      offset: offset ?? this.offset,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      curve: curve ?? this.curve,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SegmentKeyframe &&
        other.time == time &&
        other.offset == offset &&
        other.scale == scale &&
        other.rotation == rotation &&
        other.curve == curve;
  }

  @override
  int get hashCode => Object.hash(time, offset, scale, rotation, curve);

  @override
  String toString() =>
      'SegmentKeyframe(time: $time, offset: $offset, scale: $scale, '
      'rotation: $rotation, curve: $curve)';
}

/// [keyframes] sorted by [SegmentKeyframe.time], as a new list.
List<SegmentKeyframe> sortSegmentKeyframes(
  Iterable<SegmentKeyframe> keyframes,
) {
  final sorted = keyframes.toList();
  mergeSort(sorted, compare: (a, b) => a.time.compareTo(b.time));
  return sorted;
}
