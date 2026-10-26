import CoreImage
import Foundation
import ImageIO

/// Whether `layer` is a still image that looks the same on every frame it
/// shows: no animation, keyframe, censor, audio visualizer or shape mask, and
/// not an animated image.
///
/// A blended layer is drawn on its own as well: it combines with the picture
/// beneath it, which an image of static layers drawn over transparency does
/// not hold.
func isStaticImageLayer(_ layer: ImageLayerConfig) -> Bool {
  guard layer.audioVisualizer == nil, layer.censor == nil, layer.blendMode == .normal,
    layer.animations.isEmpty, layer.keyframes.isEmpty, layer.shapeMask == nil,
    let source = layer.image.imageSource
  else { return false }
  return CGImageSourceGetCount(source) == 1
}

/// How many layers from `start` on are drawn as one image: the static layers
/// (see `isStaticImageLayer`) in a row that share the time range of the one at
/// `start`. `0` when that one is not static.
func staticLayerRunLength(_ layers: [ImageLayerConfig], from start: Int) -> Int {
  let first = layers[start]
  guard isStaticImageLayer(first) else { return 0 }
  var end = start + 1
  while end < layers.count {
    let next = layers[end]
    guard next.startUs == first.startUs, next.endUs == first.endUs,
      isStaticImageLayer(next)
    else { break }
    end += 1
  }
  return end - start
}

/// Static layers in a row that share a time range, drawn as one image.
///
/// Every layer the compositor draws keeps its decoded image for the whole
/// render, so 200 stickers kept 200 decoded images of up to the frame's size
/// each. Drawn into one image of the frame, they keep one. The frame is only
/// known once a frame is composed and can differ between clips, so the image is
/// drawn the first time a frame of that extent needs it and kept for the frames
/// after it.
final class FlattenedLayers {
  let layers: [ImageLayerConfig]

  /// Images drawn so far, by the frame they were drawn for; `nil` when none of
  /// the layers decoded, so that is not tried again on every frame.
  private var images: [(frame: CGRect, image: CIImage?)] = []
  private let lock = NSLock()

  /// Frames of different extents kept at once. A render has one per clip
  /// size, so this only bounds an unusual one.
  static let maxFrames = 4

  init(layers: [ImageLayerConfig]) {
    self.layers = layers
  }

  /// The layers drawn into `frame`, drawn by `draw` the first time a frame of
  /// this extent needs them.
  func image(in frame: CGRect, draw: () -> CIImage?) -> CIImage? {
    lock.lock()
    defer { lock.unlock() }
    if let drawn = images.first(where: { $0.frame == frame }) { return drawn.image }
    let image = draw()
    images.append((frame, image))
    if images.count > Self.maxFrames { images.removeFirst() }
    return image
  }
}
