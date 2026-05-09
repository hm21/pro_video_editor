import Foundation

/// Represents a video clip with optional trimming, volume and playback speed control
internal struct VideoClip {
    let inputPath: String
    let startUs: Int64?
    let endUs: Int64?
    let volume: Float?
    let playbackSpeed: Float?

    init(
        inputPath: String,
        startUs: Int64? = nil,
        endUs: Int64? = nil,
        volume: Float? = nil,
        playbackSpeed: Float? = nil
    ) {
        self.inputPath = inputPath
        self.startUs = startUs
        self.endUs = endUs
        self.volume = volume
        self.playbackSpeed = playbackSpeed
    }
}
