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
/// over and over; a [spin] and a [flip] keep turning instead.
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

  /// Turn the layer around its center by [LayerAnimation.turns] full turns.
  ///
  /// In, the layer turns into place, out it turns away from it, both
  /// clockwise for a positive [LayerAnimation.turns]. In a
  /// [AnimationPhase.loop] it keeps turning the same way, by
  /// [LayerAnimation.turns] every cycle; with [AnimationCurve.linear] it
  /// turns at an even pace without stopping.
  spin,

  /// Turn the layer around its vertical or horizontal axis like a card, by
  /// [LayerAnimation.turns] full turns; see [LayerAnimation.flipAxis].
  ///
  /// The layer is drawn flat, so the turn shows as a squeeze across the axis:
  /// to nothing at a quarter turn and to a mirror image at half a turn. A
  /// quarter turn in starts edge-on, where nothing shows, and turns the layer
  /// to face the viewer; full turns flip it over that often. In a
  /// [AnimationPhase.loop] it keeps turning, by [LayerAnimation.turns] every
  /// cycle, like a [spin].
  ///
  /// The squeeze follows the image the layer draws, before
  /// [ImageLayer.keyframes], a [spin] and a [wiggle] turn it. A layer turned
  /// by [ImageLayer.rotation] draws its image turned, so it is squeezed across
  /// the frame's axis; one with keyframes is squeezed across its own, as the
  /// keyframes turn it, and on Android so is one with an
  /// [ImageLayer.shapeMask], which is drawn upright and turned afterwards.
  flip,
}

/// The axis a [LayerAnimationType.flip] turns a layer around.
enum FlipAxis {
  /// Turn around the vertical axis: the layer turns sideways, its left and
  /// right edges trading places.
  vertical,

  /// Turn around the horizontal axis: the layer turns over, its top and
  /// bottom edges trading places.
  horizontal,
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
  ///
  /// A [LayerAnimationType.spin] and a [LayerAnimationType.flip] do not turn
  /// back: they turn on by [LayerAnimation.turns] every cycle, which the
  /// [LayerAnimation.curve] eases from start to end, so each cycle picks up
  /// where the last one stopped.
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
///
/// A spinning loop keeps a sticker such as a record turning at an even pace,
/// once every two seconds:
///
/// ```dart
/// LayerAnimation(
///   type: LayerAnimationType.spin,
///   phase: AnimationPhase.loop,
///   duration: const Duration(seconds: 2),
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
    this.turns,
    this.flipAxis,
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
         'loopStart, loopEnd and loopPhase only apply to a loop',
       );

  /// How far a [LayerAnimationType.wiggle] tilts when [wiggleAngle] is not
  /// set: 10°, in radians.
  static const double defaultWiggleAngle = 0.17453292519943295;

  /// How high a [LayerAnimationType.bounce] lifts the layer when
  /// [bounceHeight] is not set: half its own height.
  static const double defaultBounceHeight = 0.5;

  /// How far a [LayerAnimationType.spin] or [LayerAnimationType.flip] turns
  /// the layer when [turns] is not set: once all the way round.
  static const double defaultTurns = 1;

  /// The kind of animation (fade, slide, scale, wiggle, bounce, spin, ...).
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

  /// How far a [LayerAnimationType.spin] or [LayerAnimationType.flip] turns
  /// the layer, in full turns: `1` once all the way round, `0.25` a quarter
  /// of the way. In a [AnimationPhase.loop] this is how far it turns in one
  /// cycle.
  ///
  /// A spin turns clockwise for a positive value, like [ImageLayer.rotation],
  /// and counter-clockwise for a negative one; a flip looks the same either
  /// way. Defaults to [defaultTurns] when not set.
  final double? turns;

  /// The axis a [LayerAnimationType.flip] turns the layer around.
  ///
  /// Defaults to [FlipAxis.vertical] when not set.
  final FlipAxis? flipAxis;

  /// Where a [AnimationPhase.loop] starts repeating, on the output timeline
  /// like [ImageLayer.startTime]. It counts its cycles from here and does not
  /// play before it.
  ///
  /// `null` repeats from the layer's own start. Together with [loopEnd] a
  /// loop can play over part of a layer only, such as the stretch between two
  /// [ImageLayer.keyframes]: a [duration] that fits a whole number of cycles
  /// between the two leaves the layer at rest on both. On a layer with an
  /// [ImageLayer.keyframeClock], that stretch starts and ends where the clock
  /// reaches the two keyframes on the output timeline, not at their own times.
  final Duration? loopStart;

  /// Where a [AnimationPhase.loop] stops, on the output timeline like
  /// [ImageLayer.endTime]; it does not play from here on. `null` repeats to
  /// the layer's own end. Comes after [loopStart] when both are set.
  final Duration? loopEnd;

  /// How far into its cycle a [AnimationPhase.loop] already is where it
  /// starts, at [loopStart] or the layer's own start; it plays on from there
  /// instead of from rest. Not negative; a phase of [duration] or more wraps
  /// round into the cycle.
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
    assert(
      loopPhase == null || !loopPhase!.isNegative,
      'loopPhase must not be negative',
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
      'turns': turns,
      'flipAxis': flipAxis?.name,
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
      turns: (map['turns'] as num?)?.toDouble(),
      flipAxis: map['flipAxis'] != null
          ? FlipAxis.values.byName(map['flipAxis'] as String)
          : null,
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
        '${turns != null ? ', turns: $turns' : ''}'
        '${flipAxis != null ? ', flipAxis: $flipAxis' : ''}'
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
        other.turns == turns &&
        other.flipAxis == flipAxis &&
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
        turns.hashCode ^
        flipAxis.hashCode ^
        loopStart.hashCode ^
        loopEnd.hashCode ^
        loopPhase.hashCode;
  }
}
