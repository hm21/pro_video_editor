import AVFoundation
import CoreGraphics

/// Applies rectangular crop to video frames.
///
/// Crops the video to a specified rectangle. The crop is applied in the video's
/// natural coordinate space (before rotation). When combined with rotation,
/// the output size is adjusted accordingly (width and height swap for 90°/270° rotations).
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - naturalSize: Original video dimensions before rotation.
///   - rotateTurns: Number of 90° rotations (affects output dimensions).
///   - cropX: Left edge of crop rectangle (0 = left side of video).
///   - cropY: Top edge of crop rectangle (0 = top of video).
///   - cropWidth: Width of crop rectangle. Defaults to remaining width.
///   - cropHeight: Height of crop rectangle. Defaults to remaining height.
///
/// - Returns: Final output size after crop and rotation are applied.
func applyCrop(
  config: inout VideoCompositorConfig,
  naturalSize: CGSize,
  rotateTurns: Int?,
  cropX: Int?,
  cropY: Int?,
  cropWidth: Int?,
  cropHeight: Int?
) -> CGSize {
  let x = CGFloat(cropX ?? 0)
  let y = CGFloat(cropY ?? 0)
  let width = CGFloat(cropWidth ?? Int(naturalSize.width) - Int(x))
  let height = CGFloat(cropHeight ?? Int(naturalSize.height) - Int(y))

  config.cropX = x
  config.cropY = y
  config.cropWidth = width
  config.cropHeight = height

  if cropX != 0 || cropY != 0 || cropWidth != nil || cropHeight != nil {
    PluginLog.print(
      "[\(Tags.render)] ✂️ Applying crop: x=\(Int(x)), y=\(Int(y)), width=\(Int(width)), height=\(Int(height))"
    )
  }

  let cropRect = CGRect(x: x, y: y, width: width, height: height)

  let turns = 4 - (rotateTurns ?? 0) % 4

  let isPortraitRotation = turns % 2 == 1
  return isPortraitRotation
    ? CGSize(width: cropRect.size.height, height: cropRect.size.width)
    : cropRect.size
}
