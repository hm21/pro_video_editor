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
///   - audioTracks: Array of audio track configurations to mix over the video.
///
/// - Returns: A tuple containing:
///   - AVMutableComposition: The concatenated video/audio composition
///   - VideoCompositionData: Video composition data with instructions and render size
///   - CGSize: Final render size (max dimensions from all clips)
///   - AVAudioMix?: Audio mix with volume controls (nil if no audio mixing needed)
///   - CMPersistentTrackID: The track ID of the video composition track (for fallback on older iOS)
///   - [URL]: Temporary file URLs (e.g. pre-rendered audio WAVs) the caller MUST delete after export
///   - [FadeWindow]: Dip-to-color windows for fadeToBlack / fadeToWhite transitions
///
/// - Throws: NSError if video clips are empty, files don't exist, or tracks can't be loaded.
func applyComposition(
  videoClips: [VideoClip],
  videoEffects: VideoCompositorConfig,
  enableAudio: Bool,
  audioTracks: [AudioTrackConfig]
) async throws -> (
  AVMutableComposition, VideoCompositionData, CGSize, AVAudioMix?, CMPersistentTrackID, [URL],
  [FadeWindow]
) {
  return try await CompositionBuilder(videoClips: videoClips, videoEffects: videoEffects)
    .setEnableAudio(enableAudio)
    .setAudioTracks(audioTracks)
    .build()
}
