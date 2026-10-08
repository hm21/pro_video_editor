// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:ui';

import 'package:pro_video_editor/shared/utils/parser/offset_parser.dart';

import 'image_layer_model.dart';

/// The type of animation to apply to an image layer.
///
/// Every type moves the layer away from its resting state by an amount that
/// follows the animation's progress: fully away at the start of an
/// [AnimationPhase.animateIn], at rest once it ends, and back again over an
/// [AnimationPhase.animateOut]. [AnimationPhase.loop] swings between the two
/// over and over.
enum LayerAnimationType {
  /// Fade opacity from 0 to 1 (in) or 1 to 0 (out).
  fade,

  /// Slide the layer in/out from a direction.
  slide,

  /// Scale the layer from small to full size (in) or full to small (out).
  scale,

  /// Tilt the layer around its center by up to [LayerAnimation.wiggleAngle].
  ///
  /// In and out, the layer turns between the tilted and the upright position;
  /// an elastic or bounce [AnimationCurve] makes it wobble into place. In a
  /// [AnimationPhase.loop] it tilts to one side and then to the other within
  /// every cycle, so it wiggles for as long as it is visible.
  wiggle,

  /// Lift the layer by [LayerAnimation.bounceHeight] times its own height.
  ///
  /// In, the layer drops onto its resting place, out it rises from it; a
  /// bounce [AnimationCurve] makes it bounce on landing. In a
  /// [AnimationPhase.loop] it hops up and lands once per cycle.
  bounce,

  /// Reveal a text letter by letter (in), or take it away from the last
  /// letter back (out).
  ///
  /// The renderer draws an [ImageLayer] as one fixed image, so it cannot
  /// reveal the text inside it and skips this type. An app shows the reveal by
  /// passing one layer per step with the text revealed so far, all sharing the
  /// same [ImageLayer.animationStartTime] and [ImageLayer.animationEndTime];
  /// `pro_image_editor` captures exactly those images for a text layer. The
  /// type exists here so a layer's animations convert between the two
  /// packages unchanged.
  typewriter,

  /// Reveal a text word by word (in), or take it away from the last word back
  /// (out).
  ///
  /// Skipped by the renderer for the same reason as [typewriter].
  wordByWord,
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
/// time range, or repeats throughout it.
enum AnimationPhase {
  /// Animation plays at the beginning of the layer's visible range.
  animateIn,

  /// Animation plays at the end of the layer's visible range.
  animateOut,

  /// Animation plays at both the beginning and end using the same duration.
  animateInOut,

  /// Animation repeats for as long as the layer is visible, one cycle every
  /// [LayerAnimation.duration], counted from the start of the layer (or from
  /// [ImageLayer.animationStartTime]).
  ///
  /// Each cycle leaves the resting state and comes back to it: halfway
  /// through, a fade has the layer invisible, a scale has it at
  /// [LayerAnimation.scaleFrom] and a slide has it at the edge or the
  /// [LayerAnimation.slideFrom] point. A [LayerAnimationType.wiggle] tilts to
  /// one side in the first half of the cycle and to the other in the second.
  ///
  /// The [LayerAnimation.curve] shapes the way out like an [animateOut] and
  /// the way back like an [animateIn]: with [AnimationCurve.easeIn] the layer
  /// moves fastest at rest and slowest at the turning point, like a pendulum
  /// or a hop.
  loop,
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
///
/// A [AnimationPhase.loop] keeps a layer moving while it is on screen — this
/// one wiggles by up to 8° each side, twice a second:
///
/// ```dart
/// LayerAnimation(
///   type: LayerAnimationType.wiggle,
///   phase: AnimationPhase.loop,
///   duration: const Duration(milliseconds: 500),
///   curve: AnimationCurve.easeIn,
///   wiggleAngle: 8 * math.pi / 180,
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
    this.wiggleAngle,
    this.bounceHeight,
    this.loopStart,
    this.loopEnd,
    this.loopPhase,
  }) : assert(
         type != LayerAnimationType.slide ||
             slideDirection != null ||
             slideFrom != null,
         'slide animations need either a slideDirection or a slideFrom point',
       ),
       assert(
         phase == AnimationPhase.loop ||
             (loopStart == null && loopEnd == null && loopPhase == null),
         'only a loop repeats between loopStart and loopEnd from loopPhase',
       );

  /// How far a [LayerAnimationType.wiggle] tilts when [wiggleAngle] is not
  /// set: 10°, in radians.
  static const double defaultWiggleAngle = 0.17453292519943295;

  /// How high a [LayerAnimationType.bounce] lifts the layer when
  /// [bounceHeight] is not set: half its own height.
  static const double defaultBounceHeight = 0.5;

  /// The kind of animation (fade, slide, scale, wiggle, bounce, ...).
  final LayerAnimationType type;

  /// Whether this animation plays at the start or end of the layer, or
  /// repeats while it is visible.
  final AnimationPhase phase;

  /// How long the animation lasts, or one cycle of a [AnimationPhase.loop].
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

  /// How far a [LayerAnimationType.wiggle] tilts the layer, in **radians**.
  ///
  /// Positive values tilt clockwise first, like [ImageLayer.rotation].
  /// Defaults to [defaultWiggleAngle] when not set.
  final double? wiggleAngle;

  /// How high a [LayerAnimationType.bounce] lifts the layer, as a multiple of
  /// the layer's own height: `0.5` lifts it by half its height. A layer turned
  /// by [ImageLayer.rotation] counts the height of the box around it.
  ///
  /// Defaults to [defaultBounceHeight] when not set.
  final double? bounceHeight;

  /// Where a [AnimationPhase.loop] starts repeating, on the output timeline
  /// like [ImageLayer.startTime]. It counts its cycles from here and does not
  /// play before it.
  ///
  /// `null` repeats from the layer's own start. Together with [loopEnd] a
  /// loop can play over part of a layer only, such as the stretch between two
  /// [ImageLayer.keyframes]: a [duration] that fits a whole number of cycles
  /// between the two leaves the layer at rest on both.
  final Duration? loopStart;

  /// Where a [AnimationPhase.loop] stops, on the output timeline like
  /// [ImageLayer.endTime]; it does not play from here on. `null` repeats to
  /// the layer's own end. Comes after [loopStart] when both are set.
  final Duration? loopEnd;

  /// How far into its cycle a [AnimationPhase.loop] already is where it
  /// starts, at [loopStart] or the layer's own start; it plays on from there
  /// instead of from rest. Between zero and [duration].
  ///
  /// Lets one loop be split into parts that each repeat at their own pace,
  /// such as where a clip transition plays the timeline faster, and still run
  /// on in step from one part to the next. `null` starts at rest.
  final Duration? loopPhase;

  Map<String, dynamic> toMap() {
    // Checked here: Durations cannot be compared in a const constructor.
    assert(
      loopStart == null || loopEnd == null || loopStart! < loopEnd!,
      'loopStart must be before loopEnd',
    );
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
      'wiggleAngle': wiggleAngle,
      'bounceHeight': bounceHeight,
      'loopStartUs': loopStart?.inMicroseconds,
      'loopEndUs': loopEnd?.inMicroseconds,
      'loopPhaseUs': loopPhase?.inMicroseconds,
    };
  }

  factory LayerAnimation.fromMap(Map<String, dynamic> map) {
    return LayerAnimation(
      type: LayerAnimationType.values.byName(map['type'] as String),
      phase: AnimationPhase.values.byName(map['phase'] as String),
      duration: Duration(microseconds: (map['durationUs'] as num).toInt()),
      curve: AnimationCurve.values.byName(
        (map['curve'] as String?) ?? 'linear',
      ),
      slideDirection: map['slideDirection'] != null
          ? SlideDirection.values.byName(map['slideDirection'] as String)
          : null,
      slideFrom: map['slideFrom'] != null
          ? safeParseOffset(map['slideFrom'] as Map<String, dynamic>)
          : null,
      scaleFrom: (map['scaleFrom'] as num?)?.toDouble(),
      wiggleAngle: (map['wiggleAngle'] as num?)?.toDouble(),
      bounceHeight: (map['bounceHeight'] as num?)?.toDouble(),
      loopStart: map['loopStartUs'] != null
          ? Duration(microseconds: (map['loopStartUs'] as num).toInt())
          : null,
      loopEnd: map['loopEndUs'] != null
          ? Duration(microseconds: (map['loopEndUs'] as num).toInt())
          : null,
      loopPhase: map['loopPhaseUs'] != null
          ? Duration(microseconds: (map['loopPhaseUs'] as num).toInt())
          : null,
    );
  }

  @override
  String toString() {
    return 'LayerAnimation(type: $type, phase: $phase, '
        'duration: $duration, curve: $curve'
        '${slideDirection != null ? ', slideDirection: $slideDirection' : ''}'
        '${slideFrom != null ? ', slideFrom: $slideFrom' : ''}'
        '${scaleFrom != null ? ', scaleFrom: $scaleFrom' : ''}'
        '${wiggleAngle != null ? ', wiggleAngle: $wiggleAngle' : ''}'
        '${bounceHeight != null ? ', bounceHeight: $bounceHeight' : ''}'
        '${loopStart != null ? ', loopStart: $loopStart' : ''}'
        '${loopEnd != null ? ', loopEnd: $loopEnd' : ''}'
        '${loopPhase != null ? ', loopPhase: $loopPhase' : ''})';
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
        other.scaleFrom == scaleFrom &&
        other.wiggleAngle == wiggleAngle &&
        other.bounceHeight == bounceHeight &&
        other.loopStart == loopStart &&
        other.loopEnd == loopEnd &&
        other.loopPhase == loopPhase;
  }

  @override
  int get hashCode {
    return type.hashCode ^
        phase.hashCode ^
        duration.hashCode ^
        curve.hashCode ^
        slideDirection.hashCode ^
        slideFrom.hashCode ^
        scaleFrom.hashCode ^
        wiggleAngle.hashCode ^
        bounceHeight.hashCode ^
        loopStart.hashCode ^
        loopEnd.hashCode ^
        loopPhase.hashCode;
  }
}
