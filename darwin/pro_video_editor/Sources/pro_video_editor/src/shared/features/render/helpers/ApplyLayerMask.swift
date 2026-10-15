import CoreGraphics
import CoreImage
import Foundation

/// A composition layer's alpha matte, decoded once per render.
///
/// A class around an immutable `CIImage`, so `LayerPlacement` stays `Sendable`
/// and every window the layer shows in shares the one decoded matte instead of
/// copying it.
final class LayerMatte: @unchecked Sendable {
  /// The matte's alpha, one byte per pixel, upright and with its extent at the
  /// origin. See `decodeLayerMatte(_:fittingWithin:)`.
  let image: CIImage

  init(image: CIImage) {
    self.image = image
  }
}

/// Decodes a layer's matte into an alpha-only image no larger than
/// [maxSize] on either axis.
///
/// Only the alpha counts, so it is all that is kept: one byte per pixel
/// instead of four, which matters for a matte at a phone video's resolution
/// held for the whole render. And since the matte is stretched over each clip
/// frame anyway, pixels beyond the largest frame of the layer would only be
/// thrown away again by the stretch, so they are not kept either. A
/// non-positive [maxSize] keeps the matte's own size.
///
/// The EXIF orientation is applied on the way, as for the chroma-key
/// background (see `decodeOrientedImage`). Returns nil when the image does not
/// decode.
func decodeLayerMatte(_ source: EncodedImage, fittingWithin maxSize: CGSize) -> CIImage? {
  guard let decoded = decodeOrientedImage(source) else { return nil }
  let extent = decoded.extent
  guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

  let width = Int(min(extent.width, maxSize.width > 0 ? maxSize.width : extent.width).rounded())
  let height = Int(
    min(extent.height, maxSize.height > 0 ? maxSize.height : extent.height).rounded())
  guard width > 0, height > 0 else { return nil }
  let bounds = CGRect(x: 0, y: 0, width: width, height: height)

  var matte = decoded.transformed(
    by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
  if CGFloat(width) < extent.width || CGFloat(height) < extent.height {
    // Lanczos rather than the bilinear sampling of a plain transform, so a
    // shape's edge stays smooth when a large matte is brought down a lot. The
    // clamp keeps the outermost pixels from blending with the transparency
    // beyond the matte, which would fade a shape that reaches the edge.
    let scaleY = CGFloat(height) / extent.height
    let scaleX = CGFloat(width) / extent.width
    matte = matte.clampedToExtent()
      .applyingFilter(
        "CILanczosScaleTransform",
        parameters: [
          kCIInputScaleKey: scaleY,
          kCIInputAspectRatioKey: scaleX / scaleY,
        ])
  }

  var alpha = Data(count: width * height)
  let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
  alpha.withUnsafeMutableBytes { buffer in
    guard let base = buffer.baseAddress else { return }
    context.render(
      matte.cropped(to: bounds), toBitmap: base, rowBytes: width, bounds: bounds, format: .A8,
      colorSpace: nil)
  }
  return CIImage(
    bitmapData: alpha, bytesPerRow: width, size: bounds.size, format: .A8, colorSpace: nil)
}

/// [image] shaped by [matte]: every pixel keeps its own alpha times the
/// matte's alpha there, and the matte's colors are ignored.
///
/// The matte is stretched over [image]'s whole extent, which on the layered
/// path is the clip's own upright frame, before it is placed on the canvas.
///
/// `CISourceInCompositing` does the multiply: it keeps the source scaled by the
/// background's alpha. On Core Image's premultiplied pixels that scales color
/// and alpha together, which is the straight-alpha `src.a * matte` of
/// Android's `MaskEffect` once premultiplied. Blending over clear with
/// `CIBlendWithAlphaMask` would express the same thing, but leaves a 1–2 px
/// darker seam along the edge of the shape on these renderers.
func applyLayerMatte(_ matte: CIImage, to image: CIImage) -> CIImage {
  let frame = image.extent
  let source = matte.extent
  guard !frame.isInfinite, frame.width > 0, frame.height > 0,
    !source.isInfinite, source.width > 0, source.height > 0
  else { return image }

  // Clamped before the stretch so the frame's outermost pixels sample the
  // matte's edge rather than the transparency beyond it.
  let stretched = matte.clampedToExtent()
    .transformed(
      by: CGAffineTransform(translationX: -source.minX, y: -source.minY)
        .concatenating(
          CGAffineTransform(scaleX: frame.width / source.width, y: frame.height / source.height))
        .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
    )
    .cropped(to: frame)

  return image.applyingFilter(
    "CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: stretched]
  ).cropped(to: frame)
}
