import AVFoundation
import Foundation

/// Builder class for creating video sequences in compositions.
///
/// Handles multiple video clips, audio tracks, volume control,
/// and composition assembly.
internal class VideoSequenceBuilder {

    private let videoClips: [VideoClip]
    private var enableAudio: Bool = true
    private var renderWidth: Double?
    private var renderHeight: Double?

    /// Initializes builder with video clips.
    ///
    /// - Parameter videoClips: Array of video clips to process
    init(videoClips: [VideoClip]) {
        self.videoClips = videoClips
    }

    /// Sets the target render size.
    func setRenderSize(width: Double?, height: Double?) -> VideoSequenceBuilder {
        self.renderWidth = width
        self.renderHeight = height
        return self
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

        if #available(iOS 15.0, *) {
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
    /// - Returns: Tuple containing video tracks, audio tracks, render size, frame rate, and clip instructions
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
        var trackConfigs: [CMPersistentTrackID: VideoClip] = [:]

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

            // Update max render size (only if not explicitly provided)
            if index == 0 && (renderWidth == nil || renderHeight == nil) {
                maxRenderSize = correctedSize
                PluginLog.print("   - 📏 Base render size set from first clip: \(maxRenderSize.width)x\(maxRenderSize.height)")
            } else if renderWidth != nil && renderHeight != nil {
                maxRenderSize = CGSize(width: renderWidth!, height: renderHeight!)
            }

            // Update max frame rate
            if nominalFrameRate > maxFrameRate {
                maxFrameRate = nominalFrameRate
            }

            // Calculate time range for this clip
            let clipTimeRange = await calculateTimeRange(for: clip, from: asset)
            let clipDuration = clipTimeRange.duration

            // Determine insertion time in composition
            let insertionTime: CMTime
            if let segmentTimeUs = clip.segmentTimeUs {
                insertionTime = CMTime(value: segmentTimeUs, timescale: 1_000_000)
            } else {
                insertionTime = totalDuration
            }

            // Create a new track for each clip to support overlapping and independent positioning
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw NSError(
                    domain: "VideoSequenceBuilder",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create video track for clip \(index)"]
                )
            }

            // Insert video clip into the composition track
            try compositionVideoTrack.insertTimeRange(
                clipTimeRange,
                of: videoTrack,
                at: insertionTime
            )

            // Track mapping for compositor
            trackConfigs[compositionVideoTrack.trackID] = clip

            // Add audio if enabled
            var audioTrackID: CMPersistentTrackID? = nil
            if enableAudio,
                let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: asset)
            {
                if let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    do {
                        try compositionAudioTrack.insertTimeRange(
                            clipTimeRange,
                            of: audioTrack,
                            at: insertionTime
                        )
                        originalAudioTracks.append(compositionAudioTrack)
                        audioTrackID = compositionAudioTrack.trackID
                        PluginLog.print("   🔊 Audio inserted into its own track (ID: \(audioTrackID!))")
                    } catch {
                        PluginLog.print("   ❌ ERROR inserting audio: \(error.localizedDescription)")
                    }
                } else {
                    PluginLog.print("   ⚠️ WARNING: Failed to create audio track for clip \(index)")
                }
            }

            // Store instruction for this clip segment
            clipInstructions.append(
                ClipInstruction(
                    timeRange: CMTimeRange(start: insertionTime, duration: clipDuration),
                    transform: preferredTransform,
                    naturalSize: naturalSize,
                    renderSize: correctedSize,
                    trackID: compositionVideoTrack.trackID,
                    audioTrackID: audioTrackID
                ))

            // Update total duration (sequential part)
            if clip.segmentTimeUs == nil {
                totalDuration = CMTimeAdd(totalDuration, clipDuration)
            } else {
                let endInComposition = CMTimeAdd(insertionTime, clipDuration)
                if CMTimeCompare(endInComposition, totalDuration) > 0 {
                    totalDuration = endInComposition
                }
            }

            PluginLog.print("✅ Clip \(index) added successfully")
            PluginLog.print("   - Duration: \(String(format: "%.2f", clipDuration.seconds))s")
            PluginLog.print(
                "   - Time range in composition: \(String(format: "%.2f", insertionTime.seconds))s - \(String(format: "%.2f", CMTimeAdd(insertionTime, clipDuration).seconds))s"
            )
        }

        PluginLog.print("")
        PluginLog.print("📊 ===== VIDEO SEQUENCE SUMMARY =====")
        PluginLog.print("   Total clips: \(videoClips.count)")
        PluginLog.print("   Total duration: \(String(format: "%.2f", totalDuration.seconds))s")
        PluginLog.print("   Render size: \(maxRenderSize.width) x \(maxRenderSize.height)")
        PluginLog.print("   Max frame rate: \(maxFrameRate) fps")
        PluginLog.print("   Clip instructions: \(clipInstructions.count)")
        PluginLog.print("   Audio tracks: \(originalAudioTracks.count)")
        PluginLog.print("=====================================")
        PluginLog.print("")

        return VideoSequenceResult(
            audioTracks: originalAudioTracks,
            totalDuration: totalDuration,
            renderSize: maxRenderSize,
            frameRate: maxFrameRate,
            clipInstructions: clipInstructions,
            trackConfigs: trackConfigs
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
            if #available(iOS 15.0, *) {
                assetDuration = (try? await asset.load(.duration)) ?? .zero
            } else {
                assetDuration = asset.duration
            }
            endTime = assetDuration
        }

        let duration = CMTimeSubtract(endTime, startTime)
        return CMTimeRange(start: startTime, duration: duration)
    }
}

/// Instruction for a single clip in the sequence.
internal struct ClipInstruction {
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
    let naturalSize: CGSize
    let renderSize: CGSize
    let trackID: CMPersistentTrackID
    let audioTrackID: CMPersistentTrackID?
}

/// Result of building a video sequence.
internal struct VideoSequenceResult {
    let audioTracks: [AVMutableCompositionTrack]
    let totalDuration: CMTime
    let renderSize: CGSize
    let frameRate: Float
    let clipInstructions: [ClipInstruction]
    let trackConfigs: [CMPersistentTrackID: VideoClip]
}

/// Holds the data needed to construct an AVMutableVideoComposition without
/// requiring that deprecated type in intermediate function signatures.
internal struct VideoCompositionData {
    var instructions: [AVVideoCompositionInstructionProtocol]
    let frameDuration: CMTime
    var renderSize: CGSize
}

/// Custom video composition instruction that explicitly provides source track IDs.
/// This is required for older iOS versions (e.g., iPhone 7, iOS 15) where
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
        sourceTrackIDs: [CMPersistentTrackID],
        layerInstructions: [AVVideoCompositionLayerInstruction],
        backgroundColor: CGColor? = nil
    ) {
        self.timeRange = timeRange
        self._requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: $0) }
        self.layerInstructions = layerInstructions
        self.backgroundColor = backgroundColor
        super.init()
    }
}
