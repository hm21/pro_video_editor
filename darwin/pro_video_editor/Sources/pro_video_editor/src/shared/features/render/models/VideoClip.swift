import Foundation

/// Represents a video clip with optional trimming, volume and playback speed control
internal struct VideoClip: Sendable {
  let inputPath: String
  let startUs: Int64?
  let endUs: Int64?
  let volume: Float?
  /// Equalizer of this clip's audio. `nil` = unchanged.
  let equalizer: AudioEqualizer?
  let playbackSpeed: Float?
  /// A speed that changes while the clip plays, instead of `playbackSpeed`.
  /// Its positions run along this clip's own window, so a clip trimmed to part
  /// of itself carries the matching `SpeedRamp.cropped(from:to:)`.
  let speedRamp: SpeedRamp?
  let reverseVideo: Bool
  /// Transition into the next clip (nil = hard cut). On the **last** clip it
  /// wraps into the first clip, making the track loop seamlessly (handled by the
  /// wrap pass in RenderVideo / the dip windows in CompositionBuilder).
  let transition: ClipTransitionConfig?
  /// Start position on the layer timeline in microseconds (composition only).
  /// `nil` = right after the previous clip on the same layer.
  let timelineStartUs: Int64?
  /// Placement of this clip within the composition canvas (composition only).
  /// Overrides the layer transform. `nil` = use the layer transform.
  let transform: SegmentTransformConfig?
  /// Removes a solid-colored background from this clip. Overrides the layer's
  /// and the global key. `nil` = fall back to those.
  let chromaKey: ChromaKeyConfig?
  /// Opts this clip out of the layer/global key entirely.
  ///
  /// Internal, never parsed from the platform channel. `chromaKey == nil` means
  /// "inherit", so it cannot express "deliberately unkeyed" — which is exactly
  /// what a pre-rendered overlap blend needs when the two clips it was composed
  /// from carry different keys. See `RenderVideo.blendChromaKey`.
  let suppressChromaKey: Bool
  /// The cadence the render uses for this clip instead of its file's
  /// `nominalFrameRate`, set when `inputPath` is a pre-transcode of only part
  /// of a source.
  ///
  /// Internal, never parsed from the platform channel. `nominalFrameRate` is
  /// an average over the file, and a short trimmed one misreads it: 0.4 s of
  /// 30 fps phone footage that opens on a sliver of a frame reads 33.3, and
  /// the render derives its frame duration from it. `nil` = use the file's.
  let frameRateOverride: Float?
  /// Per-frame transforms that steady this clip. Single-track path only;
  /// `nil` leaves the frames where they are.
  let stabilization: StabilizationConfig?

  init(
    inputPath: String,
    startUs: Int64? = nil,
    endUs: Int64? = nil,
    volume: Float? = nil,
    equalizer: AudioEqualizer? = nil,
    playbackSpeed: Float? = nil,
    speedRamp: SpeedRamp? = nil,
    reverseVideo: Bool = false,
    transition: ClipTransitionConfig? = nil,
    timelineStartUs: Int64? = nil,
    transform: SegmentTransformConfig? = nil,
    chromaKey: ChromaKeyConfig? = nil,
    suppressChromaKey: Bool = false,
    frameRateOverride: Float? = nil,
    stabilization: StabilizationConfig? = nil
  ) {
    self.inputPath = inputPath
    self.startUs = startUs
    self.endUs = endUs
    self.volume = volume
    self.equalizer = equalizer
    self.playbackSpeed = playbackSpeed
    self.speedRamp = speedRamp
    self.reverseVideo = reverseVideo
    self.transition = transition
    self.timelineStartUs = timelineStartUs
    self.transform = transform
    self.chromaKey = chromaKey
    self.suppressChromaKey = suppressChromaKey
    self.frameRateOverride = frameRateOverride
    self.stabilization = stabilization
  }

  /// This clip playing `startUs..<endUs` of `inputPath` instead of its own
  /// source window; every other setting is kept. `frameRateOverride` is the
  /// new file's: a cadence measured on the old one does not carry over.
  ///
  /// `sourceShiftUs` is how much later in the clip's current file a time in
  /// `inputPath` lies: non-zero only for a pre-transcode of part of it, whose
  /// timeline starts later. A re-trim of the same file leaves it at zero.
  ///
  /// The speed ramp is kept as it is, which suits a new file showing the same
  /// window; a re-trim to part of the window passes the cropped one.
  func reading(
    _ inputPath: String, startUs: Int64?, endUs: Int64?, frameRateOverride: Float? = nil,
    sourceShiftUs: Int64 = 0, speedRamp: SpeedRamp?? = nil
  ) -> VideoClip {
    VideoClip(
      inputPath: inputPath,
      startUs: startUs,
      endUs: endUs,
      volume: volume,
      equalizer: equalizer,
      playbackSpeed: playbackSpeed,
      speedRamp: speedRamp ?? self.speedRamp,
      reverseVideo: reverseVideo,
      transition: transition,
      timelineStartUs: timelineStartUs,
      transform: transform,
      chromaKey: chromaKey,
      suppressChromaKey: suppressChromaKey,
      frameRateOverride: frameRateOverride,
      stabilization: stabilization?.shifted(by: sourceShiftUs)
    )
  }

  /// Parses a clip from a platform-channel map. Used by both the single-track
  /// (`videoClips`) and the layered (`composition`) paths.
  static func fromMap(_ clipMap: [String: Any]) -> VideoClip? {
    guard let inputPath = clipMap["inputPath"] as? String else { return nil }
    return VideoClip(
      inputPath: inputPath,
      startUs: (clipMap["startUs"] as? NSNumber)?.int64Value,
      endUs: (clipMap["endUs"] as? NSNumber)?.int64Value,
      volume: (clipMap["volume"] as? NSNumber)?.floatValue,
      equalizer: AudioEqualizer.from(clipMap["equalizer"]),
      playbackSpeed: (clipMap["playbackSpeed"] as? NSNumber)?.floatValue,
      speedRamp: SpeedRamp.fromArguments(clipMap["speedRamp"]),
      reverseVideo: clipMap["reverseVideo"] as? Bool ?? false,
      transition: ClipTransitionConfig.fromArguments(
        clipMap["transition"] as? [String: Any]
      ),
      timelineStartUs: (clipMap["timelineStartUs"] as? NSNumber)?.int64Value,
      transform: SegmentTransformConfig.fromArguments(
        clipMap["transform"] as? [String: Any]
      ),
      chromaKey: ChromaKeyConfig.fromArguments(
        clipMap["chromaKey"] as? [String: Any]
      ),
      stabilization: StabilizationConfig.fromArguments(
        clipMap["stabilization"] as? [String: Any]
      )
    )
  }
}

extension VideoClip {
  /// Whether the clip plays at anything other than its own speed.
  var changesSpeed: Bool {
    speedRamp != nil || (playbackSpeed.map { $0 > 0 && $0 != 1 } ?? false)
  }

  /// The constant speed that plays `sourceDurationUs` of this clip in the time
  /// it takes: `playbackSpeed`, or a speed ramp's average.
  func averageSpeed() -> Float? {
    guard let speedRamp else { return playbackSpeed }
    return Float(1 / speedRamp.durationFactor)
  }

  /// How long `sourceDurationUs` of this clip plays: along its speed ramp, or
  /// at `playbackSpeed`.
  func outputDurationUs(sourceDurationUs: Int64) -> Int64 {
    if let speedRamp { return speedRamp.outputDurationUs(sourceDurationUs: sourceDurationUs) }
    return ClipTransitionGeometry.outputDurationUs(
      sourceDurationUs: sourceDurationUs, speed: playbackSpeed)
  }

  /// The speed the last `outputUs` of this clip play at on average, for an
  /// overlap blend that takes them; `playbackSpeed` without a speed ramp.
  func tailSpeed(outputUs: Int64, sourceDurationUs: Int64) -> Float? {
    guard let speedRamp, outputUs > 0 else { return playbackSpeed }
    let sourceUs = speedRamp.tailSourceUs(outputUs: outputUs, sourceDurationUs: sourceDurationUs)
    return Float(Double(sourceUs) / Double(outputUs))
  }

  /// The speed the first `outputUs` of this clip play at on average, for an
  /// overlap blend that takes them; `playbackSpeed` without a speed ramp.
  func headSpeed(outputUs: Int64, sourceDurationUs: Int64) -> Float? {
    guard let speedRamp, outputUs > 0 else { return playbackSpeed }
    let sourceUs = speedRamp.headSourceUs(outputUs: outputUs, sourceDurationUs: sourceDurationUs)
    return Float(Double(sourceUs) / Double(outputUs))
  }

  /// This clip's speed ramp for the part of its window from `fromUs` to
  /// `toUs` of source, counted from its start; `nil` without a speed ramp.
  func croppedSpeedRamp(fromUs: Int64, toUs: Int64, ofSourceUs sourceDurationUs: Int64) -> SpeedRamp? {
    guard let speedRamp, sourceDurationUs > 0 else { return nil }
    return speedRamp.cropped(
      from: Double(fromUs) / Double(sourceDurationUs),
      to: Double(toUs) / Double(sourceDurationUs))
  }
}
