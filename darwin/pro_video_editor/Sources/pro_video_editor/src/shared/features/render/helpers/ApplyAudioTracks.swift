import AVFoundation
import Foundation

/// Mixes the custom audio tracks into the composition over the span the
/// export keeps.
///
/// A track's `startUs`/`endUs` are on the output timeline, so they count from
/// `window.start`, where the global trim begins, and the track stops at the
/// window's end. Call this after `applyPlaybackSpeed`: the composition is on
/// its final timeline by then, and the tracks keep their own tempo. Android
/// lays its tracks over the trimmed, sped-up output the same way.
///
/// - Parameters:
///   - composition: Composition to add the tracks to.
///   - audioTracks: Custom audio tracks to mix in.
///   - window: The part of the composition the export keeps.
///   - audioMix: The mix built for the clips' own audio, if any.
///
/// - Returns: The audio mix with one volume parameter per added track, and the
///   pre-rendered WAVs the caller must delete once the export has finished.
func applyAudioTracks(
  composition: AVMutableComposition,
  audioTracks: [AudioTrackConfig],
  window: CMTimeRange,
  audioMix: AVAudioMix?
) async throws -> (audioMix: AVAudioMix?, temporaryURLs: [URL]) {
  guard !audioTracks.isEmpty else { return (audioMix, []) }

  var params: [AVAudioMixInputParameters] = audioMix?.inputParameters ?? []
  var temporaryURLs: [URL] = []
  do {
    for trackConfig in audioTracks {
      PluginLog.print("🎵 Adding audio track: \(trackConfig.path)")
      let audioBuilder = AudioSequenceBuilder(audioPath: trackConfig.path, window: window)
        .setLoop(trackConfig.loop)
        .setAudioStartTime(trackConfig.audioStartUs)
        .setAudioEndTime(trackConfig.audioEndUs)
        .setCompositionStartTime(trackConfig.startUs == -1 ? nil : trackConfig.startUs)
        .setCompositionEndTime(trackConfig.endUs == -1 ? nil : trackConfig.endUs)
        .setFade(inUs: trackConfig.fadeInUs, outUs: trackConfig.fadeOutUs)

      guard let result = try await audioBuilder.build(in: composition) else { continue }
      temporaryURLs.append(result.temporaryURL)

      let trackParams = AVMutableAudioMixInputParameters(track: result.track)
      trackParams.setVolume(trackConfig.volume, at: .zero)
      // A track played above its own level is limited rather than clipped.
      trackParams.audioTapProcessor = VolumeLimiterTap.make(
        for: VolumeSchedule(constant: trackConfig.volume))
      params.append(trackParams)
      PluginLog.print(
        "🔊 Applied volume \(trackConfig.volume) to custom audio track: \(trackConfig.path)")
    }
  } catch {
    // The caller never learns about the WAVs written before the failure.
    for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
    throw error
  }

  guard !params.isEmpty else { return (audioMix, temporaryURLs) }
  let mix = AVMutableAudioMix()
  mix.inputParameters = params
  return (mix, temporaryURLs)
}
