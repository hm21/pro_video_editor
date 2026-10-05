import Foundation

/// Keeps an amplified signal under full scale by turning it down where it
/// would cross [ceiling], instead of clipping it there.
///
/// A volume above 1.0 pushes material that is already near full scale — a
/// mastered song, a loud recording — past it. Clipping those samples is
/// audible as distortion; this lowers the gain for the frames that would
/// cross, instantly, and lets it recover over [releaseSeconds] so the
/// reduction follows the music rather than every sample.
///
/// All channels of a frame share one gain, so a peak in one channel does not
/// shift the stereo image. There is no lookahead: the output never runs late
/// against the video, and a frame that crosses still comes out at exactly the
/// ceiling. Material that stays under the ceiling passes untouched. The
/// Android export runs the same limiter.
struct PeakLimiter {
  /// The highest level a limited frame reaches: -1 dBFS. AAC overshoots a
  /// limited peak by a few percent (measured 4 % on a sine at 300 %), so a
  /// ceiling closer to full scale clips again in the encoder.
  static let ceiling: Float = 0.891251

  /// How long the gain takes to recover by ~63 % after a peak.
  static let releaseSeconds = 0.05

  private let releaseCoefficient: Float

  /// The gain the limiter currently applies, 1 when it is not limiting.
  private(set) var gain: Float = 1

  init(sampleRate: Double) {
    releaseCoefficient = Float(exp(-1.0 / (Self.releaseSeconds * max(sampleRate, 1))))
  }

  /// The gain to apply to a frame whose loudest sample, after the volume, is
  /// [peak] — at most `ceiling / peak`, so the frame ends at or under the
  /// ceiling.
  mutating func gain(forPeak peak: Float) -> Float {
    let target = peak > Self.ceiling ? Self.ceiling / peak : 1
    gain = target < gain ? target : target + (gain - target) * releaseCoefficient
    return gain
  }

  /// Lifts the gain by [factor], up to 1, after the volume in front of the
  /// limiter dropped by that factor: the reduction was only needed for the
  /// louder volume, and releasing it slowly would duck what follows.
  mutating func volumeDropped(by factor: Float) {
    gain = min(1, gain * factor)
  }

  /// Forgets any reduction in progress.
  mutating func reset() {
    gain = 1
  }
}
