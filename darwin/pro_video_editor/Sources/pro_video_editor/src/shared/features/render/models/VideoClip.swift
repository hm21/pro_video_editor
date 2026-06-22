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

  init(
    inputPath: String,
    startUs: Int64? = nil,
    endUs: Int64? = nil,
    volume: Float? = nil,
    playbackSpeed: Float? = nil,
    reverseVideo: Bool = false,
    transition: ClipTransitionConfig? = nil
  ) {
    self.inputPath = inputPath
    self.startUs = startUs
    self.endUs = endUs
    self.volume = volume
    self.playbackSpeed = playbackSpeed
    self.reverseVideo = reverseVideo
    self.transition = transition
  }
}
