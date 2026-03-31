import AVFoundation
import CoreImage
import UIKit

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

    // New properties for handling iPhone orientation
    var originalNaturalSize: CGSize = .zero

    /// Fallback source track ID for older iOS versions
    var sourceTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Color filter configs for per-frame LUT computation
    private var colorFilterConfigs: [ColorFilterConfig] = []

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

    // Update the apply function:
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
    }

    func setOverlayImageLayers(from layers: [ImageLayerConfig]) {
        overlayImageLayers = []
        for layer in layers {
            guard let uiImage = UIImage(data: layer.imageData),
                let cgImage = uiImage.cgImage
            else {
                continue
            }
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

        // Determine which filters are active at this time
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

        // Compute LUT for active filters
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

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Try to get source buffer from the first available track
        var sourceBuffer: CVPixelBuffer?

        if !request.sourceTrackIDs.isEmpty {
            sourceBuffer = request.sourceFrame(byTrackID: request.sourceTrackIDs[0].int32Value)
        }

        // Fallback 1: Try to get track ID from layer instruction if sourceTrackIDs is empty
        // This can happen on older iOS versions (iPhone 7, iOS 15)
        if sourceBuffer == nil,
            let instruction = request.videoCompositionInstruction
                as? CustomVideoCompositionInstruction,
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
            request.finish(
                with: NSError(
                    domain: "VideoCompositor", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No source tracks available for compositing (sourceTrackIDs: \(request.sourceTrackIDs.count), configTrackID: \(sourceTrackID))"
                    ]))
            return
        }
        var outputImage = CIImage(cvPixelBuffer: sourceBuffer)

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
                // Check if current time is within the layer's time range
                // startUs of -1 means "from the start of the video"
                // endUs of -1 means "until the end of the video"
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
                        // Stretch to fill frame when no position is specified
                        overlay = img.transformed(
                            by: CGAffineTransform(
                                scaleX: imageRect.width / img.extent.width,
                                y: imageRect.height / img.extent.height))
                    } else {
                        // Position at specific coordinates
                        let posX = CGFloat(layer.x ?? 0)
                        let posY = CGFloat(layer.y ?? 0)
                        // Convert y from top-left (Dart) to bottom-left (Core Graphics)
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

            // Apply time-based overlay layers with positioning
            let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)
            for layer in overlayImageLayers {
                // Check if current time is within the layer's time range
                // startUs of -1 means "from the start of the video"
                // endUs of -1 means "until the end of the video"
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
                        // Stretch to fill frame when no position is specified
                        overlay = img.transformed(
                            by: CGAffineTransform(
                                scaleX: imageRect.width / img.extent.width,
                                y: imageRect.height / img.extent.height))
                    } else {
                        // Position at specific coordinates
                        let posX = CGFloat(layer.x ?? 0)
                        let posY = CGFloat(layer.y ?? 0)
                        // Convert y from top-left (Dart) to bottom-left (Core Graphics)
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

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VideoCompositor", code: -2, userInfo: nil))
            return
        }

        context.render(outputImage, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }
}
