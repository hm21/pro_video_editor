import Foundation

/// Represents a video clip with optional trimming, volume and playback speed control
internal struct VideoClip: Sendable {
  let inputPath: String
  let startUs: Int64?
  let endUs: Int64?
  let volume: Float?
  let playbackSpeed: Float?
  let reverseVideo: Bool
  /// Transition into the next clip (nil = hard cut). Ignored on the last clip.
  let transition: ClipTransitionConfig?
  /// Start position on the layer timeline in microseconds (composition only).
  /// `nil` = right after the previous clip on the same layer.
  let timelineStartUs: Int64?
  /// Placement of this clip within the composition canvas (composition only).
  /// Overrides the layer transform. `nil` = use the layer transform.
  let transform: SegmentTransformConfig?

  init(
    inputPath: String,
    startUs: Int64? = nil,
    endUs: Int64? = nil,
    volume: Float? = nil,
    playbackSpeed: Float? = nil,
    reverseVideo: Bool = false,
    transition: ClipTransitionConfig? = nil,
    timelineStartUs: Int64? = nil,
    transform: SegmentTransformConfig? = nil
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
      )
    )
  }
}
