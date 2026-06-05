import Foundation

/// Configuration model for audio extraction operations.
///
/// This struct encapsulates all parameters required for extracting audio
/// from a video file, providing type-safe access to input parameters.
struct AudioExtractConfig {
    /// The unique task identifier for progress tracking and cancellation
    let id: String
    
    /// The absolute file path to the source video file
    let inputPath: String
    
    /// The file extension of the source video (e.g., "mp4", "mov")
    let fileExtension: String
    
    /// The desired output audio format (e.g., "mp3", "aac", "m4a")
    let format: String
    
    /// Optional start time in microseconds for trimming
    let startUs: Int64?
    
    /// Optional end time in microseconds for trimming
    let endUs: Int64?
    
    /// Optional output file path (nil = return bytes)
    let outputPath: String?
    
    /// Creates an AudioExtractConfig from Flutter method call arguments.
    ///
    /// - Parameter arguments: Dictionary containing the method call arguments
    /// - Returns: A configured AudioExtractConfig instance, or nil if required parameters are missing
    static func fromArguments(_ arguments: [String: Any]?) -> AudioExtractConfig? {
        guard let args = arguments,
              let id = args["id"] as? String,
              let inputPath = args["inputPath"] as? String,
              let extensionStr = args["extension"] as? String,
              let format = args["format"] as? String else {
            return nil
        }
        
        let startUs = args["startTime"] as? Int64
        let endUs = args["endTime"] as? Int64
        let outputPath = args["outputPath"] as? String
        
        return AudioExtractConfig(
            id: id,
            inputPath: inputPath,
            fileExtension: extensionStr,
            format: format,
            startUs: startUs,
            endUs: endUs,
            outputPath: outputPath
        )
    }
    
    /// Returns the file extension for the output audio file based on the format.
    ///
    /// - Returns: The file extension string (e.g., "mp3", "aac", "m4a", "wav")
    func getOutputExtension() -> String {
        switch format.lowercased() {
        case "mp3": return "mp3"
        case "aac": return "m4a"
        case "m4a": return "m4a"
        case "caf": return "caf"
        case "wav": return "wav"
        default: return "m4a"
        }
    }
    
    /// Returns the AVFileType for the output audio format.
    ///
    /// - Returns: The AVFileType constant for the specified format
    func getAVFileType() -> String {
        switch format.lowercased() {
        case "mp3": return "com.apple.m4a-audio" // MP3 in M4A container
        case "aac": return "com.apple.m4a-audio" // AAC in M4A container
        case "m4a": return "com.apple.m4a-audio" // M4A container
        case "wav": return "com.microsoft.waveform-audio" // WAV format
        default: return "com.apple.m4a-audio"
        }
    }
}
