import Foundation

/// Pure geometry for **overlap** clip transitions (dissolve / slide / push /
/// wipe) that honors each clip's playback speed.
///
/// The requested transition duration is interpreted in **output** (post-speed)
/// time, matching the non-transition timeline. Each side of the blend therefore
/// consumes `outputDuration * speed` microseconds of its own source, so the
/// footage inside the blend plays at the requested speed just like the rest of
/// the clip.
///
/// Mirrors the Android `ClipTransitionGeometry.kt` so both platforms resolve
/// transitions identically.
internal enum ClipTransitionGeometry {

  /// Resolved overlap geometry for a single clip boundary.
  struct OverlapPlan: Equatable {
    /// Output (post-speed) duration of the blended transition clip.
    let outputDurationUs: Int64
    /// Source microseconds consumed from the outgoing clip's tail.
    let outgoingTailSourceUs: Int64
    /// Source microseconds consumed from the incoming clip's head.
    let incomingHeadSourceUs: Int64
  }

  /// Computes the overlap geometry for the boundary between an outgoing and an
  /// incoming clip, or `nil` when the transition cannot be rendered (caller
  /// should fall back to a hard cut).
  ///
  /// Returns `nil` when either clip would be fully consumed by the blend (no
  /// body left), preserving the 1× behavior where a transition needs some
  /// non-blended content on both sides.
  static func planOverlap(
    outgoingSourceDurationUs: Int64,
    incomingSourceDurationUs: Int64,
    transitionDurationUs: Int64,
    outgoingSpeed: Float?,
    incomingSpeed: Float?
  ) -> OverlapPlan? {
    guard outgoingSourceDurationUs > 0, incomingSourceDurationUs > 0 else { return nil }

    let sOut = validSpeedOrOne(outgoingSpeed)
    let sIn = validSpeedOrOne(incomingSpeed)

    // Full output durations of each clip after its own speed.
    let outgoingOutputDur = Double(outgoingSourceDurationUs) / sOut
    let incomingOutputDur = Double(incomingSourceDurationUs) / sIn

    // Clamp the requested (output-time) duration to what each side can give.
    let dOut = min(Double(transitionDurationUs), outgoingOutputDur, incomingOutputDur)
    guard dOut > 0 else { return nil }

    let outputDurationUs = Int64((dOut).rounded())
    let tailSourceUs = Int64((dOut * sOut).rounded())
    let headSourceUs = Int64((dOut * sIn).rounded())

    // Both sides must keep some non-blended body, matching the 1× behavior.
    guard outputDurationUs > 0,
      outgoingSourceDurationUs - tailSourceUs > 0,
      incomingSourceDurationUs - headSourceUs > 0
    else { return nil }

    return OverlapPlan(
      outputDurationUs: outputDurationUs,
      outgoingTailSourceUs: tailSourceUs,
      incomingHeadSourceUs: headSourceUs
    )
  }

  private static func validSpeedOrOne(_ speed: Float?) -> Double {
    if let speed = speed, speed > 0 { return Double(speed) }
    return 1.0
  }
}
