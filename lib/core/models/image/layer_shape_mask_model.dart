import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/shared/utils/parser/double_parser.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

import 'layer_animation_model.dart';

/// The shape a [LayerShapeMask] lets its layer show through.
///
/// Every shape but [linear] fills the mask's box, the rectangle that
/// [LayerShapeMask.center] and [LayerShapeMask.size] describe before
/// [LayerShapeMask.rotation] turns it. They are the shapes of the
/// `LayerMaskShape` of the sister package `pro_image_editor`, so a mask drawn
/// in its editor exports as it showed there.
enum LayerShapeMaskShape {
  /// An ellipse filling the box; a circle when the box is square.
  ellipse,

  /// A rectangle filling the box, its corners rounded by
  /// [LayerShapeMask.cornerRadius].
  rectangle,

  /// A heart filling the box, its tip at the bottom while unturned.
  heart,

  /// A five-pointed star filling the box, a point at the top while unturned.
  star,

  /// A triangle filling the box, its tip at the middle of the top and its base
  /// along the bottom while unturned.
  triangle,

  /// A diamond filling the box, its corners on the middle of each side.
  diamond,

  /// A hexagon filling the box, a corner at the top and one at the bottom
  /// while unturned.
  hexagon,

  /// A speech bubble filling the box: a rounded body over its top four fifths
  /// with a tail pointing down from its bottom left while unturned.
  speechBubble,

  /// A straight edge through [LayerShapeMask.center], turned by
  /// [LayerShapeMask.rotation]. The layer shows above it while it is unturned;
  /// [LayerShapeMask.size] does not apply.
  linear,
}

/// A shape a layer shows through, drawn by the renderer on every frame, so it
/// can move, grow, turn and soften over time on its own (see [keyframes]).
///
/// Everything is measured in fractions of the masked image: the layer's own
/// box for an [ImageLayer] — its image as it is drawn, before its placement,
/// keyframes and animations — and each clip's own upright source frame for a
/// `VideoLayer`, as its `mask` is. The shape therefore still moves, scales
/// and turns with the layer as well.
///
/// The mask decides how much of the layer shows at every point: all of it
/// inside the shape, nothing outside, and part of it across a [feather]ed
/// edge. [invert] swaps inside and outside.
///
/// ```dart
/// // A circle that opens up from the middle of a clip over its first second.
/// LayerShapeMask(
///   shape: LayerShapeMaskShape.ellipse,
///   keyframes: [
///     LayerShapeMaskKeyframe(time: Duration.zero, size: Size.zero),
///     LayerShapeMaskKeyframe(
///       time: Duration(seconds: 1),
///       size: Size(1.5, 1.5),
///       feather: 0.05,
///       curve: AnimationCurve.easeOut,
///     ),
///   ],
/// );
/// ```
///
/// **Note:** Ignored on Web, Windows and Linux, which have no render
/// pipeline.
@immutable
class LayerShapeMask {
  /// Creates a [LayerShapeMask].
  const LayerShapeMask({
    required this.shape,
    this.center = const Offset(0.5, 0.5),
    this.size = const Size(0.5, 0.5),
    this.rotation = 0,
    this.feather = 0,
    this.cornerRadius = 0,
    this.invert = false,
    this.mirrored = false,
    this.keyframes = const [],
  }) : assert(feather >= 0, '[feather] must not be negative'),
       assert(
         cornerRadius >= 0 && cornerRadius <= 1,
         '[cornerRadius] must be between 0 and 1',
       );

  /// Creates a [LayerShapeMask] from a map written by [toMap].
  ///
  /// A shape this version does not know falls back to
  /// [LayerShapeMaskShape.ellipse].
  factory LayerShapeMask.fromMap(Map<String, dynamic> map) {
    final shapeName = map['shape'];
    return LayerShapeMask(
      shape: LayerShapeMaskShape.values.firstWhere(
        (shape) => shape.name == shapeName,
        orElse: () => LayerShapeMaskShape.ellipse,
      ),
      center: Offset(
        safeParseDouble(map['x'], fallback: 0.5),
        safeParseDouble(map['y'], fallback: 0.5),
      ),
      size: Size(
        safeParseDouble(map['width'], fallback: 0.5),
        safeParseDouble(map['height'], fallback: 0.5),
      ),
      rotation: safeParseDouble(map['rotation']),
      feather: math.max(0.0, safeParseDouble(map['feather'])),
      cornerRadius: safeParseDouble(map['cornerRadius']).clamp(0.0, 1.0),
      invert: map['invert'] == true,
      mirrored: map['mirrored'] == true,
      keyframes: sortLayerShapeMaskKeyframes([
        for (final keyframe in map['keyframes'] as List? ?? const [])
          if (keyframe is Map)
            LayerShapeMaskKeyframe.fromMap(Map<String, dynamic>.from(keyframe)),
      ]),
    );
  }

  /// The shape the layer shows through.
  final LayerShapeMaskShape shape;

  /// The centre of the shape, in fractions of the masked image: `(0, 0)` is
  /// its top-left corner and `(1, 1)` its bottom-right one.
  final Offset center;

  /// The size of the shape's box before it is turned, in fractions of the
  /// masked image: `Size(1, 1)` is as large as the image.
  ///
  /// Not used by [LayerShapeMaskShape.linear].
  final Size size;

  /// How far the shape is turned around [center], clockwise, in radians.
  final double rotation;

  /// How soft the edge is, in fractions of the shorter side of the masked
  /// image.
  ///
  /// The layer fades out over about this distance across the edge: a Gaussian
  /// with a standard deviation of `feather * shortestSide / 2.56`, or for a
  /// [LayerShapeMaskShape.linear] edge a straight gradient this wide. `0` is
  /// a hard edge.
  final double feather;

  /// How round the corners of a [LayerShapeMaskShape.rectangle] are, from `0`
  /// (square) to `1` (a radius of half the shorter side of its box).
  final double cornerRadius;

  /// Whether the layer shows outside the shape instead of inside it.
  final bool invert;

  /// Whether the shape is mirrored across the vertical line through its
  /// centre before it is turned, as on a layer that is flipped.
  final bool mirrored;

  /// How the shape changes over time.
  ///
  /// When not empty, the keyframes set the [center], [size], [rotation] and
  /// [feather] on every frame, and the mask's own values do not apply; the
  /// shape, its corners, [invert] and [mirrored] stay. Their times are on the
  /// layer's keyframe timeline: the timeline of its start and end time, or
  /// its keyframe clock when it has one (see [KeyframeClockPoint]). They need
  /// not be in order.
  final List<LayerShapeMaskKeyframe> keyframes;

  /// Converts this mask to a map, as the native renderers read it.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'shape': shape.name,
    'x': center.dx,
    'y': center.dy,
    'width': size.width,
    'height': size.height,
    'rotation': rotation,
    'feather': feather,
    'cornerRadius': cornerRadius,
    'invert': invert,
    'mirrored': mirrored,
    'keyframes': sortLayerShapeMaskKeyframes(
      keyframes,
    ).map((k) => k.toMap()).toList(),
  };

  /// Creates a copy with the given fields replaced.
  LayerShapeMask copyWith({
    LayerShapeMaskShape? shape,
    Offset? center,
    Size? size,
    double? rotation,
    double? feather,
    double? cornerRadius,
    bool? invert,
    bool? mirrored,
    List<LayerShapeMaskKeyframe>? keyframes,
  }) {
    return LayerShapeMask(
      shape: shape ?? this.shape,
      center: center ?? this.center,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      feather: feather ?? this.feather,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      invert: invert ?? this.invert,
      mirrored: mirrored ?? this.mirrored,
      keyframes: keyframes ?? this.keyframes,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LayerShapeMask &&
        other.shape == shape &&
        other.center == center &&
        other.size == size &&
        other.rotation == rotation &&
        other.feather == feather &&
        other.cornerRadius == cornerRadius &&
        other.invert == invert &&
        other.mirrored == mirrored &&
        listEquals(other.keyframes, keyframes);
  }

  @override
  int get hashCode => Object.hash(
    shape,
    center,
    size,
    rotation,
    feather,
    cornerRadius,
    invert,
    mirrored,
    Object.hashAll(keyframes),
  );

  @override
  String toString() =>
      'LayerShapeMask(shape: ${shape.name}, center: $center, size: $size, '
      'rotation: $rotation, feather: $feather, cornerRadius: $cornerRadius, '
      'invert: $invert, mirrored: $mirrored, keyframes: $keyframes)';
}

/// Where a [LayerShapeMask]'s shape is, how big it is, how far it is turned
/// and how soft its edge is at one point of the layer's keyframe timeline.
///
/// Before the first keyframe the mask holds the first one's values, after the
/// last one the last one's, and between two of them it travels from the
/// earlier to the later one along the earlier one's [curve], eased like a
/// [LayerAnimation]. An elastic or bounce curve may overshoot either
/// keyframe; only the size and the softness are kept at 0 or more.
///
/// Mirrors the `LayerMaskKeyframe` of the sister package `pro_image_editor`.
@immutable
class LayerShapeMaskKeyframe {
  /// Creates a [LayerShapeMaskKeyframe].
  const LayerShapeMaskKeyframe({
    required this.time,
    this.center = const Offset(0.5, 0.5),
    this.size = const Size(0.5, 0.5),
    this.rotation = 0,
    this.feather = 0,
    this.curve = AnimationCurve.linear,
  }) : assert(feather >= 0, '[feather] must not be negative');

  /// Creates a [LayerShapeMaskKeyframe] from a map written by [toMap].
  factory LayerShapeMaskKeyframe.fromMap(Map<String, dynamic> map) {
    final curveName = map['curve'];
    return LayerShapeMaskKeyframe(
      time: Duration(microseconds: safeParseInt(map['timeUs'])),
      center: Offset(
        safeParseDouble(map['x'], fallback: 0.5),
        safeParseDouble(map['y'], fallback: 0.5),
      ),
      size: Size(
        safeParseDouble(map['width'], fallback: 0.5),
        safeParseDouble(map['height'], fallback: 0.5),
      ),
      rotation: safeParseDouble(map['rotation']),
      feather: math.max(0.0, safeParseDouble(map['feather'])),
      curve: AnimationCurve.values.firstWhere(
        (curve) => curve.name == curveName,
        orElse: () => AnimationCurve.linear,
      ),
    );
  }

  /// When the values apply, on the layer's keyframe timeline (see
  /// [LayerShapeMask.keyframes]).
  final Duration time;

  /// The centre of the shape, like [LayerShapeMask.center].
  final Offset center;

  /// The size of the shape's box, like [LayerShapeMask.size].
  final Size size;

  /// How far the shape is turned, like [LayerShapeMask.rotation].
  ///
  /// The shape turns the whole difference to the next keyframe, so going from
  /// `0` to `2 * pi` is a full turn rather than staying still.
  final double rotation;

  /// How soft the edge is, like [LayerShapeMask.feather].
  final double feather;

  /// How the mask travels from this keyframe to the next one.
  final AnimationCurve curve;

  /// Converts this keyframe to a map, as the native renderers read it.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'timeUs': time.inMicroseconds,
    'x': center.dx,
    'y': center.dy,
    'width': size.width,
    'height': size.height,
    'rotation': rotation,
    'feather': feather,
    'curve': curve.name,
  };

  /// Creates a copy with the given fields replaced.
  LayerShapeMaskKeyframe copyWith({
    Duration? time,
    Offset? center,
    Size? size,
    double? rotation,
    double? feather,
    AnimationCurve? curve,
  }) {
    return LayerShapeMaskKeyframe(
      time: time ?? this.time,
      center: center ?? this.center,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      feather: feather ?? this.feather,
      curve: curve ?? this.curve,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LayerShapeMaskKeyframe &&
        other.time == time &&
        other.center == center &&
        other.size == size &&
        other.rotation == rotation &&
        other.feather == feather &&
        other.curve == curve;
  }

  @override
  int get hashCode => Object.hash(time, center, size, rotation, feather, curve);

  @override
  String toString() =>
      'LayerShapeMaskKeyframe(time: $time, center: $center, size: $size, '
      'rotation: $rotation, feather: $feather, curve: $curve)';
}

/// [keyframes] sorted by [LayerShapeMaskKeyframe.time], as a new list. Ties
/// keep their order.
List<LayerShapeMaskKeyframe> sortLayerShapeMaskKeyframes(
  Iterable<LayerShapeMaskKeyframe> keyframes,
) {
  final sorted = keyframes.toList();
  mergeSort(sorted, compare: (a, b) => a.time.compareTo(b.time));
  return sorted;
}
