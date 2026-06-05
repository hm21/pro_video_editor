import AVFoundation
import CoreImage
import Foundation

/// Applies image layers on top of video frames.
///
/// Each image layer is composited over video frames during rendering within its
/// specified time range. Images should be provided as encoded data (PNG, JPEG, etc.)
/// and will be decoded by the video compositor.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - imageLayers: List of image layers with timing and positioning information.
///   - withCropping: When true, the overlay is applied before cropping and gets cropped
///                   together with the video. When false (default), the overlay is scaled
///                   to the final cropped size.
///
/// - Note: The image is positioned and scaled by the video compositor according
///         to its own logic (typically centered or full-frame).
public func applyImageLayer(
    config: inout VideoCompositorConfig,
    imageLayers: [ImageLayerConfig],
    withCropping: Bool = false
) {
    config.imageLayerConfigs = imageLayers
    config.imageBytesWithCropping = withCropping

    if !imageLayers.isEmpty {
        PluginLog.print(
            "[\(Tags.render)] 🖼️ Applying \(imageLayers.count) image layer(s) with timing")
    }
}
