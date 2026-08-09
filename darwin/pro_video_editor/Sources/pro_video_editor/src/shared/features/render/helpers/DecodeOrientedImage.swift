import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Decodes encoded image `data` into a `CIImage` with its EXIF orientation applied.
///
/// Callers hand the plugin whatever their photo library gave them, and a phone
/// stores a portrait shot as *landscape* pixels plus an `Orientation` tag saying
/// how to turn them. The obvious decoders disagree about that tag:
/// `UIImage(data:)` parses it but `.cgImage` hands back the stored pixels — so an
/// image built from it renders sideways — while `NSImage` bakes it in. Same
/// input, different output per platform.
///
/// `CGImageSource` is used instead because it never applies the tag on either
/// platform: it returns the stored pixels, and the orientation is applied here.
/// So iOS and macOS agree with each other and with Android, which normalizes the
/// same way in `ImageOrientation`. The contract is: an encoded image renders the
/// way the user sees it in their photo library.
///
/// Returns nil when the bytes do not decode.
func decodeOrientedImage(_ data: Data) -> CIImage? {
  return decodeOrientedImage(.bytes(data))
}

/// `decodeOrientedImage` for an image that may live on disk.
///
/// A file-backed image is decoded straight off its URL, so the encoded bytes
/// are never copied onto the heap on the way to ImageIO.
func decodeOrientedImage(_ image: EncodedImage) -> CIImage? {
  guard let source = image.imageSource else { return nil }
  return decodeOrientedImage(source: source)
}

/// The shared tail of both entry points, once a source has been opened.
func decodeOrientedImage(source: CGImageSource) -> CIImage? {
  guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

  let image = CIImage(cgImage: cgImage)
  let orientation = exifOrientation(of: source)
  guard orientation != .up else { return image }

  // The rotation can push the extent off its original origin, and callers read
  // `extent` as a plain size sitting at that origin, so put it back.
  let oriented = image.oriented(orientation)
  return oriented.transformed(
    by: CGAffineTransform(
      translationX: image.extent.origin.x - oriented.extent.origin.x,
      y: image.extent.origin.y - oriented.extent.origin.y))
}

/// The EXIF orientation `source` declares, or `.up` when it declares none.
private func exifOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
  guard
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let raw = properties[kCGImagePropertyOrientation] as? UInt32,
    let orientation = CGImagePropertyOrientation(rawValue: raw)
  else { return .up }
  return orientation
}
