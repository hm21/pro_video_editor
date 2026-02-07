import AVFoundation
import CoreImage
import UIKit

class VideoCompositor: NSObject, AVVideoCompositing {
    var blurSigma: Double = 0.0
    var overlayImage: CIImage?
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

        self.setOverlayImage(from: config.overlayImage)
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
        guard
            let sourceBuffer = request.sourceFrame(byTrackID: request.sourceTrackIDs[0].int32Value)
        else {
            request.finish(with: NSError(domain: "VideoCompositor", code: 0))
            return
        }
        var outputImage = CIImage(cvPixelBuffer: sourceBuffer)
        
        // 1: Apply layer instruction transform first (video scaling/centering)
        // This ensures all videos are properly sized before applying user effects. 
        // Note that's only required on macOS and iOS
        if let instruction = request.videoCompositionInstruction as? AVMutableVideoCompositionInstruction,
           let layerInstruction = instruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
            
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
                outputImage = outputImage.transformed(by: startTransform)
                
                // Normalize position to origin
                let transformedExtent = outputImage.extent
                if transformedExtent.origin.x != 0 || transformedExtent.origin.y != 0 {
                    let translation = CGAffineTransform(
                        translationX: -transformedExtent.origin.x,
                        y: -transformedExtent.origin.y
                    )
                    outputImage = outputImage.transformed(by: translation)
                }
            }
        }
        
        // 2: Apply orientation correction if needed
        if shouldApplyOrientationCorrection {
            let correctionAngle: Double

            switch Int(videoRotationDegrees.rounded()) {
            case 90:
                correctionAngle = -.pi / 2
            case -90, 270:
                correctionAngle = .pi / 2
            case 180, -180:
                correctionAngle = .pi
            default:
                correctionAngle = 0
            }

            if correctionAngle != 0 {
                let correctionTransform = CGAffineTransform(rotationAngle: correctionAngle)
                outputImage = outputImage.transformed(by: correctionTransform)

                let transformedExtent = outputImage.extent
                if transformedExtent.origin.x < 0 || transformedExtent.origin.y < 0 {
                    let translation = CGAffineTransform(
                        translationX: -transformedExtent.origin.x,
                        y: -transformedExtent.origin.y
                    )
                    outputImage = outputImage.transformed(by: translation)
                }
            }
        }

        var center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)

        // 3: Apply user-defined effects (crop, rotation, flip, scale)
        var transform = CGAffineTransform.identity
        
        // Apply overlay BEFORE crop if imageBytesWithCropping is enabled
        if imageBytesWithCropping, let overlay = overlayImage {
            let imageRect = outputImage.extent
            let scaledOverlay = overlay.transformed(
                by: CGAffineTransform(
                    scaleX: imageRect.width / overlay.extent.width,
                    y: imageRect.height / overlay.extent.height))
            outputImage = scaledOverlay.composited(over: outputImage)
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

        // Flipping
        if flipX || flipY {
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

        // Apply LUT
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

        // Apply overlay image (only if not already applied before crop)
        if !imageBytesWithCropping, let overlay = overlayImage {
            let imageRect = outputImage.extent
            let scaledOverlay = overlay.transformed(
                by: CGAffineTransform(
                    scaleX: imageRect.width / overlay.extent.width,
                    y: imageRect.height / overlay.extent.height))
            outputImage = scaledOverlay.composited(over: outputImage)
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VideoCompositor", code: -2, userInfo: nil))
            return
        }

        context.render(outputImage, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }
}
