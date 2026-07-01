import AVFoundation
import CoreImage
import Foundation

/// Applies image layers on top of video frames.
///
/// Each image layer is composited over video frames during rendering within its
/// specified time range. Images should be provided as encoded data (PNG, JPEG, etc.)
/// and will be decoded by the video compositor.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - imageLayers: List of image layers with timing and positioning information.
///   - withCropping: When true, the overlay is applied before cropping and gets cropped
///                   together with the video. When false (default), the overlay is scaled
///                   to the final cropped size.
///
/// - Note: The image is positioned and scaled by the video compositor according
///         to its own logic (typically centered or full-frame).
public func applyImageLayer(
  config: inout VideoCompositorConfig,
  imageLayers: [ImageLayerConfig],
  withCropping: Bool = false,
  totalDurationUs: Int64 = 0
) {
  let resolved = resolveOpenEndedOutAnimations(imageLayers, totalDurationUs: totalDurationUs)
  config.imageLayerConfigs = resolved
  config.imageBytesWithCropping = withCropping

  if !resolved.isEmpty {
    PluginLog.print(
      "[\(Tags.render)] 🖼️ Applying \(resolved.count) image layer(s) with timing")
  }
}

/// Rewrites layers that run "until the end" (`endUs == -1`) **and** carry an
/// `animateOut`/`animateInOut` animation so their end resolves to
/// `totalDurationUs`, giving the out-phase a concrete point to animate toward.
///
/// Without this the compositor treats an open-ended layer's end as `Int64.max`,
/// so the out-phase never triggers and the layer pops off at the last frame
/// instead of animating out. Layers without an out-phase animation — and the
/// whole list when `totalDurationUs <= 0` — are returned unchanged, so every
/// untouched layer keeps its exact prior behavior.
func resolveOpenEndedOutAnimations(
  _ layers: [ImageLayerConfig], totalDurationUs: Int64
) -> [ImageLayerConfig] {
  guard totalDurationUs > 0 else { return layers }
  return layers.map { layer in
    let hasOutPhase =
      layer.endUs == -1
      && layer.animations.contains {
        $0.phase == "animateOut" || $0.phase == "animateInOut"
      }
    guard hasOutPhase else { return layer }
    return ImageLayerConfig(
      imageData: layer.imageData,
      startUs: layer.startUs,
      endUs: totalDurationUs,
      x: layer.x, y: layer.y,
      width: layer.width, height: layer.height,
      rotation: layer.rotation, loop: layer.loop,
      animations: layer.animations)
  }
}
