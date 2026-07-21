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
  /// A blend may consume a clip **entirely** (no non-blended body left): the
  /// caller drops the fully-consumed side and keeps the blend clip in its place,
  /// so two adjacent transitions can each fill their shared clip. Only a
  /// non-positive blend, a rounding overrun, or invalid inputs return `nil`.
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

    // A clip may be fully consumed by the blend (body == 0); the caller drops it
    // and keeps the blend in its place. Reject only a non-positive blend or a
    // rounding overrun that would consume more than a clip has.
    guard outputDurationUs > 0,
      outgoingSourceDurationUs - tailSourceUs >= 0,
      incomingSourceDurationUs - headSourceUs >= 0
    else { return nil }

    return OverlapPlan(
      outputDurationUs: outputDurationUs,
      outgoingTailSourceUs: tailSourceUs,
      incomingHeadSourceUs: headSourceUs
    )
  }

  /// Resolves the overlap geometry for a **seamless loop wrap** where the
  /// outgoing tail and incoming head are carved from the *same* single clip
  /// (its whole start-to-end range).
  ///
  /// Unlike `planOverlap` the two sides share one source, so the head
  /// `[0, head)` and tail `[L - tail, L)` must not overlap — a positive middle
  /// body must remain (`head + tail < sourceDuration`). Because both sides are
  /// the same clip they also share its playback speed, so `head == tail`.
  /// Returns `nil` when no body would remain (caller falls back to no wrap).
  ///
  /// Multi-clip loops (last clip != first clip) use `planOverlap` instead, since
  /// each side then keeps its own independent source.
  static func planWrap(
    sourceDurationUs: Int64,
    transitionDurationUs: Int64,
    speed: Float?
  ) -> OverlapPlan? {
    guard sourceDurationUs > 0 else { return nil }
    let s = validSpeedOrOne(speed)
    let outputDur = Double(sourceDurationUs) / s
    // Both sides consume `dOut * speed` of the same source; head + tail must
    // leave a positive middle body, so dOut is capped just below outputDur/2.
    let dOut = min(Double(transitionDurationUs), outputDur / 2.0)
    guard dOut > 0 else { return nil }
    let outputDurationUs = Int64(dOut.rounded())
    let sideSourceUs = Int64((dOut * s).rounded())
    guard outputDurationUs > 0, sourceDurationUs - 2 * sideSourceUs > 0 else { return nil }
    return OverlapPlan(
      outputDurationUs: outputDurationUs,
      outgoingTailSourceUs: sideSourceUs,
      incomingHeadSourceUs: sideSourceUs
    )
  }

  private static func validSpeedOrOne(_ speed: Float?) -> Double {
    if let speed = speed, speed > 0 { return Double(speed) }
    return 1.0
  }
}
