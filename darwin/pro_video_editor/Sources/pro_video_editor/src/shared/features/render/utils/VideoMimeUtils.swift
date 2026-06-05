import AVFoundation

/// Maps video format string to corresponding AVFileType.
///
/// Converts user-friendly format strings into AVFoundation's AVFileType enum values
/// used for video export operations. Unsupported formats default to MP4.
///
/// - Parameter format: Video format string (e.g., "mp4", "mov").
/// - Returns: AVFileType enum value for the specified format.
///
/// Supported formats:
/// - "mp4": MPEG-4 video container (.mp4)
/// - "mov": QuickTime movie container (.mov)
/// - Default: Falls back to MP4 for unknown formats
func mapFormatToMimeType(format: String) -> AVFileType {
    switch format {
    case "mp4":
        return .mp4
    case "mov":
        return .mov
    default:
        return .mp4
    }
}
