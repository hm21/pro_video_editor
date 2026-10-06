import CoreImage
import Foundation

/// Hides the part of [image] a censor layer covers: where [mask] is opaque the
/// picture is replaced by its blurred or pixelated version, where it is
/// transparent it stays as it is, and partial alpha blends the two.
///
/// [image] is the frame composed so far — the video and every image layer
/// before the censor layer — and [frame] the rect the layers are laid out in.
/// [mask] is the layer placed the way an image layer would be drawn, with its
/// animation's opacity folded into the alpha.
///
/// The blur repeats the frame's edge pixels beyond it, so an area at the edge
/// does not darken. Pixelate counts its blocks from the top-left corner of
/// [blockArea], the mask's extent unless a wiggle tilts the mask, so the area
/// starts on whole blocks, and fills each with the pixel at its start +
/// `block / 2`, as the Android renderer does.
func applyLayerCensor(
  _ censor: LayerCensorConfig, to image: CIImage, mask: CIImage, frame: CGRect,
  blockArea: CGRect? = nil
) -> CIImage {
  // Whole pixels: a crop through a pixel leaves it partly transparent, which
  // the blend below would darken into a seam along the area's edge. Outside
  // the mask's extent the hidden picture is never shown, so it is cropped
  // there: the blur then only runs where it can be seen.
  let area = mask.extent.insetBy(dx: -1, dy: -1).integral.intersection(frame)
  guard !area.isNull, !area.isEmpty, !frame.isInfinite else { return image }

  let hidden: CIImage
  switch censor.type {
  case .blur:
    hidden = censorBlurred(image, sigma: censor.strength, frame: frame)
  case .pixelate:
    let blocks = blockArea ?? mask.extent
    let anchor = CGPoint(x: blocks.minX.rounded(), y: blocks.maxY.rounded())
    hidden = censorPixelated(image, block: censor.blockSize, frame: frame, anchor: anchor)
  }

  // The hidden picture keeps the mask's coverage, then goes over the frame
  // the way an image layer would.
  return hidden.cropped(to: area)
    .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    .composited(over: image)
    .cropped(to: image.extent)
}

/// [image] within [frame] behind a Gaussian blur with the standard deviation
/// [sigma], in pixels.
///
/// The intermediate drops any nearest sampling an earlier step set up, which
/// the blur would otherwise inherit and resample with, as the glow effect
/// does. It is not cached: no other frame reuses it.
private func censorBlurred(_ image: CIImage, sigma: Double, frame: CGRect) -> CIImage {
  image.cropped(to: frame)
    .insertingIntermediate(cache: false)
    .samplingLinear()
    .clampedToExtent()
    .applyingGaussianBlur(sigma: sigma)
    .cropped(to: frame)
}

/// [image] within [frame] in square blocks of [block] pixels, counted from
/// [anchor], the top-left corner of the area in Core Image's y-up space.
///
/// The frame is flipped into a top-origin space with [anchor] at its origin
/// for `pixelated`, as `applyVideoEffect` does with the frame's corner, and
/// flipped back afterwards.
private func censorPixelated(
  _ image: CIImage, block: Int, frame: CGRect, anchor: CGPoint
) -> CIImage {
  guard frame.width >= 1, frame.height >= 1 else { return image }

  let toTopOrigin = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -anchor.x, ty: anchor.y)
  let rect = frame.applying(toTopOrigin).integral
  let topOrigin = image.cropped(to: frame).samplingNearest().transformed(by: toTopOrigin)
  return pixelated(topOrigin, block: block, rect: rect)
    .transformed(by: toTopOrigin.inverted())
    .cropped(to: frame)
}
