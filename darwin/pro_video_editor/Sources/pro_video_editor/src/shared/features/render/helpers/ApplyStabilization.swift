import CoreImage
import CoreMedia
import Foundation

/// A clip's stabilization on the composition timeline.
///
/// `startUs..<endUs` is the clip's span in composition microseconds;
/// `fileStartUs` is the time in the file the clip reads that plays at
/// `startUs`, and `frameUs` the file's frame duration. Single-track path
/// only, where a clip plays at its own speed.
struct StabilizationWindow: Sendable {
  let startUs: Int64
  let endUs: Int64
  let fileStartUs: Int64
  let frameUs: Int64
  let config: StabilizationConfig

  /// The transform for the frame shown at composition time `tUs`.
  func transform(atCompositionUs tUs: Int64) -> StabilizationConfig.Transform {
    config.transform(atFileUs: fileStartUs + (tUs - startUs), frameUs: frameUs)
  }
}

/// One window per stabilized clip, from the per-clip instructions.
///
/// A clip with a playback speed or played in reverse no longer shows its
/// source frames at a fixed offset, which these windows rely on; it is
/// skipped with a warning.
func computeStabilizationWindows(
  videoClips: [VideoClip], clipInstructions: [ClipInstruction]
) -> [StabilizationWindow] {
  var windows: [StabilizationWindow] = []
  for (index, clip) in videoClips.enumerated() {
    guard index < clipInstructions.count, let config = clip.stabilization else { continue }
    if clip.reverseVideo || (clip.playbackSpeed.map { $0 > 0 && $0 != 1 } ?? false) {
      PluginLog.print(
        "[\(Tags.render)] ⚠️ Clip \(index): stabilization is not supported with a playback speed or reverse yet and is skipped"
      )
      continue
    }
    let instruction = clipInstructions[index]
    windows.append(
      StabilizationWindow(
        startUs: microseconds(instruction.timeRange.start),
        endUs: microseconds(CMTimeRangeGetEnd(instruction.timeRange)),
        fileStartUs: microseconds(instruction.sourceStart),
        frameUs: microseconds(instruction.sourceFrameDuration),
        config: config))
  }
  return windows
}

/// Moves `image` by `transform`, around the center of its extent, and crops
/// it back to that extent.
///
/// The transform is defined with y pointing down; CoreImage's y points up,
/// so the vertical shift and the turn change sign.
func applyStabilization(
  _ transform: StabilizationConfig.Transform, to image: CIImage
) -> CIImage {
  let extent = image.extent
  let center = CGPoint(x: extent.midX, y: extent.midY)
  let move = CGAffineTransform(translationX: -center.x, y: -center.y)
    .concatenating(CGAffineTransform(scaleX: transform.scale, y: transform.scale))
    .concatenating(CGAffineTransform(rotationAngle: -transform.rotation))
    .concatenating(
      CGAffineTransform(
        translationX: center.x + transform.dx * extent.width,
        y: center.y - transform.dy * extent.height))
  return image.transformed(by: move).cropped(to: extent)
}

private func microseconds(_ time: CMTime) -> Int64 {
  Int64((CMTimeGetSeconds(time) * 1_000_000).rounded())
}
