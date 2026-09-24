import Foundation

/// Represents a video clip with optional trimming, volume and playback speed control
internal struct VideoClip: Sendable {
  let inputPath: String
  let startUs: Int64?
  let endUs: Int64?
  let volume: Float?
  let playbackSpeed: Float?
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

  init(
    inputPath: String,
    startUs: Int64? = nil,
    endUs: Int64? = nil,
    volume: Float? = nil,
    playbackSpeed: Float? = nil,
    reverseVideo: Bool = false,
    transition: ClipTransitionConfig? = nil,
    timelineStartUs: Int64? = nil,
    transform: SegmentTransformConfig? = nil,
    chromaKey: ChromaKeyConfig? = nil,
    suppressChromaKey: Bool = false,
    frameRateOverride: Float? = nil
  ) {
    self.inputPath = inputPath
    self.startUs = startUs
    self.endUs = endUs
    self.volume = volume
    self.playbackSpeed = playbackSpeed
    self.reverseVideo = reverseVideo
    self.transition = transition
    self.timelineStartUs = timelineStartUs
    self.transform = transform
    self.chromaKey = chromaKey
    self.suppressChromaKey = suppressChromaKey
    self.frameRateOverride = frameRateOverride
  }

  /// This clip playing `startUs..<endUs` of `inputPath` instead of its own
  /// source window; every other setting is kept. `frameRateOverride` is the
  /// new file's: a cadence measured on the old one does not carry over.
  func reading(
    _ inputPath: String, startUs: Int64?, endUs: Int64?, frameRateOverride: Float? = nil
  ) -> VideoClip {
    VideoClip(
      inputPath: inputPath,
      startUs: startUs,
      endUs: endUs,
      volume: volume,
      playbackSpeed: playbackSpeed,
      reverseVideo: reverseVideo,
      transition: transition,
      timelineStartUs: timelineStartUs,
      transform: transform,
      chromaKey: chromaKey,
      suppressChromaKey: suppressChromaKey,
      frameRateOverride: frameRateOverride
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
      playbackSpeed: (clipMap["playbackSpeed"] as? NSNumber)?.floatValue,
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
      )
    )
  }
}
