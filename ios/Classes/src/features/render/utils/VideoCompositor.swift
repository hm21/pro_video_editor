import AVFoundation
import CoreImage
import UIKit

struct ImageLayer {
    let image: CIImage
    let startUs: Int64
    let endUs: Int64
}

class VideoCompositor: NSObject, AVVideoCompositing {
    var blurSigma: Double = 0.0
    var overlayImage: CIImage?
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

    private let lutQueue = DispatchQueue(label: "lut.queue")
    private var _lutData: Data?
    private var _lutSize: Int = 33

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

        self.setOverlayImage(from: config.overlayImage)
        self.setOverlayImageLayers(from: config.imageLayerConfigs)
        self.setLUT(data: config.lutData, size: config.lutSize)
    }

    func setOverlayImage(from data: Data?) {
        guard let data,
            let uiImage = UIImage(data: data),
            let cgImage = uiImage.cgImage
        else {
            overlayImage = nil
            return
        }
        overlayImage = CIImage(cgImage: cgImage)
    }

    func setOverlayImageLayers(from layers: [ImageLayerConfig]) {
        overlayImageLayers = []
        for layer in layers {
            guard let uiImage = UIImage(data: layer.imageData),
                let cgImage = uiImage.cgImage
            else {
                continue
            }
            overlayImageLayers.append(ImageLayer(
                image: CIImage(cgImage: cgImage),
                startUs: layer.startUs,
                endUs: layer.endUs
            ))
        }
    }

    func clearLUT() {
        lutQueue.sync {
            _lutData = nil
        }
    }
    func setLUT(data: Data?, size: Int) {
        lutQueue.sync {
            _lutData = data
            _lutSize = size
        }
    }

    private func getLUT() -> (data: Data?, size: Int) {
        lutQueue.sync {
            (_lutData, _lutSize)
        }
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
           let instruction = request.videoCompositionInstruction as? AVMutableVideoCompositionInstruction,
           let layerInstruction = instruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
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
            request.finish(with: NSError(domain: "VideoCompositor", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No source tracks available for compositing (sourceTrackIDs: \(request.sourceTrackIDs.count), configTrackID: \(sourceTrackID))"
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
        
        // Extract layer instruction from either AVMutableVideoCompositionInstruction or CustomVideoCompositionInstruction
        var layerInstruction: AVMutableVideoCompositionLayerInstruction?
        if let customInstruction = request.videoCompositionInstruction as? CustomVideoCompositionInstruction,
           let firstLayerInstruction = customInstruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
            layerInstruction = firstLayerInstruction
        } else if let standardInstruction = request.videoCompositionInstruction as? AVMutableVideoCompositionInstruction,
                  let firstLayerInstruction = standardInstruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
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
                let convertedTransform = flipY
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
            // Apply LUT to video only
            let (lutData, lutSize) = getLUT()
            if let lutData,
                let lutFilter = CIFilter(name: "CIColorCube")
            {
                lutFilter.setValue(lutSize, forKey: "inputCubeDimension")
                lutFilter.setValue(lutData, forKey: "inputCubeData")
                lutFilter.setValue(outputImage, forKey: kCIInputImageKey)
                if let filteredImage = lutFilter.outputImage {
                    outputImage = filteredImage
                }
            }
            
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

            // Apply single overlay image if present
            if let overlay = overlayImage {
                let scaledOverlay = overlay.transformed(
                    by: CGAffineTransform(
                        scaleX: imageRect.width / overlay.extent.width,
                        y: imageRect.height / overlay.extent.height))
                outputImage = scaledOverlay.composited(over: outputImage)
            }

            // Apply time-based overlay layers
            let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)
            for layer in overlayImageLayers {
                // Check if current time is within the layer's time range
                // endUs of -1 means "until the end of the video"
                let inTimeRange = currentTimeUs >= layer.startUs &&
                                  (layer.endUs == -1 || currentTimeUs <= layer.endUs)

                if inTimeRange {
                    let scaledLayerOverlay = layer.image.transformed(
                        by: CGAffineTransform(
                            scaleX: imageRect.width / layer.image.extent.width,
                            y: imageRect.height / layer.image.extent.height))
                    outputImage = scaledLayerOverlay.composited(over: outputImage)
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

        // Apply LUT (only if NOT imageBytesWithCropping - otherwise already applied before overlay)
        if !imageBytesWithCropping {
            let (lutData, lutSize) = getLUT()
            if let lutData,
                let lutFilter = CIFilter(name: "CIColorCube")
            {
                lutFilter.setValue(lutSize, forKey: "inputCubeDimension")
                lutFilter.setValue(lutData, forKey: "inputCubeData")
                lutFilter.setValue(outputImage, forKey: kCIInputImageKey)
                if let filteredImage = lutFilter.outputImage {
                    outputImage = filteredImage
                }
            }

            // Apply blur
            if blurSigma > 0 {
                outputImage = outputImage.applyingGaussianBlur(sigma: blurSigma)
            }
        }

        // Apply overlay image (only if not already applied before crop)
        if !imageBytesWithCropping {
            let imageRect = outputImage.extent

            // Apply single overlay image if present
            if let overlay = overlayImage {
                let scaledOverlay = overlay.transformed(
                    by: CGAffineTransform(
                        scaleX: imageRect.width / overlay.extent.width,
                        y: imageRect.height / overlay.extent.height))
                outputImage = scaledOverlay.composited(over: outputImage)
            }

            // Apply time-based overlay layers
            let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)
            for layer in overlayImageLayers {
                // Check if current time is within the layer's time range
                // endUs of -1 means "until the end of the video"
                let inTimeRange = currentTimeUs >= layer.startUs &&
                                  (layer.endUs == -1 || currentTimeUs <= layer.endUs)

                if inTimeRange {
                    let scaledLayerOverlay = layer.image.transformed(
                        by: CGAffineTransform(
                            scaleX: imageRect.width / layer.image.extent.width,
                            y: imageRect.height / layer.image.extent.height))
                    outputImage = scaledLayerOverlay.composited(over: outputImage)
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
