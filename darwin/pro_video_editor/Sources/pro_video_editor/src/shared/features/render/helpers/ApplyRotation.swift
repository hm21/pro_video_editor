import CoreGraphics

/// Applies rotation to video frames in 90-degree increments.
///
/// Rotation is applied by the video compositor using a transform matrix.
/// Only 90° increments are supported (0°, 90°, 180°, 270°).
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - rotateTurns: Number of 90° clockwise rotations.
///                  - 0 = no rotation
///                  - 1 = 90° clockwise
///                  - 2 = 180°
///                  - 3 = 270° clockwise (90° counter-clockwise)
///                  - Negative values work (rotation counter-clockwise)
///
/// - Note: The rotation is normalized to 0-3 range automatically.
func applyRotation(
  config: inout VideoCompositorConfig,
  rotateTurns: Int?
) {
  let normalizedTurns = ((rotateTurns ?? 0) % 4 + 4) % 4
  let turns = (4 - normalizedTurns) % 4
  let degrees = turns * 90
  let radians = CGFloat(Double(degrees) * .pi / 180)

  config.rotateRadians = radians
  config.rotateTurns = turns

  if turns == 0 { return }
  PluginLog.print("[\(Tags.render)] 🔄 Applying rotation: \(degrees)° (\(turns) × 90°)")
}
