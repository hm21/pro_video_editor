import Foundation

/// Represents a video clip with optional trimming
struct VideoClip {
    let inputPath: String
    let startUs: Int64?
    let endUs: Int64?

    init(inputPath: String, startUs: Int64? = nil, endUs: Int64? = nil) {
        self.inputPath = inputPath
        self.startUs = startUs
        self.endUs = endUs
    }
}
