import Foundation

/// Configuration model for waveform generation operations.
///
/// This struct encapsulates all parameters required for generating
/// waveform data from a video's audio track.
struct WaveformConfig {
    /// The unique task identifier for progress tracking and cancellation
    let id: String

    /// The absolute file path to the source video file
    let inputPath: String

    /// The file extension of the source video (e.g., "mp4", "mov")
    let fileExtension: String

    /// Number of waveform samples to generate per second of audio
    let samplesPerSecond: Int

    /// Number of samples per chunk for streaming mode
    let chunkSize: Int

    /// Optional start time in microseconds for partial extraction
    let startUs: Int64?

    /// Optional end time in microseconds for partial extraction
    let endUs: Int64?

    /// Creates a WaveformConfig from Flutter method call arguments.
    ///
    /// - Parameter arguments: Dictionary containing the method call arguments
    /// - Returns: A configured WaveformConfig instance, or nil if required parameters are missing
    static func fromArguments(_ arguments: [String: Any]?) -> WaveformConfig? {
        guard let args = arguments,
            let id = args["id"] as? String,
            let inputPath = args["inputPath"] as? String,
            let extensionStr = args["extension"] as? String
        else {
            return nil
        }

        let samplesPerSecond = args["samplesPerSecond"] as? Int ?? 50
        let chunkSize = args["chunkSize"] as? Int ?? 50
        let startUs = args["startTime"] as? Int64
        let endUs = args["endTime"] as? Int64

        return WaveformConfig(
            id: id,
            inputPath: inputPath,
            fileExtension: extensionStr,
            samplesPerSecond: samplesPerSecond,
            chunkSize: chunkSize,
            startUs: startUs,
            endUs: endUs
        )
    }
}
