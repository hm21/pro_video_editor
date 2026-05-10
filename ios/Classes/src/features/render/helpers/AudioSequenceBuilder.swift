import AVFoundation
import Foundation

/// Builder for inserting a custom audio track into an `AVMutableComposition`.
///
/// The track is first **pre-rendered to a single, gap-less PCM WAV file**
/// via [AudioPreRenderer]. The composition then inserts this WAV with a
/// single `insertTimeRange` call, which avoids audible clicks at every
/// loop restart caused by AAC/MP3 codec priming when the source is
/// inserted multiple times directly into the composition.
internal class AudioSequenceBuilder {

    /// Result of a successful build operation.
    struct BuildResult {
        let track: AVMutableCompositionTrack
        /// Temporary pre-rendered audio file. The owner of the
        /// composition (RenderVideo) MUST delete this file once the
        /// export has finished (success or failure).
        let temporaryURL: URL
    }

    private let audioPath: String
    private let targetDuration: CMTime
    private var loopAudio: Bool = true
    private var audioStartTime: CMTime = .zero
    private var audioEndTime: CMTime?
    /// Where in the composition timeline to insert this audio track.
    private var compositionInsertTime: CMTime = .zero
    /// How long this audio track should play in the composition.
    /// If nil, uses targetDuration minus compositionInsertTime.
    private var compositionPlayDuration: CMTime?

    /// Initializes builder with audio path and target (full video) duration.
    init(audioPath: String, targetDuration: CMTime) {
        self.audioPath = audioPath
        self.targetDuration = targetDuration
    }

    @discardableResult
    func setLoop(_ loop: Bool) -> AudioSequenceBuilder {
        self.loopAudio = loop
        return self
    }

    @discardableResult
    func setAudioStartTime(_ startTimeUs: Int64?) -> AudioSequenceBuilder {
        if let startTimeUs = startTimeUs, startTimeUs > 0 {
            self.audioStartTime = CMTime(value: startTimeUs, timescale: 1_000_000)
        }
        return self
    }

    @discardableResult
    func setAudioEndTime(_ endTimeUs: Int64?) -> AudioSequenceBuilder {
        if let endTimeUs = endTimeUs, endTimeUs > 0 {
            self.audioEndTime = CMTime(value: endTimeUs, timescale: 1_000_000)
        }
        return self
    }

    @discardableResult
    func setCompositionStartTime(_ startUs: Int64?) -> AudioSequenceBuilder {
        if let startUs = startUs, startUs > 0 {
            self.compositionInsertTime = CMTime(value: startUs, timescale: 1_000_000)
        }
        return self
    }

    @discardableResult
    func setCompositionEndTime(_ endUs: Int64?) -> AudioSequenceBuilder {
        if let endUs = endUs, endUs > 0 {
            let endTime = CMTime(value: endUs, timescale: 1_000_000)
            self.compositionPlayDuration = CMTimeSubtract(endTime, compositionInsertTime)
        }
        return self
    }

    /// Pre-renders the audio and inserts it into `composition` with a
    /// single `insertTimeRange` call.
    func build(in composition: AVMutableComposition) async throws -> BuildResult? {
        // Compute play duration in the composition.
        let remainingCompositionTime = CMTimeSubtract(targetDuration, compositionInsertTime)
        let playDuration = compositionPlayDuration ?? remainingCompositionTime
        let effectivePlayDuration = CMTimeMinimum(playDuration, remainingCompositionTime)

        if CMTimeCompare(effectivePlayDuration, .zero) <= 0 {
            PluginLog.print("⚠️ No time remaining in composition for audio track")
            return nil
        }

        // Pre-render the audio: handles trim, loop and silence-padding
        // entirely on PCM samples.
        guard let prerender = await AudioPreRenderer.render(
            audioPath: audioPath,
            audioStartTime: audioStartTime,
            audioEndTime: audioEndTime,
            loop: loopAudio,
            targetBodyDuration: effectivePlayDuration
        ) else {
            return nil
        }

        // Load the pre-rendered audio and insert it once into the composition.
        let prerenderAsset = AVURLAsset(url: prerender.outputURL)

        let prerenderTracks: [AVAssetTrack]
        if #available(iOS 15.0, *) {
            prerenderTracks = (try? await prerenderAsset.loadTracks(withMediaType: .audio)) ?? []
        } else {
            prerenderTracks = prerenderAsset.tracks(withMediaType: .audio)
        }
        guard let sourceTrack = prerenderTracks.first else {
            PluginLog.print("⚠️ Pre-rendered audio has no audio track")
            try? FileManager.default.removeItem(at: prerender.outputURL)
            return nil
        }

        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            PluginLog.print("⚠️ Failed to add custom audio track")
            try? FileManager.default.removeItem(at: prerender.outputURL)
            return nil
        }

        // Insert the entire pre-rendered file at the composition offset.
        // The pre-render duration is already aligned to the requested
        // play duration (loop+trim handled at PCM level).
        let insertDuration = CMTimeMinimum(prerender.duration, effectivePlayDuration)
        let timeRange = CMTimeRange(start: .zero, duration: insertDuration)

        do {
            try compositionAudioTrack.insertTimeRange(
                timeRange, of: sourceTrack, at: compositionInsertTime
            )
        } catch {
            PluginLog.print("⚠️ Failed to insert pre-rendered audio: \(error)")
            try? FileManager.default.removeItem(at: prerender.outputURL)
            throw error
        }

        if CMTimeCompare(compositionInsertTime, .zero) > 0 {
            PluginLog.print(
                "🎵 Audio placed at composition time: \(compositionInsertTime.seconds)s"
            )
        }
        PluginLog.print(
            "🎼 Pre-rendered audio inserted: \(insertDuration.seconds)s (loop=\(loopAudio))"
        )

        return BuildResult(
            track: compositionAudioTrack,
            temporaryURL: prerender.outputURL
        )
    }
}
