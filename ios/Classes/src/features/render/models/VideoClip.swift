import Foundation

/// Represents a video clip with optional trimming, volume control, and positioning
internal struct VideoClip {
    let inputPath: String
    let startUs: Int64?
    let endUs: Int64?
    let volume: Float?
    let opacity: Double?

    // New fields for composition support
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let segmentTimeUs: Int64?
    let zIndex: Int?

    init(
        inputPath: String,
        startUs: Int64? = nil,
        endUs: Int64? = nil,
        volume: Float? = nil,
        opacity: Double? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        segmentTimeUs: Int64? = nil,
        zIndex: Int? = nil
    ) {
        self.inputPath = inputPath
        self.startUs = startUs
        self.endUs = endUs
        self.volume = volume
        self.opacity = opacity
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.segmentTimeUs = segmentTimeUs
        self.zIndex = zIndex
    }
}
