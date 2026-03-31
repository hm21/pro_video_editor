import Foundation

/// Configuration model for thumbnail generation operations.
///
/// This struct encapsulates all parameters required for extracting thumbnail images
/// from video files, supporting both timestamp-based and keyframe-based extraction modes.
internal struct ThumbnailConfig {
    /// Unique identifier for tracking progress of this operation
    let id: String

    /// The absolute file path to the video file
    let inputPath: String

    /// The file extension (e.g., "mp4", "mov")
    let fileExtension: String

    /// Scaling mode: "contain" (fit within bounds) or "cover" (fill bounds)
    let boxFit: String

    /// Output image format: "jpeg", "png"
    let outputFormat: String

    /// JPEG compression quality (0-100). Only affects JPEG format.
    let jpegQuality: Int

    /// Target thumbnail width in pixels
    let outputWidth: Int

    /// Target thumbnail height in pixels
    let outputHeight: Int

    /// List of timestamps in microseconds where frames should be extracted
    /// Empty if using keyframe-based extraction
    let timestampsUs: [Int64]

    /// Maximum number of keyframes to extract (for keyframe-based extraction)
    /// Nil if using timestamp-based extraction
    let maxOutputFrames: Int?

    /// Creates a ThumbnailConfig from Flutter method call arguments.
    ///
    /// - Parameter arguments: Dictionary containing the method call arguments
    /// - Returns: A configured ThumbnailConfig instance, or nil if required parameters are missing
    static func fromArguments(_ arguments: [String: Any]?) -> ThumbnailConfig? {
        guard let args = arguments,
            let id = args["id"] as? String,
            let inputPath = args["inputPath"] as? String,
            let extensionStr = args["extension"] as? String,
            let boxFit = args["boxFit"] as? String,
            let outputFormat = args["outputFormat"] as? String,
            let outputWidth = args["outputWidth"] as? Int,
            let outputHeight = args["outputHeight"] as? Int
        else {
            return nil
        }

        let jpegQuality = args["jpegQuality"] as? Int ?? 90
        guard jpegQuality >= 0 && jpegQuality <= 100 else {
            return nil
        }

        let rawTimestamps = args["timestamps"] as? [NSNumber] ?? []
        let timestampsUs = rawTimestamps.map { $0.int64Value }
        let maxOutputFrames = args["maxOutputFrames"] as? Int

        // At least one extraction mode must be specified
        guard !timestampsUs.isEmpty || maxOutputFrames != nil else {
            return nil
        }

        return ThumbnailConfig(
            id: id,
            inputPath: inputPath,
            fileExtension: extensionStr,
            boxFit: boxFit,
            outputFormat: outputFormat,
            jpegQuality: jpegQuality,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            timestampsUs: timestampsUs,
            maxOutputFrames: maxOutputFrames
        )
    }
}
