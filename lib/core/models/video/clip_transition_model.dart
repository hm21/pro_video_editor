// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'package:pro_video_editor/core/models/image/layer_animation_model.dart';
import 'package:pro_video_editor/shared/utils/parser/int_parser.dart';

/// The type of transition to play between two adjacent video clips.
///
/// Transitions fall into two families with different timeline behavior:
///
/// **Overlap transitions** — the two clips overlap and blend during the
/// transition, so the total output is **shortened** by
/// [ClipTransition.duration] per transition (e.g. two 5s clips + 1s transition
/// = 9s). Every type except [fadeToBlack] and [fadeToWhite] is one; see
/// [isOverlap].
///
/// **Dip transitions** — the dip happens within the clips' own time at the
/// boundary, so the total duration is **unchanged**. These are [fadeToBlack]
/// and [fadeToWhite]; see [isDip].
///
/// Below, *progress* is the transition's progress after its
/// [ClipTransition.curve], from 0 (only the outgoing clip) to 1 (only the
/// incoming clip). An elastic curve overshoots that range; movement follows
/// the overshoot, while opacity, blur and flash stay within it.
enum ClipTransitionType {
  /// A true cross-dissolve: the two clips overlap and the outgoing clip fades
  /// out while the incoming clip fades in (blend). Overlap transition.
  dissolve,

  /// A dip-to-black: the outgoing clip fades to black over the first half of
  /// the transition and the incoming clip fades up from black over the second
  /// half. Dip transition (duration unchanged).
  fadeToBlack,

  /// A dip-to-white: like [fadeToBlack] but dips through white instead of
  /// black. Dip transition (duration unchanged).
  fadeToWhite,

  /// The incoming clip slides in over the (stationary) outgoing clip in the
  /// configured [ClipTransition.direction]. Overlap transition.
  slide,

  /// The incoming clip pushes the outgoing clip out of frame — both move
  /// together in the configured [ClipTransition.direction]. Overlap
  /// transition.
  push,

  /// A linear wipe: the incoming clip is progressively revealed over the
  /// outgoing clip along the configured [ClipTransition.direction]. Overlap
  /// transition.
  wipe,

  /// The camera flies into the outgoing clip, which zooms in from 1× to 1.5×,
  /// while the incoming clip grows out of the center from nothing to full
  /// size (its scale is the progress) and is fully opaque by 40 % progress.
  /// Overlap transition.
  zoomIn,

  /// The reverse of [zoomIn]: the outgoing clip shrinks into the center (its
  /// scale is one minus the progress) and fades out over the last 40 %,
  /// uncovering the incoming clip, which zooms out from 1.5× to 1×. Overlap
  /// transition.
  zoomOut,

  /// Both clips turn clockwise about the center: the outgoing clip from 0° to
  /// 180°, the incoming clip from -180° to 0°, each zoomed just far enough to
  /// keep the frame covered. The picture changes clip between 35 % and 65 %
  /// progress. Overlap transition.
  spin,

  /// A [push] with motion blur along the configured
  /// [ClipTransition.direction]. The blur is a box a quarter of the frame long
  /// at mid-transition and fades to none at either end. Overlap transition.
  whipPan,

  /// The picture blurs out and back in, changing clip between 30 % and 70 %
  /// progress. The blur radius is 5 % of the frame's shorter side at
  /// mid-transition and fades to none at either end. Overlap transition.
  blur,

  /// A digital glitch: the picture cuts to the incoming clip halfway through,
  /// while slices of it jump sideways — some showing the other clip — and its
  /// red and blue channels split apart, most strongly at mid-transition. The
  /// pattern changes 15 times a second. Overlap transition.
  glitch,

  /// A flash of white light: the picture cuts to the incoming clip at its
  /// peak, halfway through, where it is fully white.
  ///
  /// It flashes once. Flashes closer than a third of a second apart, from
  /// flash transitions or flashing video effects, exceed the three flashes a
  /// second that WCAG 2.3.1 allows; see [flashes]. Overlap transition.
  flash,

  /// A circle reveal: the incoming clip appears inside a circle that grows
  /// from the center until, at full progress, it reaches the corners. Overlap
  /// transition.
  iris,

  /// The incoming clip stretches in from the edge opposite the configured
  /// [ClipTransition.direction] while the outgoing clip is squeezed toward
  /// it; together they always fill the frame. The incoming clip's share of
  /// the frame is the progress. Overlap transition.
  stretch;

  /// Whether the transition dips through a color within the clips' own time
  /// ([fadeToBlack], [fadeToWhite]), leaving the output duration unchanged.
  bool get isDip => this == fadeToBlack || this == fadeToWhite;

  /// Whether the two clips overlap and blend, shortening the output by the
  /// transition's duration. Every type that is not [isDip].
  bool get isOverlap => !isDip;

  /// Whether [ClipTransition.direction] changes the transition.
  bool get usesDirection =>
      this == slide ||
      this == push ||
      this == wipe ||
      this == whipPan ||
      this == stretch;

  /// Whether the transition flashes: [flash] flashes once, at its midpoint.
  ///
  /// More than three flashes in any second can trigger seizures (WCAG 2.3.1),
  /// so space flashing transitions, and the flashing video effects near them,
  /// accordingly.
  bool get flashes => this == flash;
}

/// Direction for directional transitions ([ClipTransitionType.slide],
/// [ClipTransitionType.push], [ClipTransitionType.wipe],
/// [ClipTransitionType.whipPan], [ClipTransitionType.stretch]); see
/// [ClipTransitionType.usesDirection].
///
/// The direction describes where the incoming content travels **toward** as
/// the transition progresses. For example [left] means the incoming clip
/// enters from the right edge and moves left; for a [ClipTransitionType.wipe]
/// it means the reveal edge sweeps toward the left.
enum ClipTransitionDirection {
  /// Motion toward the left edge (incoming enters from the right).
  left,

  /// Motion toward the right edge (incoming enters from the left).
  right,

  /// Motion toward the top edge (incoming enters from the bottom).
  up,

  /// Motion toward the bottom edge (incoming enters from the top).
  down,
}

/// A transition played at the boundary between one [VideoSegment] and the next.
///
/// Assign this to [VideoSegment.transition] to describe how that clip
/// transitions **into the following clip** (dissolve, fade-to-black, wipe,
/// etc.).
///
/// On the **last (or only)** segment there is no following clip, so the
/// transition **wraps back into the first segment** and the track loops
/// seamlessly — e.g. a [ClipTransitionType.dissolve] on a single segment makes
/// a looping player cross-dissolve on restart. See [VideoSegment.transition]
/// for the exact wrap behavior (overlap types shorten the output; dip types dip
/// through the color at the seam).
///
/// Clip transitions are currently supported on **Android** and
/// **iOS/macOS** only. Other platforms ignore the field.
///
/// **Note for overlap transitions** (see [ClipTransitionType.isOverlap]): the
/// two clips must show at the same size (which split clips from the same
/// source always do). How each is stored does not matter — a recording kept
/// landscape with a rotation flag blends with an upright clip of the same
/// picture. When neighbouring clips differ in display size, the native side
/// falls back to a hard cut.
///
/// Example:
/// ```dart
/// VideoSegment(
///   video: myVideo,
///   endTime: const Duration(seconds: 5),
///   transition: const ClipTransition(
///     type: ClipTransitionType.dissolve,
///     duration: Duration(milliseconds: 800),
///     curve: AnimationCurve.easeInOut,
///   ),
/// ),
/// VideoSegment(video: myVideo, startTime: const Duration(seconds: 5)),
/// ```
class ClipTransition {
  /// Creates a [ClipTransition].
  ///
  /// [duration] should be greater than zero; the native side clamps it to what
  /// the neighbouring clips can provide.
  const ClipTransition({
    required this.type,
    this.duration = const Duration(milliseconds: 500),
    this.curve = AnimationCurve.linear,
    this.direction = ClipTransitionDirection.left,
  });

  /// The kind of transition (dissolve, fade-to-black, slide, …).
  final ClipTransitionType type;

  /// How long the transition lasts.
  ///
  /// For overlap transitions this is how long the two clips overlap and blend.
  /// For dip transitions ([ClipTransitionType.fadeToBlack],
  /// [ClipTransitionType.fadeToWhite]) this is the full dip duration
  /// (fade-out + fade-in).
  ///
  /// Defaults to 500ms. The native side clamps the duration to what the
  /// neighbouring clips can provide.
  final Duration duration;

  /// The easing curve applied to the transition's progress.
  ///
  /// An overlap transition cross-fades its audio along the same curve. Where
  /// an elastic curve overshoots, iOS and macOS hold each clip at its own
  /// volume or at silence, while Android follows the overshoot.
  ///
  /// Defaults to [AnimationCurve.linear].
  final AnimationCurve curve;

  /// The direction for directional transitions (see
  /// [ClipTransitionType.usesDirection]).
  ///
  /// Ignored for non-directional transitions. Defaults to
  /// [ClipTransitionDirection.left].
  final ClipTransitionDirection direction;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'durationUs': duration.inMicroseconds,
      'curve': curve.name,
      'direction': direction.name,
    };
  }

  factory ClipTransition.fromMap(Map<String, dynamic> map) {
    return ClipTransition(
      type: ClipTransitionType.values.byName(map['type'] as String),
      duration: Duration(microseconds: safeParseInt(map['durationUs'])),
      curve: AnimationCurve.values.byName(
        (map['curve'] as String?) ?? 'linear',
      ),
      direction: ClipTransitionDirection.values.byName(
        (map['direction'] as String?) ?? 'left',
      ),
    );
  }

  ClipTransition copyWith({
    ClipTransitionType? type,
    Duration? duration,
    AnimationCurve? curve,
    ClipTransitionDirection? direction,
  }) {
    return ClipTransition(
      type: type ?? this.type,
      duration: duration ?? this.duration,
      curve: curve ?? this.curve,
      direction: direction ?? this.direction,
    );
  }

  @override
  String toString() {
    return 'ClipTransition(type: $type, duration: $duration, '
        'curve: $curve, direction: $direction)';
  }

  @override
  bool operator ==(covariant ClipTransition other) {
    if (identical(this, other)) return true;
    return other.type == type &&
        other.duration == duration &&
        other.curve == curve &&
        other.direction == direction;
  }

  @override
  int get hashCode =>
      type.hashCode ^ duration.hashCode ^ curve.hashCode ^ direction.hashCode;
}
