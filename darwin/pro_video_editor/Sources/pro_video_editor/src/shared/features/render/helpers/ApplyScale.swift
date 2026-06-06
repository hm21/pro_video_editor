import CoreGraphics

/// Applies independent horizontal and vertical scaling to video frames.
///
/// Scaling is applied by the video compositor and can create aspect ratio changes
/// or size adjustments. Values less than 1.0 shrink, greater than 1.0 enlarge.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - scaleX: Horizontal scale factor. 1.0 = no change, 0.5 = half width, 2.0 = double width.
///   - scaleY: Vertical scale factor. 1.0 = no change, 0.5 = half height, 2.0 = double height.
///
/// - Note: Scaling is applied after rotation but before other transforms.
func applyScale(
  config: inout VideoCompositorConfig,
  scaleX: Float?,
  scaleY: Float?
) {
  let x = CGFloat(scaleX ?? 1.0)
  let y = CGFloat(scaleY ?? 1.0)

  config.scaleX = x
  config.scaleY = y

  if x != 1.0 || y != 1.0 {
    let percentX = Int(x * 100)
    let percentY = Int(y * 100)
    PluginLog.print("[\(Tags.render)] 📏 Applying scale: X=\(percentX)%, Y=\(percentY)%")
  }
}
