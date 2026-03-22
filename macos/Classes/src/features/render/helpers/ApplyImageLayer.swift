import AVFoundation
import AppKit
import CoreImage

/// Applies an overlay image on top of video frames.
///
/// The image is composited over each video frame during rendering. The image
/// should be provided as encoded data (PNG, JPEG, etc.) and will be decoded
/// by the video compositor.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - imageData: Encoded image data. If nil, no overlay is applied.
///   - imageLayers: List of image layers with timing information.
///   - withCropping: When true, the overlay is applied before cropping and gets cropped
///                   together with the video. When false (default), the overlay is scaled
///                   to the final cropped size.
///
/// - Note: The image is positioned and scaled by the video compositor according
///         to its own logic (typically centered or full-frame).
func applyImageLayer(
    config: inout VideoCompositorConfig,
    imageData: Data?,
    imageLayers: [ImageLayerConfig],
    withCropping: Bool = false
) {
    config.overlayImage = imageData
    config.imageLayerConfigs = imageLayers
    config.imageBytesWithCropping = withCropping

    if let data = imageData {
        let sizeKB = Double(data.count) / 1024.0
        print("[\(Tags.render)] 🖼️ Applying overlay image (\(String(format: "%.1f", sizeKB)) KB, withCropping: \(withCropping))")
    }

    if !imageLayers.isEmpty {
        print("[\(Tags.render)] 🖼️ Applying \(imageLayers.count) image layer(s) with timing")
    }
}
