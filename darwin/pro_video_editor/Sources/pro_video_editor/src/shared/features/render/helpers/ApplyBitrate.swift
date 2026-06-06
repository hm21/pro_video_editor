import AVFoundation
import Foundation

/// Determines the appropriate AVAssetExportSession preset based on requested bitrate.
///
/// Since AVAssetExportSession doesn't support direct bitrate control, this function
/// maps bitrate values to the closest quality preset. Higher bitrates select higher
/// resolution/quality presets.
///
/// - Parameters:
///   - requestedBitrate: Target bitrate in bits per second. If nil, returns preset hint or highest quality.
///   - presetHint: Optional preset to use as fallback. If nil, defaults to highest quality.
/// - Returns: AVAssetExportPreset string matching the requested quality level.
///
/// Bitrate mapping:
/// - ≥50 Mbps: 8K HEVC (macOS 12.1+) or 4K HEVC (iOS 11+)
/// - ≥40 Mbps: 4K HEVC or H264
/// - ≥30 Mbps: 1080p HEVC or H264
/// - ≥20 Mbps: Highest quality HEVC or H264
/// - ≥10 Mbps: Highest quality
/// - ≥7 Mbps: 1080p
/// - ≥5 Mbps: 720p
/// - ≥3 Mbps: 540p
/// - ≥2 Mbps: 480p
/// - ≥1 Mbps: Medium quality
/// - <1 Mbps: Low quality
public func applyBitrate(requestedBitrate: Int?, presetHint: String? = nil) -> String {
  if let bitrate = requestedBitrate {
    PluginLog.print(
      "[\(Tags.render)] 📊 Requested bitrate: \(bitrate) bps (\(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps)"
    )
    PluginLog.print(
      "[\(Tags.render)] ⚠️ AVAssetExportSession does not support custom bitrate directly - using closest preset"
    )

    if bitrate >= 50_000_000 {
      #if os(macOS)
        if #available(macOS 12.1, *) {
          return AVAssetExportPresetHEVC7680x4320  // 8K HEVC on Mac
        } else if #available(macOS 10.13, *) {
          return AVAssetExportPresetHEVC3840x2160  // 4K HEVC Fallback
        } else {
          return AVAssetExportPreset3840x2160  // 4K H264 Fallback
        }
      #elseif os(iOS)
        if #available(iOS 11.0, *) {
          return AVAssetExportPresetHEVC3840x2160  // Use 4K HEVC as max on iOS
        } else {
          return AVAssetExportPreset3840x2160
        }
      #endif
    } else if bitrate >= 40_000_000 {
      #if os(macOS)
        if #available(macOS 10.13, *) {
          return AVAssetExportPresetHEVC3840x2160
        } else {
          return AVAssetExportPreset3840x2160
        }
      #elseif os(iOS)
        if #available(iOS 11.0, *) {
          return AVAssetExportPresetHEVC3840x2160
        } else {
          return AVAssetExportPreset3840x2160
        }
      #endif
    } else if bitrate >= 30_000_000 {
      #if os(macOS)
        if #available(macOS 10.13, *) {
          return AVAssetExportPresetHEVC1920x1080
        } else {
          return AVAssetExportPreset1920x1080
        }
      #elseif os(iOS)
        if #available(iOS 11.0, *) {
          return AVAssetExportPresetHEVC1920x1080
        } else {
          return AVAssetExportPreset1920x1080
        }
      #endif
    } else if bitrate >= 20_000_000 {
      #if os(macOS)
        if #available(macOS 10.13, *) {
          return AVAssetExportPresetHEVCHighestQuality
        } else {
          return AVAssetExportPresetHighestQuality
        }
      #elseif os(iOS)
        if #available(iOS 11.0, *) {
          return AVAssetExportPresetHEVCHighestQuality
        } else {
          return AVAssetExportPresetHighestQuality
        }
      #endif
    } else if bitrate >= 10_000_000 {
      return AVAssetExportPresetHighestQuality
    } else if bitrate >= 7_000_000 {
      return AVAssetExportPreset1920x1080
    } else if bitrate >= 5_000_000 {
      return AVAssetExportPreset1280x720
    } else if bitrate >= 3_000_000 {
      return AVAssetExportPreset960x540
    } else if bitrate >= 2_000_000 {
      return AVAssetExportPreset640x480
    } else if bitrate >= 1_000_000 {
      return AVAssetExportPresetMediumQuality
    } else {
      return AVAssetExportPresetLowQuality
    }
  }

  return presetHint ?? AVAssetExportPresetHighestQuality
}
