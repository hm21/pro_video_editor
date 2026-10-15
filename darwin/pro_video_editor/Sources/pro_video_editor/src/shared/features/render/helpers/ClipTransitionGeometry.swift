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

  /// One clip as the overlap pre-render lays it out.
  struct TimelineClip: Equatable {
    /// Trimmed source duration of the clip.
    let sourceDurationUs: Int64
    /// Clip playback speed (nil/<=0 → 1×).
    let speed: Float?
    /// Requested duration of the overlap blend into the next clip, or `nil`
    /// when this clip does not blend into it.
    let blendDurationUs: Int64?
  }

  /// Which overlap blends start at or after `endUs`, where the render ends on
  /// the clips' timeline (see `clipTimelineEndUs`). Such a blend never reaches
  /// the output, so it need not be rendered.
  ///
  /// Lays the clips out the way the pre-render rewrites them: every blend takes
  /// its tail from the outgoing clip and its head from the incoming one, so each
  /// transition shortens the timeline by one blend. A clip whose blend cannot be
  /// planned is a hard cut, as in `planOverlap`.
  ///
  /// The layout assumes every earlier blend renders. One that fails becomes a
  /// hard cut, which only pushes later clips back, so a blend found past the end
  /// stays past it.
  ///
  /// - Parameter startOffsetUs: Where the first clip starts. A loop wrap moves
  ///   the first clip's head to the end, which pulls every blend earlier by up
  ///   to the wrap's requested duration, so the caller passes that negated.
  /// - Returns: per clip, whether its blend into the next clip starts at or
  ///   after `endUs`; false for a clip without a blend, and for all when `endUs`
  ///   is nil.
  static func blendsPastEnd(
    clips: [TimelineClip],
    endUs: Int64?,
    startOffsetUs: Int64 = 0
  ) -> [Bool] {
    var result = Array(repeating: false, count: clips.count)
    guard let endUs else { return result }
    var positionUs = startOffsetUs
    // Source the previous blend took from the head of the current clip.
    var headTakenUs: Int64 = 0
    for (i, clip) in clips.enumerated() {
      let durationUs = clip.sourceDurationUs - headTakenUs
      headTakenUs = 0
      let next: TimelineClip? = i + 1 < clips.count ? clips[i + 1] : nil
      guard let blendDurationUs = clip.blendDurationUs, let next,
        let plan = planOverlap(
          outgoingSourceDurationUs: durationUs,
          incomingSourceDurationUs: next.sourceDurationUs,
          transitionDurationUs: blendDurationUs,
          outgoingSpeed: clip.speed,
          incomingSpeed: next.speed)
      else {
        positionUs += outputDurationUs(sourceDurationUs: durationUs, speed: clip.speed)
        continue
      }
      let blendStartUs =
        positionUs
        + outputDurationUs(
          sourceDurationUs: durationUs - plan.outgoingTailSourceUs, speed: clip.speed)
      result[i] = blendStartUs >= endUs
      positionUs = blendStartUs + plan.outputDurationUs
      headTakenUs = plan.incomingHeadSourceUs
    }
    return result
  }

  /// Maps the render's end, given on the output timeline after the
  /// composition-wide `globalSpeed`, onto the clips' own timeline, where each
  /// clip runs at its own speed only. `nil` stays `nil` (no end).
  static func clipTimelineEndUs(globalEndUs: Int64?, globalSpeed: Float?) -> Int64? {
    globalEndUs.map { Int64((Double($0) * validSpeedOrOne(globalSpeed)).rounded()) }
  }

  /// Output duration of `sourceDurationUs` of a clip played at `speed`.
  static func outputDurationUs(sourceDurationUs: Int64, speed: Float?) -> Int64 {
    Int64((Double(sourceDurationUs) / validSpeedOrOne(speed)).rounded())
  }

  private static func validSpeedOrOne(_ speed: Float?) -> Double {
    if let speed = speed, speed > 0 { return Double(speed) }
    return 1.0
  }
}
