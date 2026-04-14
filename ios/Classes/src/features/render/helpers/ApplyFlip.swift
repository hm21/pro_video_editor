import CoreGraphics

/// Applies horizontal and/or vertical flip to video frames.
///
/// Flipping is implemented by scaling with negative values (-1) in the video compositor.
/// This creates a mirror effect along the specified axes.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - flipX: If true, flip horizontally (mirror left-right).
///   - flipY: If true, flip vertically (mirror top-bottom).
func applyFlip(
  config: inout VideoCompositorConfig,
  flipX: Bool,
  flipY: Bool
) {
  config.flipX = flipX
  config.flipY = flipY

  if !flipX && !flipY { return }

  let flipType = flipX && flipY ? "both axes" : flipX ? "horizontal" : "vertical"
  PluginLog.print("[\(Tags.render)] 🔄 Applying flip: \(flipType)")
}
