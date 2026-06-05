import Foundation

/// Configuration model for metadata extraction operations.
///
/// This struct encapsulates all parameters required for extracting metadata
/// from a video file, providing type-safe access to input parameters.
struct MetadataConfig {
    /// The absolute file path to the video file
    let inputPath: String
    
    /// The file extension (e.g., "mp4", "mov")
    let fileExtension: String
    
    /// Whether to check if the video is optimized for streaming (moov before mdat)
    let checkStreamingOptimization: Bool
    
    /// Creates a MetadataConfig from Flutter method call arguments.
    ///
    /// - Parameter arguments: Dictionary containing the method call arguments
    /// - Returns: A configured MetadataConfig instance, or nil if required parameters are missing
    static func fromArguments(_ arguments: [String: Any]?) -> MetadataConfig? {
        guard let args = arguments,
              let inputPath = args["inputPath"] as? String,
              let extensionStr = args["extension"] as? String else {
            return nil
        }
        
        return MetadataConfig(
            inputPath: inputPath,
            fileExtension: extensionStr,
            checkStreamingOptimization: args["checkStreamingOptimization"] as? Bool ?? false
        )
    }
}
