import AVFoundation
import Foundation

/// Builder class for creating video sequences in compositions.
///
/// Handles multiple video clips, audio tracks, volume control,
/// and composition assembly.
internal class VideoSequenceBuilder {

    private let videoClips: [VideoClip]
    private var enableAudio: Bool = true

    /// Initializes builder with video clips.
    ///
    /// - Parameter videoClips: Array of video clips to process
    init(videoClips: [VideoClip]) {
        self.videoClips = videoClips
    }

    /// Enables or disables audio in the output.
    ///
    /// - Parameter enabled: If true, includes original audio from video clips
    /// - Returns: Self for chaining
    func setEnableAudio(_ enabled: Bool) -> VideoSequenceBuilder {
        self.enableAudio = enabled
        return self
    }

    /// Calculates total duration of all video clips combined.
    ///
    /// - Returns: Total duration as CMTime
    func calculateTotalDuration() async -> CMTime {
        var totalDuration = CMTime.zero

        for clip in videoClips {
            let clipDuration = await calculateClipDuration(clip)
            totalDuration = CMTimeAdd(totalDuration, clipDuration)
        }

        let durationMs = Int(totalDuration.seconds * 1000)
        PluginLog.print("🔍 Total video duration: \(durationMs) ms")
        return totalDuration
    }

    /// Calculates duration of a single clip considering trimming.
    private func calculateClipDuration(_ clip: VideoClip) async -> CMTime {
        let url = URL(fileURLWithPath: clip.inputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .zero
        }

        let asset = AVURLAsset(url: url)
        let assetDuration: CMTime

        if #available(macOS 13.0, *) {
            assetDuration = (try? await asset.load(.duration)) ?? .zero
        } else {
            assetDuration = asset.duration
        }

        let startTime = clip.startUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? .zero
        let endTime = clip.endUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? assetDuration

        return CMTimeSubtract(endTime, startTime)
    }

    /// Builds the video composition with all clips.
    ///
    /// - Parameter composition: Composition to build into
    /// - Returns: Tuple containing video track, audio tracks, render size, frame rate, and clip instructions
    func build(in composition: AVMutableComposition) async throws -> VideoSequenceResult {
        guard !videoClips.isEmpty else {
            throw NSError(
                domain: "VideoSequenceBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
            )
        }

        PluginLog.print("🎬 Building video sequence with \(videoClips.count) clips")
        PluginLog.print("🔊 Audio enabled: \(enableAudio)")

        var totalDuration = CMTime.zero
        var maxRenderSize = CGSize.zero
        var maxFrameRate: Float = 30.0
        var originalAudioTracks: [AVMutableCompositionTrack] = []
        var clipInstructions: [ClipInstruction] = []
        var reversedAudioTempURLs: [URL] = []

        // Create single video track for all clips
        guard
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw NSError(
                domain: "VideoSequenceBuilder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"]
            )
        }

        // Create single shared audio track for all clips (if enabled)
        var sharedAudioTrack: AVMutableCompositionTrack?
        if enableAudio {
            sharedAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if sharedAudioTrack != nil {
                PluginLog.print("🔊 Created SHARED audio track for all clips (will prevent empty segments)")
            }
        }

        // Process each video clip
        for (index, clip) in videoClips.enumerated() {
            PluginLog.print("📹 Processing clip \(index): \(clip.inputPath)")

            let url = URL(fileURLWithPath: clip.inputPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                PluginLog.print("❌ ERROR: Video file does not exist: \(clip.inputPath)")
                throw NSError(
                    domain: "VideoSequenceBuilder",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Video file does not exist: \(clip.inputPath)"
                    ]
                )
            }

            let asset = AVURLAsset(url: url)

            // Load video track
            let videoTrack = try await MediaInfoExtractor.loadVideoTrack(from: asset)

            // Get video properties
            let naturalSize = videoTrack.naturalSize
            let nominalFrameRate = videoTrack.nominalFrameRate
            let preferredTransform = videoTrack.preferredTransform

            // Calculate corrected size (accounting for rotation)
            let displaySize = naturalSize.applying(preferredTransform)
            let correctedSize = CGSize(
                width: abs(displaySize.width),
                height: abs(displaySize.height)
            )

            // Log video properties
            let angle = atan2(preferredTransform.b, preferredTransform.a)
            let degrees = angle * 180 / .pi
            PluginLog.print("📹 Clip \(index) properties:")
            PluginLog.print("   - Natural size: \(naturalSize.width) x \(naturalSize.height)")
            PluginLog.print(
                "   - Rotation: \(degrees)° (transform: [\(preferredTransform.a), \(preferredTransform.b), \(preferredTransform.c), \(preferredTransform.d), \(preferredTransform.tx), \(preferredTransform.ty)])"
            )
            PluginLog.print("   - Display size: \(correctedSize.width) x \(correctedSize.height)")
            PluginLog.print("   - Frame rate: \(nominalFrameRate) fps")

            // Update max render size
            if correctedSize.width > maxRenderSize.width
                || correctedSize.height > maxRenderSize.height
            {
                let oldSize = maxRenderSize
                maxRenderSize = correctedSize
                PluginLog.print(
                    "   - ⬆️ Max render size updated: \(oldSize.width)x\(oldSize.height) → \(maxRenderSize.width)x\(maxRenderSize.height)"
                )
            }

            // Update max frame rate
            if nominalFrameRate > maxFrameRate {
                maxFrameRate = nominalFrameRate
            }

            // Calculate time range for this clip
            let rawClipTimeRange = await calculateTimeRange(for: clip, from: asset)

            // Clamp clip range to the video track's actual available range.
            // Some MP4 files have a container duration slightly longer than the video
            // track's decoded frames. Without clamping, insertTimeRange silently truncates
            // the insert but the ClipInstruction keeps the longer duration, creating a gap
            // where AVFoundation calls the compositor with no source frame available
            // (sourceTrackIDs empty), causing a RENDER_ERROR crash.
            let videoTrackTimeRange = videoTrack.timeRange
            let clampedRange = CMTimeRangeGetIntersection(rawClipTimeRange, otherRange: videoTrackTimeRange)
            let clipTimeRange = clampedRange.duration > .zero ? clampedRange : rawClipTimeRange
            let clipDuration = clipTimeRange.duration
            let insertStart = totalDuration
            let sourceRanges: [CMTimeRange]
            if clip.reverseVideo {
                sourceRanges = reverseTimeRanges(
                    for: clipTimeRange,
                    frameDuration: frameDuration(for: nominalFrameRate)
                )
            } else {
                sourceRanges = [clipTimeRange]
            }

            // Insert video clip into the composition track.
            var segmentInsertTime = insertStart
            for sourceRange in sourceRanges {
                try compositionVideoTrack.insertTimeRange(
                    sourceRange,
                    of: videoTrack,
                    at: segmentInsertTime
                )
                segmentInsertTime = CMTimeAdd(segmentInsertTime, sourceRange.duration)
            }
            if clip.reverseVideo {
                PluginLog.print("⏪ Clip \(index) reversed with \(sourceRanges.count) frame slice(s)")
            }

            // Apply per-clip playback speed by scaling the inserted segment.
            // The global config.playbackSpeed is still applied via
            // composition instructions in `applyPlaybackSpeed` and is multiplicative.
            let effectiveDuration: CMTime
            if let speed = clip.playbackSpeed, speed > 0, speed != 1.0 {
                let scaled = CMTimeMultiplyByFloat64(clipDuration, multiplier: 1.0 / Float64(speed))
                let insertedRange = CMTimeRange(start: insertStart, duration: clipDuration)
                compositionVideoTrack.scaleTimeRange(insertedRange, toDuration: scaled)
                effectiveDuration = scaled
                PluginLog.print(
                    "⏩ Clip \(index) playback speed: \(speed)× (duration \(String(format: "%.2f", clipDuration.seconds))s → \(String(format: "%.2f", scaled.seconds))s)"
                )
            } else {
                effectiveDuration = clipDuration
            }

            // Store instruction for this clip segment
            clipInstructions.append(
                ClipInstruction(
                    timeRange: CMTimeRange(start: insertStart, duration: effectiveDuration),
                    transform: preferredTransform,
                    naturalSize: naturalSize,
                    renderSize: correctedSize
                ))

            // Add audio to shared track if enabled
            if enableAudio,
                let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: asset),
                let sharedAudioTrack = sharedAudioTrack
            {
                PluginLog.print("🔊 Processing audio for clip \(index)...")

                do {
                    if clip.reverseVideo {
                        // True PCM-level reversal: decode → reverse samples → WAV.
                        // This avoids the ~30 audible artefacts/second that the
                        // frame-slice approach produces.
                        if let reversed = await AudioReverser.reverse(
                            inputPath: clip.inputPath,
                            startTime: clipTimeRange.start,
                            endTime: CMTimeRangeGetEnd(clipTimeRange)
                        ) {
                            reversedAudioTempURLs.append(reversed.outputURL)
                            let wavAsset = AVURLAsset(url: reversed.outputURL)
                            let wavTracks: [AVAssetTrack]
                            if #available(macOS 13.0, *) {
                                wavTracks = (try? await wavAsset.loadTracks(withMediaType: .audio)) ?? []
                            } else {
                                wavTracks = wavAsset.tracks(withMediaType: .audio)
                            }
                            if let wavTrack = wavTracks.first {
                                // Clamp the WAV duration to clipDuration.
                                // AudioReverser produces PCM frames at 44 100 Hz, so
                                // reversed.duration (= PCMFrameCount/44100) is rarely
                                // equal to clipDuration (video frames / fps).  Even a
                                // few microseconds of overhang extend composition.duration
                                // beyond the AVVideoComposition instruction coverage,
                                // triggering AVErrorInvalidVideoComposition (-11841).
                                let clampedDuration = CMTimeMinimum(reversed.duration, clipDuration)
                                let wavRange = CMTimeRange(start: .zero, duration: clampedDuration)
                                try sharedAudioTrack.insertTimeRange(wavRange, of: wavTrack, at: insertStart)
                                if let speed = clip.playbackSpeed, speed > 0, speed != 1.0 {
                                    let insertedRange = CMTimeRange(start: insertStart, duration: clipDuration)
                                    sharedAudioTrack.scaleTimeRange(insertedRange, toDuration: effectiveDuration)
                                }
                                PluginLog.print("   ✅ Reversed audio inserted (PCM-level, \(reversed.duration.seconds)s)")
                            }
                        } else {
                            PluginLog.print("   ⚠️ AudioReverser returned nil, skipping audio for reversed clip")
                        }
                    } else {
                        var audioInsertTime = insertStart
                        for sourceRange in sourceRanges {
                            try sharedAudioTrack.insertTimeRange(
                                sourceRange,
                                of: audioTrack,
                                at: audioInsertTime
                            )
                            audioInsertTime = CMTimeAdd(audioInsertTime, sourceRange.duration)
                        }
                        if let speed = clip.playbackSpeed, speed > 0, speed != 1.0 {
                            let insertedAudioRange = CMTimeRange(start: insertStart, duration: clipDuration)
                            sharedAudioTrack.scaleTimeRange(insertedAudioRange, toDuration: effectiveDuration)
                        }
                        PluginLog.print("   ✅ Audio inserted into SHARED track!")
                    }
                    PluginLog.print(
                        "      Source time range: \(String(format: "%.2f", clipTimeRange.start.seconds))s - \(String(format: "%.2f", (clipTimeRange.start + clipTimeRange.duration).seconds))s"
                    )
                    PluginLog.print(
                        "      Inserted at composition time: \(String(format: "%.2f", totalDuration.seconds))s"
                    )
                } catch {
                    PluginLog.print("   ❌ ERROR inserting audio: \(error.localizedDescription)")
                    PluginLog.print("      Error details: \(error)")
                }
            }

            totalDuration = CMTimeAdd(totalDuration, effectiveDuration)
            PluginLog.print("✅ Clip \(index) added successfully")
            PluginLog.print("   - Duration: \(String(format: "%.2f", effectiveDuration.seconds))s")
            PluginLog.print(
                "   - Time range in composition: \(String(format: "%.2f", insertStart.seconds))s - \(String(format: "%.2f", totalDuration.seconds))s"
            )
        }

        PluginLog.print("")
        PluginLog.print("📊 ===== VIDEO SEQUENCE SUMMARY =====")
        PluginLog.print("   Total clips: \(videoClips.count)")
        PluginLog.print("   Total duration: \(String(format: "%.2f", totalDuration.seconds))s")
        PluginLog.print("   Max render size: \(maxRenderSize.width) x \(maxRenderSize.height)")
        PluginLog.print("   Max frame rate: \(maxFrameRate) fps")
        PluginLog.print("   Clip instructions: \(clipInstructions.count)")

        // Handle shared audio track - add to result if it has segments, otherwise remove from composition
        if let audioTrack = sharedAudioTrack {
            if !audioTrack.segments.isEmpty {
                originalAudioTracks.append(audioTrack)
                PluginLog.print(
                    "   🔊 AUDIO TRACKS: 1 (shared track with \(audioTrack.segments.count) segment(s))"
                )
                for (segIdx, segment) in audioTrack.segments.enumerated() {
                    let timeMapping = segment as AVCompositionTrackSegment
                    PluginLog.print(
                        "      Segment \(segIdx): \(String(format: "%.2f", timeMapping.timeMapping.target.start.seconds))s - \(String(format: "%.2f", (timeMapping.timeMapping.target.start + timeMapping.timeMapping.target.duration).seconds))s (duration: \(String(format: "%.2f", timeMapping.timeMapping.target.duration.seconds))s)"
                    )
                }
            } else {
                // Remove empty audio track from composition to prevent export errors
                composition.removeTrack(audioTrack)
                PluginLog.print("   🔊 AUDIO TRACKS: 0 (shared track was empty and removed from composition)")
            }
        } else {
            PluginLog.print("   🔊 AUDIO TRACKS: 0 (no audio track created)")
        }

        PluginLog.print("=====================================")
        PluginLog.print("")

        return VideoSequenceResult(
            videoTrack: compositionVideoTrack,
            audioTracks: originalAudioTracks,
            totalDuration: totalDuration,
            renderSize: maxRenderSize,
            frameRate: maxFrameRate,
            clipInstructions: clipInstructions,
            reversedAudioTempURLs: reversedAudioTempURLs
        )
    }

    /// Calculates time range for a clip considering start/end trimming.
    private func calculateTimeRange(for clip: VideoClip, from asset: AVAsset) async -> CMTimeRange {
        let startTime: CMTime
        let endTime: CMTime

        if let startUs = clip.startUs {
            startTime = CMTime(value: startUs, timescale: 1_000_000)
        } else {
            startTime = .zero
        }

        if let endUs = clip.endUs {
            endTime = CMTime(value: endUs, timescale: 1_000_000)
        } else {
            let assetDuration: CMTime
            if #available(macOS 13.0, *) {
                assetDuration = (try? await asset.load(.duration)) ?? .zero
            } else {
                assetDuration = asset.duration
            }
            endTime = assetDuration
        }

        let duration = CMTimeSubtract(endTime, startTime)
        return CMTimeRange(start: startTime, duration: duration)
    }

    /// Returns a frame-sized duration used for reverse rendering slices.
    private func frameDuration(for nominalFrameRate: Float) -> CMTime {
        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30.0
        let timescale = max(1, Int32(fps.rounded()))
        return CMTime(value: 1, timescale: timescale)
    }

    /// Builds forward-playable source slices ordered from the end of the range to the start.
    private func reverseTimeRanges(for timeRange: CMTimeRange, frameDuration: CMTime) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var cursorEnd = CMTimeRangeGetEnd(timeRange)
        var remainingDuration = timeRange.duration

        while CMTimeCompare(remainingDuration, CMTime.zero) > 0 {
            let sliceDuration: CMTime
            if CMTimeCompare(remainingDuration, frameDuration) < 0 {
                sliceDuration = remainingDuration
            } else {
                sliceDuration = frameDuration
            }
            let sliceStart = CMTimeSubtract(cursorEnd, sliceDuration)
            ranges.append(CMTimeRange(start: sliceStart, duration: sliceDuration))
            cursorEnd = sliceStart
            remainingDuration = CMTimeSubtract(remainingDuration, sliceDuration)
        }

        return ranges
    }
}

/// Instruction for a single clip in the sequence.
internal struct ClipInstruction {
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
    let naturalSize: CGSize
    let renderSize: CGSize
}

/// Result of building a video sequence.
internal struct VideoSequenceResult {
    let videoTrack: AVMutableCompositionTrack
    let audioTracks: [AVMutableCompositionTrack]
    let totalDuration: CMTime
    let renderSize: CGSize
    let frameRate: Float
    let clipInstructions: [ClipInstruction]
    /// Temporary WAV files created by AudioReverser for reversed clips.
    /// CompositionBuilder MUST forward these into the caller's cleanup list.
    let reversedAudioTempURLs: [URL]
}

/// Holds the data needed to construct an AVMutableVideoComposition without
/// requiring that deprecated type in intermediate function signatures.
internal struct VideoCompositionData {
    var instructions: [AVVideoCompositionInstructionProtocol]
    let frameDuration: CMTime
    var renderSize: CGSize
}

/// Custom video composition instruction that explicitly provides source track IDs.
/// This is required for older macOS versions where
/// AVMutableVideoCompositionInstruction doesn't properly derive track IDs
/// from layer instructions when using a custom video compositor.
internal class CustomVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol,
    @unchecked Sendable
{
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = false
    let backgroundColor: CGColor?
    let layerInstructions: [AVVideoCompositionLayerInstruction]

    private let _requiredSourceTrackIDs: [NSValue]
    var requiredSourceTrackIDs: [NSValue]? {
        return _requiredSourceTrackIDs
    }

    var passthroughTrackID: CMPersistentTrackID {
        return kCMPersistentTrackID_Invalid
    }

    init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        layerInstructions: [AVVideoCompositionLayerInstruction],
        backgroundColor: CGColor? = nil
    ) {
        self.timeRange = timeRange
        self._requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.layerInstructions = layerInstructions
        self.backgroundColor = backgroundColor
        super.init()
    }
}
