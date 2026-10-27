import CoreImage
import CoreMedia
import Foundation

/// How a segment's keyframes move one frame: scaled by `scale` and turned
/// clockwise by `rotation` radians around the frame's center, then shifted by
/// `dx` and `dy` (fractions of its width and height), in the upright frame with
/// the origin top left.
struct FrameMotion: Equatable, Sendable {
  let dx: Double
  let dy: Double
  let scale: Double
  let rotation: Double

  /// Whether the frame stays exactly where it is.
  var isIdentity: Bool { dx == 0 && dy == 0 && scale == 1 && rotation == 0 }
}

/// The motion a segment's `keyframes` give the frame with source timestamp
/// `sourceUs`, or `nil` when there are none.
///
/// The keyframes carry the shift as `x`/`y` and are mixed as a layer's are
/// (see `keyframePlacement(_:atUs:)`), which is what the Dart
/// `SegmentKeyframe` describes.
func segmentMotion(_ keyframes: [KeyframeConfig], atSourceUs sourceUs: Int64) -> FrameMotion? {
  keyframePlacement(keyframes, atUs: sourceUs).map {
    FrameMotion(dx: $0.x, dy: $0.y, scale: $0.scale, rotation: $0.rotation)
  }
}

/// `image`, an upright frame, moved by `motion` around the center of its
/// extent and cropped back to it. What the moved picture no longer covers is
/// black.
///
/// The motion is defined with y pointing down; Core Image's y points up, so
/// the vertical shift and the turn change sign.
func applyFrameMotion(_ motion: FrameMotion, to image: CIImage) -> CIImage {
  let extent = image.extent
  let black = CIImage(color: .black).cropped(to: extent)
  guard motion.scale > 1e-6 else { return black }
  let center = CGPoint(x: extent.midX, y: extent.midY)
  let move = CGAffineTransform(translationX: -center.x, y: -center.y)
    .concatenating(CGAffineTransform(scaleX: motion.scale, y: motion.scale))
    .concatenating(CGAffineTransform(rotationAngle: -motion.rotation))
    .concatenating(
      CGAffineTransform(
        translationX: center.x + motion.dx * extent.width,
        y: center.y - motion.dy * extent.height))
  return image.transformed(by: move).composited(over: black).cropped(to: extent)
}

extension KeyframeConfig {
  /// This keyframe `deltaUs` later.
  func shifted(by deltaUs: Int64) -> KeyframeConfig {
    deltaUs == 0
      ? self
      : KeyframeConfig(
        timeUs: timeUs + deltaUs, x: x, y: y, scale: scale, rotation: rotation,
        opacity: opacity, curve: curve)
  }
}

/// A segment's `keyframes` as they apply to it played backwards from the
/// source frame at `lastSourceUs`, counting time from 0 there.
///
/// Every frame keeps the motion of its source timestamp: a keyframe at `t`
/// moves to `lastSourceUs - t`, and each stretch between two keyframes is
/// eased along the mirror of its curve, so it passes through the same
/// placements backwards. Mirrors `reversedSegmentKeyframes` on Android.
func reversedSegmentKeyframes(_ keyframes: [KeyframeConfig], lastSourceUs: Int64)
  -> [KeyframeConfig]
{
  guard !keyframes.isEmpty else { return keyframes }
  let last = keyframes.count - 1
  return (0...last).map { i in
    let source = keyframes[last - i]
    // The stretch after this keyframe played backwards is the one before it
    // in the source, eased by the keyframe that starts it there.
    let curve = last - i - 1 >= 0 ? mirroredCurve(keyframes[last - i - 1].curve) : "linear"
    return KeyframeConfig(
      timeUs: lastSourceUs - source.timeUs, x: source.x, y: source.y, scale: source.scale,
      rotation: source.rotation, opacity: source.opacity, curve: curve)
  }
}

/// The curve that eases a stretch played backwards through the same values as
/// `curve` eases it forwards: `1 - curve(1 - t)`. The in and out halves swap;
/// the symmetric curves are their own mirror.
func mirroredCurve(_ curve: String) -> String {
  switch curve {
  case "easeIn": return "easeOut"
  case "easeOut": return "easeIn"
  case "easeInCubic": return "easeOutCubic"
  case "easeOutCubic": return "easeInCubic"
  case "bounceIn": return "bounceOut"
  case "bounceOut": return "bounceIn"
  case "elasticIn": return "elasticOut"
  case "elasticOut": return "elasticIn"
  default: return curve
  }
}

/// A moving clip's span on the composition timeline and the source time of
/// the frame it shows at each moment of it.
///
/// `startUs..<endUs` is the clip's span in composition microseconds, before
/// any render-wide speed. Single-track path only.
struct MotionWindow: Sendable {
  let startUs: Int64
  let endUs: Int64
  /// The time in the file that plays at `startUs` when the clip plays forward.
  let sourceStartUs: Int64
  /// How much of the file the clip plays.
  let sourceDurationUs: Int64
  /// The file's frame duration; a reversed clip opens on the frame that
  /// starts this long before the end of its window.
  let frameUs: Int64
  let reverse: Bool
  /// The clip's constant speed, when it has no ramp.
  let speed: Double
  let ramp: SpeedRamp?
  let keyframes: [KeyframeConfig]

  /// The motion of the frame shown at composition time `tUs`.
  func motion(atCompositionUs tUs: Int64) -> FrameMotion? {
    segmentMotion(keyframes, atSourceUs: sourceUs(atCompositionUs: tUs))
  }

  /// The source timestamp of the frame shown at composition time `tUs`.
  func sourceUs(atCompositionUs tUs: Int64) -> Int64 {
    let played = playedSourceUs(atOutputUs: Double(tUs - startUs))
    let clamped = min(max(played, 0), Double(sourceDurationUs))
    if reverse {
      return sourceStartUs + max(0, sourceDurationUs - frameUs - Int64(clamped.rounded()))
    }
    return sourceStartUs + Int64(clamped.rounded())
  }

  /// How much of the window, in the order it plays, has played after
  /// `outputUs` of the clip's own output.
  private func playedSourceUs(atOutputUs outputUs: Double) -> Double {
    guard let ramp else { return outputUs * speed }
    let total = Double(sourceDurationUs)
    var elapsed = 0.0
    for step in ramp.steps {
      let length = (step.end - step.start) * total
      let output = length / step.speed
      if outputUs <= elapsed + output {
        return step.start * total + (outputUs - elapsed) * step.speed
      }
      elapsed += output
    }
    return total
  }
}

/// One window per clip with keyframes, from the per-clip instructions.
func computeMotionWindows(
  videoClips: [VideoClip], clipInstructions: [ClipInstruction]
) -> [MotionWindow] {
  var windows: [MotionWindow] = []
  for (index, clip) in videoClips.enumerated() {
    guard index < clipInstructions.count, !clip.keyframes.isEmpty else { continue }
    let instruction = clipInstructions[index]
    let outputUs = motionMicroseconds(instruction.timeRange.duration)
    let speed = Double(clip.playbackSpeed.flatMap { $0 > 0 ? $0 : nil } ?? 1)
    let sourceDurationUs: Int64
    if let ramp = clip.speedRamp, ramp.durationFactor > 0 {
      sourceDurationUs = Int64((Double(outputUs) / ramp.durationFactor).rounded())
    } else {
      sourceDurationUs = Int64((Double(outputUs) * speed).rounded())
    }
    windows.append(
      MotionWindow(
        startUs: motionMicroseconds(instruction.timeRange.start),
        endUs: motionMicroseconds(CMTimeRangeGetEnd(instruction.timeRange)),
        sourceStartUs: motionMicroseconds(instruction.sourceStart),
        sourceDurationUs: sourceDurationUs,
        frameUs: motionMicroseconds(instruction.sourceFrameDuration),
        reverse: clip.reverseVideo,
        speed: speed,
        ramp: clip.speedRamp,
        keyframes: clip.keyframes))
  }
  return windows
}

private func motionMicroseconds(_ time: CMTime) -> Int64 {
  guard time.isValid, time.isNumeric else { return 0 }
  return Int64((CMTimeGetSeconds(time) * 1_000_000).rounded())
}
