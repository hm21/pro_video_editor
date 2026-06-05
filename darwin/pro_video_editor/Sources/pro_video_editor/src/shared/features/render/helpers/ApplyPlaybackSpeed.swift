import AVFoundation

/// Adjusts video playback speed by time-scaling the composition.
///
/// Changes the playback speed by scaling the time range of all tracks in the composition.
/// This affects both video and audio tracks equally. Also rescales the provided video
/// composition instructions so their time ranges match the scaled track durations.
///
/// - Parameters:
///   - composition: Composition to modify.
///   - instructions: Video composition instructions to rescale.
///   - speed: Playback speed multiplier.
///            - 0.5 = half speed (slow motion)
///            - 1.0 = normal speed (no change)
///            - 2.0 = double speed (fast forward)
///            - nil or 1.0 = no change
///
/// - Returns: The rescaled instructions (unchanged if speed is nil or 1.0).
/// - Note: Speed must be positive. Values ≤0 or exactly 1.0 are ignored.
public func applyPlaybackSpeed(
    composition: AVMutableComposition,
    instructions: [AVVideoCompositionInstructionProtocol],
    speed: Float?
) -> [AVVideoCompositionInstructionProtocol] {
    guard let speed = speed, speed > 0, speed != 1 else { return instructions }

    let speedType = speed < 1 ? "slow motion" : "fast forward"
    PluginLog.print("[\(Tags.render)] ⚡ Applying playback speed: \(String(format: "%.2f", speed))x (\(speedType))")

    let multiplier = 1.0 / Double(speed)

    let tracks = composition.tracks
    for track in tracks {
        let range = CMTimeRange(start: .zero, duration: track.timeRange.duration)
        let scaledDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: multiplier)
        track.scaleTimeRange(range, toDuration: scaledDuration)
    }

    // Scale video composition instructions to match the new track durations
    return instructions.map { instruction in
        guard let custom = instruction as? CustomVideoCompositionInstruction else {
            return instruction
        }
        let scaledStart = CMTimeMultiplyByFloat64(custom.timeRange.start, multiplier: multiplier)
        let scaledDuration = CMTimeMultiplyByFloat64(custom.timeRange.duration, multiplier: multiplier)
        let trackID = (custom.requiredSourceTrackIDs?.first as? NSNumber)?.int32Value ?? kCMPersistentTrackID_Invalid
        return CustomVideoCompositionInstruction(
            timeRange: CMTimeRange(start: scaledStart, duration: scaledDuration),
            sourceTrackID: trackID,
            layerInstructions: custom.layerInstructions,
            backgroundColor: custom.backgroundColor
        )
    }
}
