import AVFoundation
import CoreImage

struct VideoCompositorConfig {
    var blurSigma: Double = 0.0
    var imageLayerConfigs: [ImageLayerConfig] = []

    var rotateRadians: Double = 0.0
    var rotateTurns: Int = 0
    var flipX: Bool = false
    var flipY: Bool = false

    var cropX: CGFloat = 0.0
    var cropY: CGFloat = 0.0
    var cropWidth: CGFloat? = nil
    var cropHeight: CGFloat? = nil

    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0

    /// Color filter configs with optional time ranges for per-frame LUT switching.
    var colorFilterConfigs: [ColorFilterConfig] = []

    var videoRotationDegrees: Double = 0.0
    var shouldApplyOrientationCorrection: Bool = false

    var preferredTransform: CGAffineTransform = .identity
    var originalNaturalSize: CGSize = .zero

    /// Whether to apply cropping to the image overlay along with the video.
    /// When true, the overlay is applied before cropping and gets cropped together with the video.
    /// When false (default), the overlay is scaled to the final cropped size.
    var imageBytesWithCropping: Bool = false

    /// Fallback source track ID for older macOS versions where sourceTrackIDs may be empty.
    /// This is used when the custom compositor doesn't receive track IDs properly.
    var sourceTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
}
