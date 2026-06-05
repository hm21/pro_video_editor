import AVFoundation

/// Applies Gaussian blur effect to video frames.
///
/// The blur is implemented using Core Image's CIGaussianBlur filter during composition.
/// The sigma value is scaled by 2.5 to achieve the desired visual effect.
///
/// - Parameters:
///   - config: Video compositor configuration to modify.
///   - sigma: Blur radius. Higher values = more blur. 0 or nil = no blur.
///
/// - Note: The actual blur is applied by the video compositor during rendering.
func applyBlur(
    config: inout VideoCompositorConfig,
    sigma: Double?
) {
    config.blurSigma = (sigma ?? 0) * 2.5

    if sigma == nil || sigma == 0 { return }

    PluginLog.print("[\(Tags.render)] 🌫️ Applying Gaussian blur: sigma=\(String(format: "%.1f", sigma!))")
}
