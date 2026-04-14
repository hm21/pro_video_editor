import AVFoundation
import Foundation

/// Builder class for creating custom audio sequences.
///
/// Handles custom audio track with volume control, looping/trimming
/// to match video duration or a specific time range in the composition.
internal class AudioSequenceBuilder {

    private let audioPath: String
    private let targetDuration: CMTime
    private var volume: Float = 1.0
    private var loopAudio: Bool = true
    private var audioStartTime: CMTime = .zero
    private var audioEndTime: CMTime?
    /// Where in the composition timeline to insert this audio track.
    private var compositionInsertTime: CMTime = .zero
    /// How long this audio track should play in the composition.
    /// If nil, uses targetDuration minus compositionInsertTime.
    private var compositionPlayDuration: CMTime?

    /// Initializes builder with audio path and target duration.
    ///
    /// - Parameters:
    ///   - audioPath: Absolute path to audio file
    ///   - targetDuration: Target duration to match (total video duration)
    init(audioPath: String, targetDuration: CMTime) {
        self.audioPath = audioPath
        self.targetDuration = targetDuration
    }

    /// Sets volume for custom audio.
    ///
    /// - Parameter volume: Volume multiplier (0.0 to 1.0+)
    /// - Returns: Self for chaining
    func setVolume(_ volume: Float) -> AudioSequenceBuilder {
        self.volume = volume
        return self
    }

    /// Sets whether the audio should loop to match video duration.
    ///
    /// - Parameter loop: If true, audio repeats; if false, plays once
    /// - Returns: Self for chaining
    func setLoop(_ loop: Bool) -> AudioSequenceBuilder {
        self.loopAudio = loop
        return self
    }

    /// Sets the start time offset within the audio file.
    ///
    /// - Parameter startTimeUs: Start time in microseconds from the beginning of the audio file
    /// - Returns: Self for chaining
    func setAudioStartTime(_ startTimeUs: Int64?) -> AudioSequenceBuilder {
        if let startTimeUs = startTimeUs, startTimeUs > 0 {
            self.audioStartTime = CMTime(value: startTimeUs, timescale: 1_000_000)
        }
        return self
    }

    /// Sets the end time offset within the audio file.
    ///
    /// - Parameter endTimeUs: End time in microseconds within the audio file
    /// - Returns: Self for chaining
    func setAudioEndTime(_ endTimeUs: Int64?) -> AudioSequenceBuilder {
        if let endTimeUs = endTimeUs, endTimeUs > 0 {
            self.audioEndTime = CMTime(value: endTimeUs, timescale: 1_000_000)
        }
        return self
    }

    /// Sets where in the composition timeline this audio should start playing.
    ///
    /// - Parameter startUs: Composition start time in microseconds (-1 or nil = from start)
    /// - Returns: Self for chaining
    func setCompositionStartTime(_ startUs: Int64?) -> AudioSequenceBuilder {
        if let startUs = startUs, startUs > 0 {
            self.compositionInsertTime = CMTime(value: startUs, timescale: 1_000_000)
        }
        return self
    }

    /// Sets the duration this audio should play in the composition.
    ///
    /// - Parameter endUs: Composition end time in microseconds (-1 or nil = until end)
    /// - Returns: Self for chaining
    func setCompositionEndTime(_ endUs: Int64?) -> AudioSequenceBuilder {
        if let endUs = endUs, endUs > 0 {
            let endTime = CMTime(value: endUs, timescale: 1_000_000)
            self.compositionPlayDuration = CMTimeSubtract(endTime, compositionInsertTime)
        }
        return self
    }

    /// Builds custom audio track and adds it to composition.
    ///
    /// Trims or loops the audio to match target duration and applies volume.
    ///
    /// - Parameter composition: Composition to add audio track to
    /// - Returns: The created composition track, or nil if failed
    func build(in composition: AVMutableComposition) async throws -> AVMutableCompositionTrack? {
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            PluginLog.print("⚠️ Custom audio file does not exist: \(audioPath)")
            return nil
        }

        let audioAsset = AVURLAsset(url: audioURL)

        guard let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: audioAsset),
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            PluginLog.print("⚠️ Failed to add custom audio track")
            return nil
        }

        // Get audio duration
        let audioDuration: CMTime
        if #available(iOS 15.0, *) {
            audioDuration = (try? await audioAsset.load(.duration)) ?? .zero
        } else {
            audioDuration = audioAsset.duration
        }

        // Calculate effective audio source range
        let effectiveAudioEnd = audioEndTime ?? audioDuration
        let effectiveAudioDuration = CMTimeSubtract(effectiveAudioEnd, audioStartTime)
        if CMTimeCompare(effectiveAudioDuration, .zero) <= 0 {
            PluginLog.print(
                "⚠️ Audio start/end time range is invalid (start: \(audioStartTime.seconds)s, end: \(effectiveAudioEnd.seconds)s)"
            )
            return nil
        }

        // Calculate how long this track should play in the composition
        let remainingCompositionTime = CMTimeSubtract(targetDuration, compositionInsertTime)
        let playDuration = compositionPlayDuration ?? remainingCompositionTime
        let effectivePlayDuration = CMTimeMinimum(playDuration, remainingCompositionTime)

        if CMTimeCompare(effectivePlayDuration, .zero) <= 0 {
            PluginLog.print("⚠️ No time remaining in composition for audio track")
            return nil
        }

        if CMTimeCompare(audioStartTime, .zero) > 0 {
            PluginLog.print("🎵 Custom audio start offset: \(audioStartTime.seconds)s")
        }
        if audioEndTime != nil {
            PluginLog.print("🎵 Custom audio end offset: \(effectiveAudioEnd.seconds)s")
        }
        if CMTimeCompare(compositionInsertTime, .zero) > 0 {
            PluginLog.print(
                "🎵 Audio placed at composition time: \(compositionInsertTime.seconds)s"
            )
        }

        // Trim or loop custom audio to match the effective play duration
        if CMTimeCompare(effectiveAudioDuration, effectivePlayDuration) > 0 {
            // Trim audio to match play duration (starting from audioStartTime)
            let timeRange = CMTimeRange(start: audioStartTime, duration: effectivePlayDuration)
            try compositionAudioTrack.insertTimeRange(
                timeRange, of: audioTrack, at: compositionInsertTime)
            PluginLog.print("✂️ Custom audio trimmed to \(effectivePlayDuration.seconds)s")
        } else if loopAudio {
            // Loop audio to match play duration
            var currentTime = compositionInsertTime
            let compositionEndTime = CMTimeAdd(compositionInsertTime, effectivePlayDuration)
            var loopCount = 0
            var isFirstLoop = true

            while CMTimeCompare(currentTime, compositionEndTime) < 0 {
                loopCount += 1
                let remainingDuration = CMTimeSubtract(compositionEndTime, currentTime)

                // First loop uses audioStartTime offset, subsequent loops start from beginning of source range
                let loopStartTime = isFirstLoop ? audioStartTime : audioStartTime
                let loopAudioDuration = effectiveAudioDuration

                let insertDuration = CMTimeMinimum(loopAudioDuration, remainingDuration)
                let timeRange = CMTimeRange(start: loopStartTime, duration: insertDuration)

                try compositionAudioTrack.insertTimeRange(
                    timeRange, of: audioTrack, at: currentTime)
                currentTime = CMTimeAdd(currentTime, insertDuration)
                isFirstLoop = false
            }

            PluginLog.print(
                "🔄 Custom audio looped \(loopCount) times to match \(effectivePlayDuration.seconds)s duration"
            )
        } else {
            // Play audio once without looping (starting from audioStartTime)
            let insertDuration = CMTimeMinimum(effectiveAudioDuration, effectivePlayDuration)
            let timeRange = CMTimeRange(start: audioStartTime, duration: insertDuration)
            try compositionAudioTrack.insertTimeRange(
                timeRange, of: audioTrack, at: compositionInsertTime)
            PluginLog.print(
                "▶️ Custom audio plays once (\(insertDuration.seconds)s, no loop)"
                    + (CMTimeCompare(audioStartTime, .zero) > 0
                        ? " starting at \(audioStartTime.seconds)s" : ""))
        }

        if volume != 1.0 {
            PluginLog.print("🔊 Custom audio volume: \(volume)")
        }

        return compositionAudioTrack
    }

    /// Checks if custom audio sample rate is compatible with video audio.
    ///
    /// - Parameter videoClips: Array of video clips to check against
    /// - Returns: true if compatible or no video audio exists
    func checkSampleRateCompatibility(videoClips: [VideoClip]) async -> Bool {
        let customSampleRate = await MediaInfoExtractor.getAudioSampleRate(audioPath)

        guard customSampleRate > 0 else {
            PluginLog.print("⚠️ Could not detect custom audio sample rate")
            return true  // Assume compatible if we can't detect
        }

        for clip in videoClips {
            if let videoSampleRate = await getVideoAudioSampleRate(clip.inputPath),
                videoSampleRate > 0 && videoSampleRate != customSampleRate
            {
                PluginLog.print(
                    "❌ Sample rate mismatch: custom audio (\(customSampleRate) Hz) vs video (\(videoSampleRate) Hz)"
                )
                return false
            }
        }

        PluginLog.print("✅ Sample rates are compatible")
        return true
    }

    /// Gets sample rate of audio track in video file.
    private func getVideoAudioSampleRate(_ videoPath: String) async -> Int? {
        let url = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let asset = AVURLAsset(url: url)

        do {
            let tracks: [AVAssetTrack]
            if #available(iOS 15.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }

            guard let audioTrack = tracks.first else {
                return nil
            }

            let formatDescriptions: [Any]
            if #available(iOS 15.0, *) {
                formatDescriptions = try await audioTrack.load(.formatDescriptions)
            } else {
                formatDescriptions = audioTrack.formatDescriptions
            }

            for description in formatDescriptions {
                let formatDesc = description as! CMFormatDescription
                if let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    return Int(basicDesc.pointee.mSampleRate)
                }
            }

            return nil
        } catch {
            return nil
        }
    }
}
