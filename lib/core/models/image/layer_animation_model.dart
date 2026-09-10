// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:ui';

import 'package:pro_video_editor/shared/utils/parser/offset_parser.dart';

import 'image_layer_model.dart';

/// The type of animation to apply to an image layer.
enum LayerAnimationType {
  /// Fade opacity from 0 to 1 (in) or 1 to 0 (out).
  fade,

  /// Slide the layer in/out from a direction.
  slide,

  /// Scale the layer from small to full size (in) or full to small (out).
  scale,
}

/// Slide direction for slide animations.
enum SlideDirection {
  /// Slide from/to the left edge.
  left,

  /// Slide from/to the right edge.
  right,

  /// Slide from/to the top edge.
  top,

  /// Slide from/to the bottom edge.
  bottom,
}

/// Easing curve for animation timing.
enum AnimationCurve {
  /// Constant speed from start to end.
  linear,

  /// Starts slow, accelerates (quadratic).
  easeIn,

  /// Starts fast, decelerates (quadratic).
  easeOut,

  /// Starts slow, accelerates, then decelerates (quadratic).
  easeInOut,

  /// Starts slow, accelerates (cubic – smoother than [easeIn]).
  easeInCubic,

  /// Starts fast, decelerates (cubic – smoother than [easeOut]).
  easeOutCubic,

  /// Starts slow, accelerates, then decelerates (cubic).
  easeInOutCubic,

  /// Bounces at the start before settling.
  bounceIn,

  /// Bounces at the end like a ball hitting the ground.
  bounceOut,

  /// Bounces at both the start and end.
  bounceInOut,

  /// Overshoots at the start and springs forward.
  elasticIn,

  /// Overshoots the target and springs back.
  elasticOut,

  /// Elastic spring effect at both start and end.
  elasticInOut,
}

/// Whether the animation plays at the start, end, or both ends of the layer's
/// time range.
enum AnimationPhase {
  /// Animation plays at the beginning of the layer's visible range.
  animateIn,

  /// Animation plays at the end of the layer's visible range.
  animateOut,

  /// Animation plays at both the beginning and end using the same duration.
  animateInOut,
}

/// A single animation applied to an [ImageLayer].
///
/// Multiple animations can be combined on one layer, e.g. a
/// [LayerAnimationType.fade] in together with a [LayerAnimationType.slide] in
/// from the left.
///
/// Example:
/// ```dart
/// ImageLayer(
///   image: myImage,
///   startTime: Duration.zero,
///   endTime: const Duration(seconds: 10),
///   animations: [
///     LayerAnimation(
///       type: LayerAnimationType.fade,
///       phase: AnimationPhase.animateIn,
///       duration: const Duration(milliseconds: 500),
///     ),
///     LayerAnimation(
///       type: LayerAnimationType.fade,
///       phase: AnimationPhase.animateOut,
///       duration: const Duration(milliseconds: 300),
///     ),
///     LayerAnimation(
///       type: LayerAnimationType.slide,
///       phase: AnimationPhase.animateIn,
///       duration: const Duration(milliseconds: 400),
///       slideDirection: SlideDirection.left,
///       curve: AnimationCurve.easeOut,
///     ),
///   ],
/// )
/// ```
///
/// A slide can start from a point of your own instead of a canvas edge — the
/// layer below comes in diagonally from beyond the top-left corner:
///
/// ```dart
/// LayerAnimation(
///   type: LayerAnimationType.slide,
///   phase: AnimationPhase.animateIn,
///   duration: const Duration(milliseconds: 600),
///   slideFrom: const Offset(-200, -200),
///   curve: AnimationCurve.easeOutCubic,
/// )
/// ```
class LayerAnimation {
  /// Creates a [LayerAnimation].
  const LayerAnimation({
    required this.type,
    required this.phase,
    required this.duration,
    this.curve = AnimationCurve.linear,
    this.slideDirection,
    this.slideFrom,
    this.scaleFrom,
  }) : assert(
         type != LayerAnimationType.slide ||
             slideDirection != null ||
             slideFrom != null,
         'slide animations need either a slideDirection or a slideFrom point',
       );

  /// The kind of animation (fade, slide, scale).
  final LayerAnimationType type;

  /// Whether this animation plays at the start or end of the layer.
  final AnimationPhase phase;

  /// How long the animation lasts.
  final Duration duration;

  /// The easing curve for the animation.
  ///
  /// Defaults to [AnimationCurve.linear].
  final AnimationCurve curve;

  /// The direction for [LayerAnimationType.slide] animations.
  ///
  /// The layer travels between its resting place and the canvas edge in this
  /// direction, far enough to sit completely outside the frame.
  ///
  /// Required when [type] is [LayerAnimationType.slide], unless [slideFrom]
  /// names a start point instead.
  final SlideDirection? slideDirection;

  /// A custom start point for [LayerAnimationType.slide] animations, in
  /// pixels.
  ///
  /// Uses the same coordinate system as [ImageLayer.offset]: the layer's
  /// top-left corner measured from the top-left of the video frame. The layer
  /// starts here and slides to its resting [ImageLayer.offset]
  /// ([AnimationPhase.animateIn]), or leaves its resting place for this point
  /// ([AnimationPhase.animateOut]). With [AnimationPhase.animateInOut] the
  /// point is both: the layer enters from it and leaves back towards it.
  ///
  /// Values may sit outside the frame — `Offset(-500, 800)` starts the layer
  /// 500px past the left edge. A layer without an [ImageLayer.offset] is
  /// stretched over the frame and rests at `Offset.zero`.
  ///
  /// Overrides [slideDirection] when both are set.
  final Offset? slideFrom;

  /// The starting scale factor for [LayerAnimationType.scale] animations.
  ///
  /// Defaults to `0.0` (invisible) on the native side if not set.
  /// A value of `0.5` means the layer starts at half size.
  final double? scaleFrom;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'phase': phase.name,
      'durationUs': duration.inMicroseconds,
      'curve': curve.name,
      'slideDirection': slideDirection?.name,
      'slideFrom': slideFrom != null
          ? {'dx': slideFrom!.dx, 'dy': slideFrom!.dy}
          : null,
      'scaleFrom': scaleFrom,
    };
  }

  factory LayerAnimation.fromMap(Map<String, dynamic> map) {
    return LayerAnimation(
      type: LayerAnimationType.values.byName(map['type'] as String),
      phase: AnimationPhase.values.byName(map['phase'] as String),
      duration: Duration(microseconds: map['durationUs'] as int),
      curve: AnimationCurve.values.byName(
        (map['curve'] as String?) ?? 'linear',
      ),
      slideDirection: map['slideDirection'] != null
          ? SlideDirection.values.byName(map['slideDirection'] as String)
          : null,
      slideFrom: map['slideFrom'] != null
          ? safeParseOffset(map['slideFrom'] as Map<String, dynamic>)
          : null,
      scaleFrom: map['scaleFrom'] as double?,
    );
  }

  @override
  String toString() {
    return 'LayerAnimation(type: $type, phase: $phase, '
        'duration: $duration, curve: $curve'
        '${slideDirection != null ? ', slideDirection: $slideDirection' : ''}'
        '${slideFrom != null ? ', slideFrom: $slideFrom' : ''}'
        '${scaleFrom != null ? ', scaleFrom: $scaleFrom' : ''})';
  }

  @override
  bool operator ==(covariant LayerAnimation other) {
    if (identical(this, other)) return true;
    return other.type == type &&
        other.phase == phase &&
        other.duration == duration &&
        other.curve == curve &&
        other.slideDirection == slideDirection &&
        other.slideFrom == slideFrom &&
        other.scaleFrom == scaleFrom;
  }

  @override
  int get hashCode {
    return type.hashCode ^
        phase.hashCode ^
        duration.hashCode ^
        curve.hashCode ^
        slideDirection.hashCode ^
        slideFrom.hashCode ^
        scaleFrom.hashCode;
  }
}
