import CoreImage
import Foundation

/// The images an image layer shows, one per frame of its animation.
///
/// A still image and the frames of an animated GIF are decoded up front. A
/// frame sequence is decoded as each frame comes on screen, holding one decoded
/// frame at a time. Decoded up front, every frame stayed in memory once it had
/// been drawn: a drawing that draws itself over six seconds, about 175 frames
/// of 1.4 megapixels each, held close to 2 GB on macOS by the end of the
/// render. A render asks for the frames in order, so each one is decoded once
/// per playthrough: once for a sequence that does not loop, again on every pass
/// of one that does.
final class LayerFrames: @unchecked Sendable {
  /// How many frames there are.
  let count: Int

  private let decoded: [CIImage]
  private let decode: ((Int) -> CIImage?)?
  private let lock = NSLock()
  private var shownIndex = 0
  private var shown: CIImage?

  /// Frames decoded up front: one still image, or the frames of an animated
  /// GIF.
  init(decoded: [CIImage]) {
    self.decoded = decoded
    count = decoded.count
    decode = nil
  }

  /// A frame sequence of `count` frames whose frame 0, `first`, is decoded
  /// already. `decode` decodes frame `index`, or returns nil when it does not
  /// decode; the frame shown before it then stays on screen.
  init(count: Int, first: CIImage, decode: @escaping (Int) -> CIImage?) {
    self.count = count
    decoded = []
    self.decode = decode
    shown = first
  }

  /// The image of frame `index`.
  ///
  /// Requests may arrive on several threads; a request that still draws the
  /// frame shown before keeps it alive until it is done.
  func frame(at index: Int) -> CIImage {
    guard let decode else { return decoded[index] }
    lock.lock()
    defer { lock.unlock() }
    if index != shownIndex {
      // Set first, so a frame that does not decode is not retried on every
      // video frame it covers.
      shownIndex = index
      if let next = decode(index) { shown = next }
    }
    return shown!
  }
}

extension LayerFrames: ExpressibleByArrayLiteral {
  /// Frames decoded up front, written as a list.
  convenience init(arrayLiteral elements: CIImage...) {
    self.init(decoded: elements)
  }
}
