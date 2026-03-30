import Foundation

/// Represents a video clip with optional trimming and volume control
internal struct VideoClip {
    let inputPath: String
    let startUs: Int64?
    let endUs: Int64?
    let volume: Float?

    init(inputPath: String, startUs: Int64? = nil, endUs: Int64? = nil, volume: Float? = nil) {
        self.inputPath = inputPath
        self.startUs = startUs
        self.endUs = endUs
        self.volume = volume
    }
}
