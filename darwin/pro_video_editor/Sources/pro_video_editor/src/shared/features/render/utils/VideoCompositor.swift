import AVFoundation
import CoreImage
import Foundation
import ImageIO

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct ImageLayer {
  /// Decoded frames: one for a static image, several for an animated GIF.
  let frames: [CIImage]
  /// Cumulative end time (µs) of each frame within one playthrough.
  let frameEndsUs: [Int64]
  /// Total duration (µs) of one playthrough; 0 for a static image.
  let totalDurationUs: Int64
  /// Whether an animated image repeats while the layer is visible.
  let loop: Bool
  let startUs: Int64
  let endUs: Int64
  /// x position in pixels. When nil, the image is stretched to fill the video frame.
  let x: Int64?
  /// y position in pixels. When nil, the image is stretched to fill the video frame.
  let y: Int64?
  /// Target width in pixels. When nil, the image is used at its original width.
  let width: Double?
  /// Target height in pixels. When nil, the image is used at its original height.
  let height: Double?
  /// Clockwise rotation around the layer center, in radians.
  let rotation: Double
  /// Animations applied to this layer.
  let animations: [LayerAnimationConfig]

  /// The frame to display at composition time [currentTimeUs].
  ///
  /// Static layers always return their single frame. Animated layers map the
  /// elapsed time (relative to the layer's start) onto the frame timeline,
  /// looping or holding the last frame depending on [loop].
  func currentFrame(atUs currentTimeUs: Int64) -> CIImage {
    if frames.count <= 1 || totalDurationUs <= 0 { return frames[0] }
    let effectiveStartUs = startUs == -1 ? 0 : startUs
    var t = currentTimeUs - effectiveStartUs
    if t < 0 { t = 0 }
    t = loop ? t % totalDurationUs : min(t, totalDurationUs - 1)
    for (index, end) in frameEndsUs.enumerated() where t < end {
      return frames[index]
    }
    return frames[frames.count - 1]
  }
}

/// Decodes an animated GIF into its frames and per-frame timeline.
///
/// Returns nil for non-animated sources (single frame / zero duration) so the
/// caller can fall back to a plain static decode.
private func decodeGifFrames(_ data: Data) -> (
  frames: [CIImage], frameEndsUs: [Int64], totalUs: Int64
)? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  let count = CGImageSourceGetCount(source)
  if count <= 1 { return nil }

  var frames: [CIImage] = []
  var frameEndsUs: [Int64] = []
  var accUs: Int64 = 0
  for index in 0..<count {
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
    accUs += Int64(gifFrameDelaySeconds(source, index) * 1_000_000)
    frames.append(CIImage(cgImage: cgImage))
    frameEndsUs.append(accUs)
  }
  if frames.count <= 1 || accUs <= 0 { return nil }
  return (frames, frameEndsUs, accUs)
}

/// Reads the on-screen delay (seconds) of GIF frame [index], clamping very
/// small/zero values to 0.1s as browsers do.
private func gifFrameDelaySeconds(_ source: CGImageSource, _ index: Int) -> Double {
  let fallback = 0.1
  guard
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
    let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
  else { return fallback }
  let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
  let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
  let delay = unclamped ?? clamped ?? fallback
  return delay < 0.011 ? fallback : delay
}

/// Rotates [overlay] clockwise by [radians] around its own center.
///
/// CoreImage uses a y-up coordinate space where a positive `rotationAngle`
/// turns counter-clockwise, so the sign is flipped to match the clockwise
/// (Flutter `Transform.rotate`) convention used by `ImageLayer.rotation`.
/// Rotating around the center keeps the layer's placement fixed while the
/// bounding box grows symmetrically.
private func rotateOverlayAroundCenter(_ overlay: CIImage, radians: Double) -> CIImage {
  if radians == 0 { return overlay }
  let cx = overlay.extent.midX
  let cy = overlay.extent.midY
  let transform = CGAffineTransform(translationX: cx, y: cy)
    .rotated(by: CGFloat(-radians))
    .translatedBy(x: -cx, y: -cy)
  return overlay.transformed(by: transform)
}

class VideoCompositor: NSObject, AVVideoCompositing {
  var blurSigma: Double = 0.0
  var overlayImageLayers: [ImageLayer] = []
  var imageBytesWithCropping: Bool = false

  var rotateRadians: Double = 0
  var rotateTurns: Int = 0
  var flipX: Bool = false
  var flipY: Bool = false
  var cropX: CGFloat = 0
  var cropY: CGFloat = 0
  var scaleX: CGFloat = 1
  var scaleY: CGFloat = 1
  var cropWidth: CGFloat?
  var cropHeight: CGFloat?

  // Properties for handling orientation variations
  var originalNaturalSize: CGSize = .zero

  /// Fallback source track ID for older OS versions
  var sourceTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

  /// Exact output canvas size; the composed frame is letterboxed into it.
  var outputResolution: CGSize? = nil

  /// Color filter configs for per-frame LUT computation
  private var colorFilterConfigs: [ColorFilterConfig] = []

  /// Dip-to-color windows for fadeToBlack / fadeToWhite clip transitions
  private var fadeWindows: [FadeWindow] = []

  /// Per-clip chroma-key windows (single-track path).
  private var chromaKeyWindows: [ChromaKeyWindow] = []

  /// Decoded chroma-key background images, keyed by config, so a background is
  /// decoded once per render rather than once per frame.
  private var chromaBackgroundCache: [String: CIImage] = [:]

  /// Cache for computed LUTs keyed by the active chroma key and filter indices
  private let lutCacheQueue = DispatchQueue(label: "lut.cache.queue")
  private var lutCache: [String: (data: Data, size: Int)] = [:]
  /// Insertion order of `lutCache`, so the oldest entry can be evicted.
  private var lutCacheOrder: [String] = []
  private let defaultLutSize = 33
  /// A 33³ cube is 574 KB; a long timeline with many distinct keys and filters
  /// would otherwise accumulate one per combination.
  private let lutCacheLimit = 8

  static var config = VideoCompositorConfig()

  required override init() {
    super.init()
    apply(Self.config)
  }

  var videoRotationDegrees: Double = 0.0
  var shouldApplyOrientationCorrection: Bool = false

  func apply(_ config: VideoCompositorConfig) {
    self.blurSigma = config.blurSigma
    self.rotateRadians = config.rotateRadians
    self.rotateTurns = config.rotateTurns
    self.flipX = config.flipX
    self.flipY = config.flipY
    self.cropX = config.cropX
    self.cropY = config.cropY
    self.cropWidth = config.cropWidth
    self.cropHeight = config.cropHeight
    self.scaleX = config.scaleX
    self.scaleY = config.scaleY
    self.imageBytesWithCropping = config.imageBytesWithCropping

    // Apply rotation metadata properties
    self.videoRotationDegrees = config.videoRotationDegrees
    self.shouldApplyOrientationCorrection = config.shouldApplyOrientationCorrection
    self.originalNaturalSize = config.originalNaturalSize
    self.sourceTrackID = config.sourceTrackID
    self.outputResolution = config.outputResolution

    self.setOverlayImageLayers(from: config.imageLayerConfigs)
    self.colorFilterConfigs = config.colorFilterConfigs
    self.fadeWindows = config.fadeWindows
    self.chromaKeyWindows = config.chromaKeyWindows
  }

  /// The chroma key active at the given composition time, if any.
  ///
  /// Windows are per clip and never overlap, so the first match wins.
  private func activeChromaKey(at compositionTime: CMTime) -> ChromaKeyConfig? {
    guard !chromaKeyWindows.isEmpty else { return nil }
    let tUs = Int64(CMTimeGetSeconds(compositionTime) * 1_000_000)
    for window in chromaKeyWindows
    where window.endUs > window.startUs && tUs >= window.startUs && tUs < window.endUs {
      return window.config
    }
    // The last frame of the timeline lands exactly on the final window's end,
    // so clamp to it rather than emitting one unkeyed frame.
    if let last = chromaKeyWindows.last, tUs >= last.endUs { return last.config }
    return nil
  }

  /// Applies a dip-to-color (fade-to-black / fade-to-white) at the given
  /// composition time, if any fade window is active. The video is mixed toward
  /// the dip color by `dipAmount` (0 = full video, 1 = full color).
  private func applyFadeDip(to image: CIImage, at compositionTime: CMTime) -> CIImage {
    guard !fadeWindows.isEmpty else { return image }
    let tUs = Int64(CMTimeGetSeconds(compositionTime) * 1_000_000)

    var dipAmount = 0.0
    var toWhite = false
    for w in fadeWindows where w.endUs > w.startUs && tUs >= w.startUs && tUs < w.endUs {
      let raw = Double(tUs - w.startUs) / Double(w.endUs - w.startUs)
      let eased = applyEasing(max(0, min(1, raw)), curve: w.curve)
      let amt = w.fadeIn ? (1.0 - eased) : eased
      if amt > dipAmount {
        dipAmount = amt
        toWhite = w.toWhite
      }
    }

    guard dipAmount > 0 else { return image }
    let s = CGFloat(1.0 - dipAmount)
    let b = toWhite ? CGFloat(dipAmount) : 0
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
      ])
  }

  func setOverlayImageLayers(from layers: [ImageLayerConfig]) {
    overlayImageLayers = []
    for layer in layers {
      let frames: [CIImage]
      let frameEndsUs: [Int64]
      let totalDurationUs: Int64

      if let gif = decodeGifFrames(layer.imageData) {
        // Animated GIF: keep every frame and its timeline.
        frames = gif.frames
        frameEndsUs = gif.frameEndsUs
        totalDurationUs = gif.totalUs
      } else {
        // Static image: decode the single frame.
        #if os(iOS)
          guard let uiImage = UIImage(data: layer.imageData),
            let cgImage = uiImage.cgImage
          else {
            continue
          }
        #elseif os(macOS)
          guard let nsImage = NSImage(data: layer.imageData),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
          else {
            continue
          }
        #endif
        frames = [CIImage(cgImage: cgImage)]
        frameEndsUs = [0]
        totalDurationUs = 0
      }

      overlayImageLayers.append(
        ImageLayer(
          frames: frames,
          frameEndsUs: frameEndsUs,
          totalDurationUs: totalDurationUs,
          loop: layer.loop,
          startUs: layer.startUs,
          endUs: layer.endUs,
          x: layer.x,
          y: layer.y,
          width: layer.width,
          height: layer.height,
          rotation: layer.rotation,
          animations: layer.animations
        ))
    }
  }

  /// Computes the color-filter cube active at the given composition time.
  ///
  /// Results are cached so each unique combination is built only once.
  private func getLUTForActiveFilters(at compositionTime: CMTime) -> (data: Data, size: Int)? {
    guard !colorFilterConfigs.isEmpty else { return nil }

    let currentTimeUs = Int64(CMTimeGetSeconds(compositionTime) * 1_000_000)

    var activeIndices: [Int] = []
    for (index, filter) in colorFilterConfigs.enumerated() {
      let inRange =
        (filter.startUs == -1 || currentTimeUs >= filter.startUs)
        && (filter.endUs == -1 || currentTimeUs <= filter.endUs)
      if inRange {
        activeIndices.append(index)
      }
    }

    guard !activeIndices.isEmpty else { return nil }
    let cacheKey = "cf:" + activeIndices.map { String($0) }.joined(separator: ",")

    // Check cache
    var cached: (data: Data, size: Int)?
    lutCacheQueue.sync {
      cached = lutCache[cacheKey]
    }
    if let cached = cached {
      return cached
    }

    let activeMatrices = activeIndices.map { colorFilterConfigs[$0].matrix }
    let combined = combineColorMatrices(activeMatrices)
    guard combined.count == 20 else { return nil }
    guard let data = generateLUTData(from: combined, size: defaultLutSize) else {
      return nil
    }

    let result = (data: data, size: defaultLutSize)
    lutCacheQueue.sync {
      if lutCache[cacheKey] == nil {
        lutCache[cacheKey] = result
        lutCacheOrder.append(cacheKey)
        while lutCacheOrder.count > lutCacheLimit {
          lutCache.removeValue(forKey: lutCacheOrder.removeFirst())
        }
      }
    }
    return result
  }

  /// Applies the active color cube at the given composition time.
  private func applyColorFilter(to image: CIImage, at compositionTime: CMTime) -> CIImage {
    guard let lut = getLUTForActiveFilters(at: compositionTime),
      let lutFilter = CIFilter(name: "CIColorCube")
    else {
      return image
    }
    lutFilter.setValue(lut.size, forKey: "inputCubeDimension")
    lutFilter.setValue(lut.data, forKey: "inputCubeData")
    lutFilter.setValue(image, forKey: kCIInputImageKey)
    return lutFilter.outputImage ?? image
  }

  /// Applies a chroma key as its own color cube.
  ///
  /// The cube encodes the whole key — matte alpha *and* despilled color — since
  /// both are pure functions of the input RGB. Entries are premultiplied, as
  /// `CIColorCube` requires. Cached like the color-filter cube.
  private func applyChromaKeyCube(to image: CIImage, _ config: ChromaKeyConfig) -> CIImage {
    let cacheKey = "ck:\(config.cacheKey)"

    var cached: (data: Data, size: Int)?
    lutCacheQueue.sync { cached = lutCache[cacheKey] }

    let lut: (data: Data, size: Int)
    if let cached = cached {
      lut = cached
    } else {
      guard
        let data = generateChromaLUTData(chroma: config, size: defaultLutSize)
      else { return image }
      lut = (data: data, size: defaultLutSize)
      lutCacheQueue.sync {
        if lutCache[cacheKey] == nil {
          lutCache[cacheKey] = lut
          lutCacheOrder.append(cacheKey)
          while lutCacheOrder.count > lutCacheLimit {
            lutCache.removeValue(forKey: lutCacheOrder.removeFirst())
          }
        }
      }
    }

    guard let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(lut.size, forKey: "inputCubeDimension")
    filter.setValue(lut.data, forKey: "inputCubeData")
    filter.setValue(image, forKey: kCIInputImageKey)
    return filter.outputImage ?? image
  }

  /// Removes the chroma key from a source frame and fills the keyed area.
  ///
  /// Runs on the **raw source frame**, before crop, rotation, flip and scale.
  /// Three reasons:
  ///
  /// 1. It is a single insertion point that covers both branches of the
  ///    `imageBytesWithCropping` split, where the color filter is duplicated.
  ///    Applying it inside `applyColorFilter` instead would place it before the
  ///    crop in one branch and after it in the other, so a background *image*
  ///    would be cropped along with the video in one case and not the other.
  /// 2. It matches the Android ordering exactly: there the chroma shader is
  ///    first in the per-clip chain and `SingleColorLut` grades whatever it
  ///    produced — so a color filter grades the substituted background too.
  ///    Folding the filter into the key's own cube instead would grade only the
  ///    video and leave the background at its raw color.
  /// 3. It keys unresampled pixels, which keeps the soft edge crisp.
  ///
  /// Chaining the color filter's own `CIColorCube` afterwards is safe precisely
  /// because the background has already been composited: the frame is opaque
  /// again, so the second cube resetting alpha from its own data changes
  /// nothing. Without a background it would un-key the frame — which is why the
  /// single-track path substitutes opaque black for a transparent key, and why
  /// the layered path keys inside `composeLayered` instead.
  private func applyChromaKeyStage(to image: CIImage, at compositionTime: CMTime)
    -> CIImage
  {
    guard let chroma = activeChromaKey(at: compositionTime) else { return image }
    return compositeChromaBackground(applyChromaKeyCube(to: image, chroma), chroma)
  }

  /// Fills the keyed-out area with the key's background.
  ///
  /// A nil background leaves the image transparent, which only carries meaning
  /// on the layered path — the single-track path substitutes opaque black long
  /// before this, in `CompositionBuilder.computeChromaKeyWindows`.
  private func compositeChromaBackground(_ image: CIImage, _ config: ChromaKeyConfig)
    -> CIImage
  {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return image }

    if let background = chromaBackgroundImage(for: config) {
      return image.composited(over: scaleToFill(background, extent))
    }

    guard config.backgroundColor != -1 else { return image }
    let argb = config.backgroundColor
    let color = CIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255.0,
      green: CGFloat((argb >> 8) & 0xFF) / 255.0,
      blue: CGFloat(argb & 0xFF) / 255.0,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255.0)
    return image.composited(over: CIImage(color: color).cropped(to: extent))
  }

  /// Stretches [image] to exactly cover [extent].
  ///
  /// Matches `ImageLayer`'s "no offset means stretch to the frame" semantics and
  /// the Android shader, which samples the background with the frame's own
  /// texture coordinates.
  private func scaleToFill(_ image: CIImage, _ extent: CGRect) -> CIImage {
    let source = image.extent
    guard source.width > 0, source.height > 0 else { return image }
    let scaled = image.transformed(
      by: CGAffineTransform(
        scaleX: extent.width / source.width, y: extent.height / source.height))
    return scaled.transformed(
      by: CGAffineTransform(
        translationX: extent.minX - scaled.extent.minX,
        y: extent.minY - scaled.extent.minY))
  }

  /// The decoded background image for [config], decoded once and cached.
  private func chromaBackgroundImage(for config: ChromaKeyConfig) -> CIImage? {
    guard let data = config.backgroundImageData else { return nil }
    if let cached = chromaBackgroundCache[config.cacheKey] { return cached }

    #if os(iOS)
      guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
    #elseif os(macOS)
      guard let image = NSImage(data: data),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return nil }
    #endif

    let ciImage = CIImage(cgImage: cgImage)
    chromaBackgroundCache[config.cacheKey] = ciImage
    return ciImage
  }

  private let context = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
  ])

  var sourcePixelBufferAttributes: [String: any Sendable]? = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
  ]

  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
  ]

  private var renderContext: AVVideoCompositionRenderContext?

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
  }

  /// Composites all layers of a layered instruction onto the composition canvas.
  ///
  /// Layers are drawn bottom-to-top over the instruction's background color.
  /// Each layer's source frame is oriented, scaled into its destination rect
  /// per its fit mode, clipped to that rect, and blended with its opacity.
  private func composeLayered(
    request: AVAsynchronousVideoCompositionRequest,
    instruction: CustomVideoCompositionInstruction
  ) -> CIImage? {
    let renderSize = request.renderContext.size
    let canvasHeight = renderSize.height

    let bg = instruction.backgroundColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    var canvas = CIImage(color: CIColor(cgColor: bg))
      .cropped(to: CGRect(origin: .zero, size: renderSize))

    for placement in instruction.layerPlacements {
      guard let buffer = request.sourceFrame(byTrackID: placement.trackID) else { continue }
      var img = CIImage(cvPixelBuffer: buffer)

      // 0. Remove this layer's chroma key on its raw source frame, before any
      //    orientation or scaling. A key without a background stays transparent
      //    here — unlike the single-track path, there really is something
      //    underneath, and step 5's composite lets it show through.
      if let key = placement.chromaKey {
        img = applyChromaKeyCube(to: img, key)
        img = compositeChromaBackground(img, key)
      }

      // 1. Orient using the source preferred transform (rotation + mirror
      //    metadata), then normalize the extent back to the origin.
      let preferred = placement.preferredTransform
      if !preferred.isIdentity {
        img = img.transformed(by: preferred)
        img = img.transformed(
          by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
      }

      let srcSize = img.extent.size
      guard srcSize.width > 0, srcSize.height > 0 else { continue }

      // 2. Destination rect in canvas pixels (top-left origin); nil = full canvas.
      let topLeftRect = placement.targetRect ?? CGRect(origin: .zero, size: renderSize)
      // Convert to CoreImage's bottom-left origin.
      let ciRect = CGRect(
        x: topLeftRect.minX,
        y: canvasHeight - topLeftRect.minY - topLeftRect.height,
        width: topLeftRect.width,
        height: topLeftRect.height)

      // 3. Scale per fit mode.
      let sxFill = ciRect.width / srcSize.width
      let syFill = ciRect.height / srcSize.height
      let sx: CGFloat
      let sy: CGFloat
      switch placement.fit {
      case "contain":
        let s = min(sxFill, syFill)
        sx = s
        sy = s
      case "cover":
        let s = max(sxFill, syFill)
        sx = s
        sy = s
      default:  // "fill"
        sx = sxFill
        sy = syFill
      }

      let scaledW = srcSize.width * sx
      let scaledH = srcSize.height * sy
      let tx = ciRect.minX + (ciRect.width - scaledW) / 2
      let ty = ciRect.minY + (ciRect.height - scaledH) / 2

      img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
      img = img.transformed(
        by: CGAffineTransform(
          translationX: tx - img.extent.origin.x, y: ty - img.extent.origin.y))

      // 4. Clip to the destination rect so "cover" overflow doesn't bleed.
      img = img.cropped(to: ciRect)

      // 5. Apply opacity and composite over the canvas.
      canvas = compositeOverlay(
        img, over: canvas, opacity: Double(placement.opacity), transform: .identity)
    }

    return canvas.cropped(to: CGRect(origin: .zero, size: renderSize))
  }

  /// Emits an opaque black frame as a last resort for a layered window that
  /// produced no image (e.g. a gap with no active layers).
  private func finishWithBackground(_ request: AVAsynchronousVideoCompositionRequest) {
    if let buffer = request.renderContext.newPixelBuffer() {
      CVPixelBufferLockBaseAddress(buffer, [])
      if let addr = CVPixelBufferGetBaseAddress(buffer) {
        memset(addr, 0, CVPixelBufferGetDataSize(buffer))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      request.finish(withComposedVideoFrame: buffer)
    } else {
      request.finish(with: NSError(domain: "VideoCompositor", code: -3, userInfo: nil))
    }
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    var outputImage: CIImage

    if let layeredInstruction = request.videoCompositionInstruction
      as? CustomVideoCompositionInstruction, layeredInstruction.isLayered
    {
      // Layered (multi-track) compositing path.
      guard let composed = composeLayered(request: request, instruction: layeredInstruction)
      else {
        finishWithBackground(request)
        return
      }
      outputImage = composed
    } else {
      // Single-track path: take one source frame and place it in the frame.
      // Try to get source buffer from the first available track
      var sourceBuffer: CVPixelBuffer?

      if !request.sourceTrackIDs.isEmpty {
        sourceBuffer = request.sourceFrame(byTrackID: request.sourceTrackIDs[0].int32Value)
      }

      // Fallback 1: Try to get track ID from layer instruction if sourceTrackIDs is empty
      // This can happen on older iOS versions (iPhone 7, iOS 15)
      if sourceBuffer == nil,
        let instruction = request.videoCompositionInstruction as? CustomVideoCompositionInstruction,
        let layerInstruction = instruction.layerInstructions.first
      {
        let trackID = layerInstruction.trackID
        if trackID != kCMPersistentTrackID_Invalid {
          sourceBuffer = request.sourceFrame(byTrackID: trackID)
        }
      }

      // Fallback 2: Use the pre-configured sourceTrackID from VideoCompositorConfig
      // This is set during composition building and guarantees we have the correct track ID
      if sourceBuffer == nil && sourceTrackID != kCMPersistentTrackID_Invalid {
        sourceBuffer = request.sourceFrame(byTrackID: sourceTrackID)
      }

      guard let sourceBuffer = sourceBuffer else {
        // Last-resort fallback: output a black frame rather than aborting the entire render.
        // This can happen for certain MP4 files where the container duration slightly exceeds
        // the video track's actual decoded frames, causing AVFoundation to call the compositor
        // for a time slot where no pixel buffer is available.
        if let ctx = renderContext, let blackBuffer = ctx.newPixelBuffer() {
          CVPixelBufferLockBaseAddress(blackBuffer, [])
          if let addr = CVPixelBufferGetBaseAddress(blackBuffer) {
            memset(addr, 0, CVPixelBufferGetDataSize(blackBuffer))
          }
          CVPixelBufferUnlockBaseAddress(blackBuffer, [])
          request.finish(withComposedVideoFrame: blackBuffer)
        } else {
          request.finish(
            with: NSError(
              domain: "VideoCompositor", code: 0,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "No source tracks available for compositing (sourceTrackIDs: \(request.sourceTrackIDs.count), configTrackID: \(sourceTrackID))"
              ]))
        }
        return
      }

      outputImage = CIImage(cvPixelBuffer: sourceBuffer)

      // Apply layer instruction transform first (video scaling/centering/rotation)
      // This ensures all videos are properly sized and oriented before applying user effects.
      // The layerInstruction contains the preferredTransform which already handles video rotation
      // from portrait to landscape or vice versa, so no additional orientation correction is needed.
      //
      // IMPORTANT: AVFoundation uses a top-left origin coordinate system (Y points down),
      // while CIImage uses a bottom-left origin (Y points up). We need to convert the transform
      // to work correctly with CIImage's coordinate system.

      // Extract layer instruction from CustomVideoCompositionInstruction
      var layerInstruction: AVVideoCompositionLayerInstruction?
      if let customInstruction = request.videoCompositionInstruction
        as? CustomVideoCompositionInstruction,
        let firstLayerInstruction = customInstruction.layerInstructions.first
      {
        layerInstruction = firstLayerInstruction
      }

      if let layerInstruction = layerInstruction {
        var startTransform = CGAffineTransform.identity
        var endTransform = CGAffineTransform.identity
        var timeRange = CMTimeRange.zero

        // Get the transform at the current composition time
        let hasTransform = layerInstruction.getTransformRamp(
          for: request.compositionTime,
          start: &startTransform,
          end: &endTransform,
          timeRange: &timeRange
        )

        if hasTransform && !startTransform.isIdentity {
          // Convert AVFoundation transform to CIImage coordinate system:
          // 1. Flip Y axis before transform (go from CIImage coords to AVFoundation coords)
          // 2. Apply the AVFoundation transform
          // 3. Flip Y axis after transform (go back to CIImage coords)
          let imageHeight = outputImage.extent.height

          // Flip Y: translate to top, scale Y by -1
          let flipY = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -imageHeight)

          // Convert transform: flipY * transform * flipY^-1
          // But since flipY is its own inverse (when combined with translate), we use:
          // result = flipY * transform * flipY (adjusted for new height after transform)
          let convertedTransform =
            flipY
            .concatenating(startTransform)

          outputImage = outputImage.transformed(by: convertedTransform)

          // After transform, we need to flip back and normalize
          let transformedExtent = outputImage.extent
          let newHeight = transformedExtent.height
          let flipBack = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -newHeight)

          outputImage = outputImage.transformed(by: flipBack)

          // Normalize position to origin
          let finalExtent = outputImage.extent
          if finalExtent.origin.x != 0 || finalExtent.origin.y != 0 {
            let translation = CGAffineTransform(
              translationX: -finalExtent.origin.x,
              y: -finalExtent.origin.y
            )
            outputImage = outputImage.transformed(by: translation)
          }
        }
      }
    }

    // Remove the chroma key on the raw source frame, before any geometry, and
    // fill the keyed area with its background. One insertion point for both
    // branches of the imageBytesWithCropping split below.
    outputImage = applyChromaKeyStage(to: outputImage, at: request.compositionTime)

    var center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)

    // Apply user-defined effects (crop, rotation, flip, scale)
    var transform = CGAffineTransform.identity

    // Apply LUT, blur, and flip BEFORE overlay when imageBytesWithCropping is enabled
    // This ensures these effects only affect the video, not the overlay
    if imageBytesWithCropping {
      // Apply color filter (timed LUT) to video only
      outputImage = applyColorFilter(to: outputImage, at: request.compositionTime)

      // Apply blur to video only
      if blurSigma > 0 {
        outputImage = outputImage.applyingGaussianBlur(sigma: blurSigma)
      }

      // Apply flip to video only (before adding overlay)
      if flipX || flipY {
        let flipScaleX: CGFloat = flipX ? -1 : 1
        let flipScaleY: CGFloat = flipY ? -1 : 1

        let flipTransform = CGAffineTransform(translationX: center.x, y: center.y)
          .scaledBy(x: flipScaleX, y: flipScaleY)
          .translatedBy(x: -center.x, y: -center.y)

        outputImage = outputImage.transformed(by: flipTransform)

        // Normalize position after flip
        let flippedExtent = outputImage.extent
        if flippedExtent.origin.x != 0 || flippedExtent.origin.y != 0 {
          let translation = CGAffineTransform(
            translationX: -flippedExtent.origin.x,
            y: -flippedExtent.origin.y
          )
          outputImage = outputImage.transformed(by: translation)
        }
        center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)
      }
    }

    // Apply overlay BEFORE crop if imageBytesWithCropping is enabled
    if imageBytesWithCropping {
      let imageRect = outputImage.extent

      // Apply time-based overlay layers
      let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)
      for layer in overlayImageLayers {
        let inTimeRange =
          (layer.startUs == -1 || currentTimeUs >= layer.startUs)
          && (layer.endUs == -1 || currentTimeUs <= layer.endUs)

        if inTimeRange {
          var img = layer.currentFrame(atUs: currentTimeUs)

          if let w = layer.width, let h = layer.height {
            let sx = CGFloat(w) / img.extent.width
            let sy = CGFloat(h) / img.extent.height
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
          }

          let overlay: CIImage
          if layer.x == nil && layer.y == nil {
            overlay = img.transformed(
              by: CGAffineTransform(
                scaleX: imageRect.width / img.extent.width,
                y: imageRect.height / img.extent.height))
          } else {
            let posX = CGFloat(layer.x ?? 0)
            let posY = CGFloat(layer.y ?? 0)
            let cgY = imageRect.height - posY - img.extent.height
            overlay = img.transformed(
              by: CGAffineTransform(translationX: posX, y: cgY))
          }

          let rotated = rotateOverlayAroundCenter(overlay, radians: layer.rotation)
          let (opacity, animTransform) = computeAnimation(
            layer: layer,
            currentTimeUs: currentTimeUs,
            overlayExtent: rotated.extent,
            frameExtent: imageRect
          )
          outputImage = compositeOverlay(
            rotated, over: outputImage, opacity: opacity, transform: animTransform)
        }
      }

      // Clip overlay content that animated beyond the frame back to the frame
      // extent so a subsequent crop and the final render operate on the exact
      // video frame, not an extent inflated by an off-frame overlay.
      outputImage = outputImage.cropped(to: imageRect)
    }

    // Cropping
    if cropX != 0 || cropY != 0 || cropWidth != nil || cropHeight != nil {
      let inputExtent = outputImage.extent
      let videoWidth = inputExtent.width
      let videoHeight = inputExtent.height

      let x = cropX
      var y = cropY
      let width = cropWidth ?? (videoWidth - x)
      let height = cropHeight ?? (videoHeight - y)

      y = videoHeight - height - y

      let cropRect = CGRect(x: x, y: y, width: width, height: height)

      outputImage = outputImage.cropped(to: cropRect)
      outputImage = outputImage.transformed(
        by: CGAffineTransform(
          translationX: -cropRect.origin.x,
          y: -cropRect.origin.y

        ))
      center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)
    }

    // Rotation
    if rotateRadians != 0 {
      // Rotate the image
      let rotation = CGAffineTransform(rotationAngle: rotateRadians)
      let rotatedImage = outputImage.transformed(by: rotation)

      // Get the new bounding box after rotation
      let rotatedExtent = rotatedImage.extent

      // Translate to (0, 0)
      let translation = CGAffineTransform(
        translationX: -rotatedExtent.origin.x, y: -rotatedExtent.origin.y)
      outputImage = rotatedImage.transformed(by: translation)
      center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)
    }

    // Flipping (only if NOT imageBytesWithCropping - otherwise already applied before overlay)
    if !imageBytesWithCropping && (flipX || flipY) {
      let scaleX: CGFloat = flipX ? -1 : 1
      let scaleY: CGFloat = flipY ? -1 : 1

      let flipTransform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: scaleX, y: scaleY)
        .translatedBy(x: -center.x, y: -center.y)

      transform = transform.concatenating(flipTransform)
    }

    // Apply Scale
    if scaleX != 1 || scaleY != 1 {
      transform = transform.scaledBy(x: scaleX, y: scaleY)
    }

    outputImage = outputImage.transformed(by: transform)

    // Apply color filter (only if NOT imageBytesWithCropping - otherwise already applied before overlay)
    if !imageBytesWithCropping {
      outputImage = applyColorFilter(to: outputImage, at: request.compositionTime)

      // Apply blur
      if blurSigma > 0 {
        outputImage = outputImage.applyingGaussianBlur(sigma: blurSigma)
      }
    }

    // Apply overlay image layers (only if not already applied before crop)
    if !imageBytesWithCropping {
      let imageRect = outputImage.extent

      let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)
      for layer in overlayImageLayers {
        let inTimeRange =
          (layer.startUs == -1 || currentTimeUs >= layer.startUs)
          && (layer.endUs == -1 || currentTimeUs <= layer.endUs)
        if inTimeRange {
          var img = layer.currentFrame(atUs: currentTimeUs)

          if let w = layer.width, let h = layer.height {
            let sx = CGFloat(w) / img.extent.width
            let sy = CGFloat(h) / img.extent.height
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
          }

          let overlay: CIImage
          if layer.x == nil && layer.y == nil {
            overlay = img.transformed(
              by: CGAffineTransform(
                scaleX: imageRect.width / img.extent.width,
                y: imageRect.height / img.extent.height))
          } else {
            let posX = CGFloat(layer.x ?? 0)
            let posY = CGFloat(layer.y ?? 0)
            let cgY = imageRect.height - posY - img.extent.height
            overlay = img.transformed(
              by: CGAffineTransform(translationX: posX, y: cgY))
          }

          let rotated = rotateOverlayAroundCenter(overlay, radians: layer.rotation)
          let (opacity, animTransform) = computeAnimation(
            layer: layer,
            currentTimeUs: currentTimeUs,
            overlayExtent: rotated.extent,
            frameExtent: imageRect
          )
          outputImage = compositeOverlay(
            rotated, over: outputImage, opacity: opacity, transform: animTransform)
        }
      }

      // Clip any overlay content that animated beyond the frame (e.g. a layer
      // sliding in from an edge) back to the video frame, so the composed
      // extent stays exactly the frame size. Otherwise the inflated extent
      // shifts and shrinks the frame in `letterbox` when a custom output
      // resolution is set — briefly showing a black bar at the frame edge.
      outputImage = outputImage.cropped(to: imageRect)
    }

    // Apply dip-to-color (fade-to-black / fade-to-white) clip transitions last,
    // so the entire composed frame (including overlays) dips uniformly.
    outputImage = applyFadeDip(to: outputImage, at: request.compositionTime)

    // Letterbox into the exact output canvas when a custom resolution was
    // requested: scale to fit (preserving aspect ratio), center, pad with black.
    if let target = outputResolution {
      outputImage = letterbox(outputImage, into: target)
    }

    guard let outputBuffer = request.renderContext.newPixelBuffer() else {
      request.finish(with: NSError(domain: "VideoCompositor", code: -2, userInfo: nil))
      return
    }

    context.render(outputImage, to: outputBuffer)
    request.finish(withComposedVideoFrame: outputBuffer)
  }

  /// Scales [image] to fit inside [target] (preserving aspect ratio), centers
  /// it, and composites it over an opaque black canvas of exactly [target] size.
  private func letterbox(_ image: CIImage, into target: CGSize) -> CIImage {
    let src = image.extent
    guard src.width > 0, src.height > 0, target.width > 0, target.height > 0
    else { return image }

    let scale = min(target.width / src.width, target.height / src.height)
    let scaledWidth = src.width * scale
    let scaledHeight = src.height * scale
    // Scale around the origin, then translate the scaled content's origin to the
    // centered position within the target canvas.
    let translateX = (target.width - scaledWidth) / 2 - src.origin.x * scale
    let translateY = (target.height - scaledHeight) / 2 - src.origin.y * scale
    let transform = CGAffineTransform(scaleX: scale, y: scale)
      .concatenating(CGAffineTransform(translationX: translateX, y: translateY))

    let scaled = image.transformed(by: transform)
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
      .cropped(to: CGRect(origin: .zero, size: target))
    return scaled.composited(over: black)
  }
}
