import AVFoundation
import CoreImage
import Foundation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct ImageLayer {
  let image: CIImage
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
  /// Animations applied to this layer.
  let animations: [LayerAnimationConfig]
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

  /// Color filter configs for per-frame LUT computation
  private var colorFilterConfigs: [ColorFilterConfig] = []

  /// Dip-to-color windows for fadeToBlack / fadeToWhite clip transitions
  private var fadeWindows: [FadeWindow] = []

  /// Cache for computed LUTs keyed by active filter indices
  private let lutCacheQueue = DispatchQueue(label: "lut.cache.queue")
  private var lutCache: [String: (data: Data, size: Int)] = [:]
  private let defaultLutSize = 33

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

    self.setOverlayImageLayers(from: config.imageLayerConfigs)
    self.colorFilterConfigs = config.colorFilterConfigs
    self.fadeWindows = config.fadeWindows
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

      overlayImageLayers.append(
        ImageLayer(
          image: CIImage(cgImage: cgImage),
          startUs: layer.startUs,
          endUs: layer.endUs,
          x: layer.x,
          y: layer.y,
          width: layer.width,
          height: layer.height,
          animations: layer.animations
        ))
    }
  }

  /// Computes the LUT for a given set of active color filter indices.
  /// Results are cached so that each unique combination is only computed once.
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
    let cacheKey = activeIndices.map { String($0) }.joined(separator: ",")

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
    guard let data = generateLUTData(from: combined, size: defaultLutSize) else { return nil }

    let result = (data: data, size: defaultLutSize)
    lutCacheQueue.sync {
      lutCache[cacheKey] = result
    }
    return result
  }

  /// Applies the LUT for active color filters at the given composition time.
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
          var img = layer.image

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

          let (opacity, animTransform) = computeAnimation(
            layer: layer,
            currentTimeUs: currentTimeUs,
            overlayExtent: overlay.extent,
            frameExtent: imageRect
          )
          outputImage = compositeOverlay(
            overlay, over: outputImage, opacity: opacity, transform: animTransform)
        }
      }
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
          var img = layer.image

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

          let (opacity, animTransform) = computeAnimation(
            layer: layer,
            currentTimeUs: currentTimeUs,
            overlayExtent: overlay.extent,
            frameExtent: imageRect
          )
          outputImage = compositeOverlay(
            overlay, over: outputImage, opacity: opacity, transform: animTransform)
        }
      }
    }

    // Apply dip-to-color (fade-to-black / fade-to-white) clip transitions last,
    // so the entire composed frame (including overlays) dips uniformly.
    outputImage = applyFadeDip(to: outputImage, at: request.compositionTime)

    guard let outputBuffer = request.renderContext.newPixelBuffer() else {
      request.finish(with: NSError(domain: "VideoCompositor", code: -2, userInfo: nil))
      return
    }

    context.render(outputImage, to: outputBuffer)
    request.finish(withComposedVideoFrame: outputBuffer)
  }
}
