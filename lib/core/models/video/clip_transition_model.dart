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
/// = 9s). These are [dissolve], [slide], [push] and [wipe].
///
/// **Dip transitions** — the dip happens within the clips' own time at the
/// boundary, so the total duration is **unchanged**. These are [fadeToBlack]
/// and [fadeToWhite].
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
}

/// Direction for directional transitions ([ClipTransitionType.slide],
/// [ClipTransitionType.push], [ClipTransitionType.wipe]).
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
/// etc.). The transition is ignored on the last segment (there is no following
/// clip).
///
/// Clip transitions are currently supported on **Android** and
/// **iOS/macOS** only. Other platforms ignore the field.
///
/// **Note for overlap transitions** ([ClipTransitionType.dissolve],
/// [ClipTransitionType.slide], [ClipTransitionType.push],
/// [ClipTransitionType.wipe]): the two clips must share the same dimensions
/// (which split clips from the same source always do). When neighbouring clips
/// differ in size, the native side falls back to a hard cut.
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
  /// Defaults to [AnimationCurve.linear].
  final AnimationCurve curve;

  /// The direction for directional transitions ([ClipTransitionType.slide],
  /// [ClipTransitionType.push], [ClipTransitionType.wipe]).
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
