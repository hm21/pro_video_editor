import AVFoundation
import CoreImage
import Foundation

/// A dip-to-color (fade-to-black / fade-to-white) window in composition time.
///
/// Used by the custom compositor to darken/whiten frames at clip boundaries for
/// `fadeToBlack` / `fadeToWhite` transitions.
public struct FadeWindow: Sendable {
  /// Inclusive start of the window in composition microseconds.
  let startUs: Int64
  /// Exclusive end of the window in composition microseconds.
  let endUs: Int64
  /// `true` = fade **in** from the dip color (color → video); `false` = fade
  /// **out** to the dip color (video → color).
  let fadeIn: Bool
  /// Easing curve name (e.g. "linear", "easeInOut").
  let curve: String
  /// `true` dips through white, `false` dips through black.
  let toWhite: Bool
}

/// Configuration properties used by a custom video compositor to apply visual effects.
///
/// Holds properties for geometry adjustments (rotation, scale, crop, flips), spatial blurring,
/// overlay asset placements, and lookup-table (LUT) dynamic color grading modifications.
public struct VideoCompositorConfig {
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

  /// Dip-to-color windows for `fadeToBlack` / `fadeToWhite` clip transitions.
  var fadeWindows: [FadeWindow] = []

  /// Chroma-key windows for the **single-track** path, one per clip that
  /// carries a key.
  ///
  /// Always empty on the layered path, where the key lives on each
  /// `LayerPlacement` instead: there, every layer is keyed on its own source
  /// frame before it reaches the canvas, and keying the composed (opaque)
  /// canvas afterwards would be meaningless.
  var chromaKeyWindows: [ChromaKeyWindow] = []

  var videoRotationDegrees: Double = 0.0
  var shouldApplyOrientationCorrection: Bool = false

  var preferredTransform: CGAffineTransform = .identity
  var originalNaturalSize: CGSize = .zero

  /// Whether to apply cropping to the image overlay along with the video.
  /// When true, the overlay is applied before cropping and gets cropped together with the video.
  /// When false (default), the overlay is scaled to the final cropped size.
  var imageBytesWithCropping: Bool = false

  /// Fallback source track ID for older iOS/macOS versions where sourceTrackIDs may be empty.
  /// This is used when the custom compositor doesn't receive track IDs properly from the instruction context.
  var sourceTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

  /// Exact output canvas size. When set, the composed frame is scaled to fit
  /// inside it (preserving aspect ratio), centered, and padded with black as a
  /// final step. Nil = keep the composed frame's own size.
  var outputResolution: CGSize? = nil
}
