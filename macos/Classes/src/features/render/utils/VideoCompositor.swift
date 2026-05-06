import AVFoundation
import AppKit
import CoreImage

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

    var originalNaturalSize: CGSize = .zero
    var intendedRenderSize: CGSize = .zero

    /// Fallback source track ID for older macOS versions
    var sourceTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Track configurations for multi-track compositing
    var videoClipConfigs: [CMPersistentTrackID: VideoClip] = [:]

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
        self.intendedRenderSize = config.intendedRenderSize
        self.sourceTrackID = config.sourceTrackID
        self.videoClipConfigs = config.videoClipConfigs

        self.setOverlayImageLayers(from: config.imageLayerConfigs)
        self.colorFilterConfigs = config.colorFilterConfigs
    }

    func setOverlayImageLayers(from layers: [ImageLayerConfig]) {
        overlayImageLayers = []
        for layer in layers {
            guard let nsImage = NSImage(data: layer.imageData),
                let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
        let renderSize = request.renderContext.size
        let currentTimeUs = Int64(CMTimeGetSeconds(request.compositionTime) * 1_000_000)

        // Calculate scale factors between intended logical resolution and actual render size.
        // This handles cases where AVAssetExportSession forces a different resolution
        // (e.g. 1080p preset for a 4K composition).
        let scaleFactorX = intendedRenderSize.width > 0 ? renderSize.width / intendedRenderSize.width : 1.0
        let scaleFactorY = intendedRenderSize.height > 0 ? renderSize.height / intendedRenderSize.height : 1.0

        // 1. Define a common structure for all renderable items
        enum RenderableItem {
            case video(image: CIImage, clip: VideoClip, trackID: CMPersistentTrackID)
            case imageLayer(layer: ImageLayer)

            var zIndex: Int {
                switch self {
                    case .video(_, let clip, _): return clip.zIndex ?? 0
                    case .imageLayer: return Int.max
                }
            }
        }

        var items: [RenderableItem] = []

        // 2. Collect active video frames
        for trackIDValue in request.sourceTrackIDs {
            let trackID = trackIDValue.int32Value
            if let sourceBuffer = request.sourceFrame(byTrackID: trackID),
               let clipConfig = videoClipConfigs[trackID] {

                var frameImage = CIImage(cvPixelBuffer: sourceBuffer)

                // Apply individual track transform from layer instructions
                if let customInstruction = request.videoCompositionInstruction as? CustomVideoCompositionInstruction {
                    for layerInstruction in customInstruction.layerInstructions {
                        if layerInstruction.trackID == trackID {
                            var startTransform = CGAffineTransform.identity
                            var endTransform = CGAffineTransform.identity
                            var timeRange = CMTimeRange.zero

                            let hasTransform = layerInstruction.getTransformRamp(
                                for: request.compositionTime,
                                start: &startTransform,
                                end: &endTransform,
                                timeRange: &timeRange
                            )

                            if hasTransform && !startTransform.isIdentity {
                                let imageHeight = frameImage.extent.height
                                let flipY = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -imageHeight)
                                let convertedTransform = flipY.concatenating(startTransform)
                                frameImage = frameImage.transformed(by: convertedTransform)

                                let transformedExtent = frameImage.extent
                                let flipBack = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -transformedExtent.height)
                                frameImage = frameImage.transformed(by: flipBack)

                                // Normalize
                                let finalExtent = frameImage.extent
                                if finalExtent.origin.x != 0 || finalExtent.origin.y != 0 {
                                    frameImage = frameImage.transformed(by: CGAffineTransform(translationX: -finalExtent.origin.x, y: -finalExtent.origin.y))
                                }
                            }
                            break
                        }
                    }
                }

                items.append(.video(image: frameImage, clip: clipConfig, trackID: trackID))
            }
        }

        // 3. Collect active image layers
        for layer in overlayImageLayers {
            let inRange = (layer.startUs == -1 || currentTimeUs >= layer.startUs) && (layer.endUs == -1 || currentTimeUs <= layer.endUs)
            if inRange {
                items.append(.imageLayer(layer: layer))
            }
        }

        if items.isEmpty {
            PluginLog.print("⚠️ VideoCompositor: No active items found at time \(request.compositionTime.seconds)s")
            request.finish(with: NSError(domain: "VideoCompositor", code: 0, userInfo: [NSLocalizedDescriptionKey: "No active items found"]))
            return
        }

        // 4. Sort all items by zIndex
        let sortedItems = items.sorted { $0.zIndex < $1.zIndex }

        // 5. Initialize background image (black frame)
        var outputImage = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))

        // 6. Composite each item
        for item in sortedItems {
            switch item {
            case .video(let img, let clip, _):
                var frameImg = img

                // Apply custom size if provided, otherwise scale by global factor
                if let w = clip.width, let h = clip.height {
                    let targetW = CGFloat(w) * scaleFactorX
                    let targetH = CGFloat(h) * scaleFactorY
                    let sx = targetW / frameImg.extent.width
                    let sy = targetH / frameImg.extent.height
                    frameImg = frameImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                } else if scaleFactorX != 1.0 || scaleFactorY != 1.0 {
                    frameImg = frameImg.transformed(by: CGAffineTransform(scaleX: scaleFactorX, y: scaleFactorY))
                }

                // Apply custom offset if provided
                if clip.x != nil || clip.y != nil {
                    let posX = CGFloat(clip.x ?? 0) * scaleFactorX
                    let posY = CGFloat(clip.y ?? 0) * scaleFactorY
                    // Convert from top-left (Flutter) to bottom-left (Core Image)
                    let cgY = renderSize.height - posY - frameImg.extent.height
                    frameImg = frameImg.transformed(by: CGAffineTransform(translationX: posX, y: cgY))
                } else if scaleFactorX != 1.0 || scaleFactorY != 1.0 {
                    // Normalize position if we scaled but didn't translate manually
                    let extent = frameImg.extent
                    if extent.origin.x != 0 || extent.origin.y != 0 {
                        frameImg = frameImg.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
                    }
                }

                // Apply opacity if needed
                if let opacity = clip.opacity, opacity < 1.0 {
                    frameImg = frameImg.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                    ])
                }

                outputImage = frameImg.composited(over: outputImage)

            case .imageLayer(let layer):
                var layerImg = layer.image
                if let w = layer.width, let h = layer.height {
                    let targetW = CGFloat(w) * scaleFactorX
                    let targetH = CGFloat(h) * scaleFactorY
                    layerImg = layerImg.transformed(by: CGAffineTransform(scaleX: targetW/layerImg.extent.width, y: targetH/layerImg.extent.height))
                }

                let overlay: CIImage
                if layer.x == nil && layer.y == nil {
                    overlay = layerImg.transformed(by: CGAffineTransform(scaleX: renderSize.width/layerImg.extent.width, y: renderSize.height/layerImg.extent.height))
                } else {
                    let posX = CGFloat(layer.x ?? 0) * scaleFactorX
                    let posY = CGFloat(layer.y ?? 0) * scaleFactorY
                    let cgY = renderSize.height - posY - layerImg.extent.height
                    overlay = layerImg.transformed(by: CGAffineTransform(translationX: posX, y: cgY))
                }

                let (opacity, animTransform) = computeAnimation(layer: layer, currentTimeUs: currentTimeUs, overlayExtent: overlay.extent, frameExtent: CGRect(origin: .zero, size: renderSize))
                outputImage = compositeOverlay(overlay, over: outputImage, opacity: opacity, transform: animTransform)
            }
        }

        // 7. Apply global effects (if any)
        let center = CGPoint(x: outputImage.extent.midX, y: outputImage.extent.midY)
        var transform = CGAffineTransform.identity

        // Apply flip (Global)
        if flipX || flipY {
            let scaleX: CGFloat = flipX ? -1 : 1
            let scaleY: CGFloat = flipY ? -1 : 1
            transform = transform.concatenating(CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: scaleX, y: scaleY)
                .translatedBy(x: -center.x, y: -center.y))
        }

        // Apply Global Scale
        if scaleX != 1 || scaleY != 1 {
            transform = transform.scaledBy(x: scaleX, y: scaleY)
        }

        outputImage = outputImage.transformed(by: transform)

        // Apply LUT and Blur (Global)
        outputImage = applyColorFilter(to: outputImage, at: request.compositionTime)
        if blurSigma > 0 {
            outputImage = outputImage.applyingGaussianBlur(sigma: blurSigma)
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VideoCompositor", code: -2, userInfo: nil))
            return
        }

        context.render(outputImage, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }
}
