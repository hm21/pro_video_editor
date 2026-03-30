import AVFoundation
import Foundation

/// Builder class for creating custom audio sequences.
///
/// Handles custom audio track with volume control, looping/trimming
/// to match video duration.
internal class AudioSequenceBuilder {

    private let audioPath: String
    private let targetDuration: CMTime
    private var volume: Float = 1.0
    private var loopAudio: Bool = true
    private var startTime: CMTime = .zero

    /// Initializes builder with audio path and target duration.
    ///
    /// - Parameters:
    ///   - audioPath: Absolute path to audio file
    ///   - targetDuration: Target duration to match (video duration)
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

    /// Sets the start time offset for the custom audio.
    ///
    /// - Parameter startTimeUs: Start time in microseconds from the beginning of the audio file
    /// - Returns: Self for chaining
    func setStartTime(_ startTimeUs: Int64?) -> AudioSequenceBuilder {
        if let startTimeUs = startTimeUs, startTimeUs > 0 {
            self.startTime = CMTime(value: startTimeUs, timescale: 1_000_000)
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
            print("⚠️ Custom audio file does not exist: \(audioPath)")
            return nil
        }

        let audioAsset = AVURLAsset(url: audioURL)

        guard let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: audioAsset),
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            print("⚠️ Failed to add custom audio track")
            return nil
        }

        // Get audio duration
        let audioDuration: CMTime
        if #available(macOS 13.0, *) {
            audioDuration = try await audioAsset.load(.duration)
        } else {
            audioDuration = audioAsset.duration
        }

        // Calculate effective audio duration after start offset
        let effectiveAudioDuration = CMTimeSubtract(audioDuration, startTime)
        if CMTimeCompare(effectiveAudioDuration, .zero) <= 0 {
            print(
                "⚠️ Start time (\(startTime.seconds)s) exceeds audio duration (\(audioDuration.seconds)s)"
            )
            return nil
        }

        if CMTimeCompare(startTime, .zero) > 0 {
            print("🎵 Custom audio start offset: \(startTime.seconds)s")
        }

        // Trim or loop custom audio to match video duration
        if CMTimeCompare(effectiveAudioDuration, targetDuration) > 0 {
            // Trim audio to match video duration (starting from startTime)
            let timeRange = CMTimeRange(start: startTime, duration: targetDuration)
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            print("✂️ Custom audio trimmed to \(targetDuration.seconds)s")
        } else if loopAudio {
            // Loop audio to match video duration
            var currentTime = CMTime.zero
            var loopCount = 0
            var isFirstLoop = true

            while CMTimeCompare(currentTime, targetDuration) < 0 {
                loopCount += 1
                let remainingDuration = CMTimeSubtract(targetDuration, currentTime)

                // First loop uses startTime offset, subsequent loops start from beginning
                let loopStartTime = isFirstLoop ? startTime : .zero
                let loopAudioDuration = isFirstLoop ? effectiveAudioDuration : audioDuration

                let insertDuration = CMTimeMinimum(loopAudioDuration, remainingDuration)
                let timeRange = CMTimeRange(start: loopStartTime, duration: insertDuration)

                try compositionAudioTrack.insertTimeRange(
                    timeRange, of: audioTrack, at: currentTime)
                currentTime = CMTimeAdd(currentTime, insertDuration)
                isFirstLoop = false
            }

            print(
                "🔄 Custom audio looped \(loopCount) times to match \(targetDuration.seconds)s duration"
            )
        } else {
            // Play audio once without looping (starting from startTime)
            let timeRange = CMTimeRange(start: startTime, duration: effectiveAudioDuration)
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            print(
                "▶️ Custom audio plays once (\(effectiveAudioDuration.seconds)s, no loop)"
                    + (CMTimeCompare(startTime, .zero) > 0
                        ? " starting at \(startTime.seconds)s" : ""))
        }

        if volume != 1.0 {
            print("🔊 Custom audio volume: \(volume)")
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
            print("⚠️ Could not detect custom audio sample rate")
            return true  // Assume compatible if we can't detect
        }

        for clip in videoClips {
            if let videoSampleRate = await getVideoAudioSampleRate(clip.inputPath),
                videoSampleRate > 0 && videoSampleRate != customSampleRate
            {
                print(
                    "❌ Sample rate mismatch: custom audio (\(customSampleRate) Hz) vs video (\(videoSampleRate) Hz)"
                )
                return false
            }
        }

        print("✅ Sample rates are compatible")
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
            if #available(macOS 13.0, *) {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                tracks = asset.tracks(withMediaType: .audio)
            }

            guard let audioTrack = tracks.first else {
                return nil
            }

            let formatDescriptions: [Any]
            if #available(macOS 13.0, *) {
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
