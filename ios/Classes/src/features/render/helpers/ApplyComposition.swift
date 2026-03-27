import AVFoundation
import Foundation

/// Creates a multi-clip video composition with audio mixing and custom effects.
///
/// This is a simplified wrapper function that delegates the actual work
/// to CompositionBuilder. The builder pattern provides better separation
/// of concerns and cleaner code organization.
///
/// - Parameters:
///   - videoClips: Array of video clips to concatenate. Each clip can have optional trimming.
///   - videoEffects: Configuration for visual effects (rotation, scale, color, blur, etc.).
///   - enableAudio: If true, includes original audio from video clips.
///   - customAudioPath: Optional path to custom audio file to mix over the video.
///   - customAudioStartTimeUs: Start time offset in microseconds for the custom audio.
///   - originalAudioVolume: Volume for original video audio (0.0 to 1.0). Default 1.0.
///   - customAudioVolume: Volume for custom audio track (0.0 to 1.0). Default 1.0.
///
/// - Returns: A tuple containing:
///   - AVMutableComposition: The concatenated video/audio composition
///   - AVMutableVideoComposition: Video composition with effects and instructions
///   - CGSize: Final render size (max dimensions from all clips)
///   - AVAudioMix?: Audio mix with volume controls (nil if no audio mixing needed)
///   - CMPersistentTrackID: The track ID of the video composition track (for fallback on older iOS)
///
/// - Throws: NSError if video clips are empty, files don't exist, or tracks can't be loaded.
func applyComposition(
    videoClips: [VideoClip],
    videoEffects: VideoCompositorConfig,
    enableAudio: Bool,
    customAudioPath: String?,
    customAudioStartTimeUs: Int64?,
    originalAudioVolume: Float?,
    customAudioVolume: Float?,
    loopCustomAudio: Bool
) async throws -> (AVMutableComposition, AVMutableVideoComposition, CGSize, AVAudioMix?, CMPersistentTrackID) {
    return try await CompositionBuilder(videoClips: videoClips, videoEffects: videoEffects)
        .setEnableAudio(enableAudio)
        .setCustomAudioPath(customAudioPath)
        .setCustomAudioStartTime(customAudioStartTimeUs)
        .setOriginalAudioVolume(originalAudioVolume)
        .setCustomAudioVolume(customAudioVolume)
        .setLoopCustomAudio(loopCustomAudio)
        .build()
}
