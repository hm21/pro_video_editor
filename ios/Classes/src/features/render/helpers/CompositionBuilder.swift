import AVFoundation
import Foundation

/// Main builder class for creating video compositions from render configurations.
///
/// Orchestrates video sequences, custom audio tracks, and audio mixing.
/// This class delegates the actual work to specialized builders
/// (VideoSequenceBuilder, AudioSequenceBuilder) following the Builder pattern.
internal class CompositionBuilder {

    private let videoClips: [VideoClip]
    private let videoEffects: VideoCompositorConfig
    private var enableAudio: Bool = true
    private var audioTracks: [AudioTrackConfig] = []
    private var renderWidth: Double?
    private var renderHeight: Double?

    /// Initializes builder with configuration.
    ///
    /// - Parameters:
    ///   - videoClips: Array of video clips to process
    ///   - videoEffects: Video effect configuration
    init(videoClips: [VideoClip], videoEffects: VideoCompositorConfig) {
        self.videoClips = videoClips
        self.videoEffects = videoEffects
    }

    /// Sets the target render size.
    func setRenderSize(width: Double?, height: Double?) -> CompositionBuilder {
        self.renderWidth = width
        self.renderHeight = height
        return self
    }

    /// Enables or disables audio.
    ///
    /// - Parameter enabled: If true, includes original audio from video clips
    /// - Returns: Self for chaining
    func setEnableAudio(_ enabled: Bool) -> CompositionBuilder {
        self.enableAudio = enabled
        return self
    }

    /// Sets the audio tracks for mixing.
    ///
    /// - Parameter tracks: Array of audio track configurations
    /// - Returns: Self for chaining
    func setAudioTracks(_ tracks: [AudioTrackConfig]) -> CompositionBuilder {
        self.audioTracks = tracks
        return self
    }

    /// Builds the complete composition.
    ///
    /// - Returns: Tuple containing composition, video composition, render size, audio mix, and source track ID
    /// - Throws: Error if composition creation fails
    func build() async throws -> (
        AVMutableComposition, VideoCompositionData, CGSize, AVAudioMix?, CMPersistentTrackID, VideoCompositorConfig
    ) {
        guard !videoClips.isEmpty else {
            throw NSError(
                domain: "CompositionBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
            )
        }

        PluginLog.print("🎬 Creating composition with \(videoClips.count) video clips")
        PluginLog.print("🔊 Audio enabled: \(enableAudio)")

        let composition = AVMutableComposition()

        // Build video sequence
        let videoBuilder = VideoSequenceBuilder(videoClips: videoClips)
            .setEnableAudio(enableAudio)
            .setRenderSize(width: renderWidth, height: renderHeight)

        let videoResult = try await videoBuilder.build(in: composition)

        // Store track configs for compositor
        var updatedVideoEffects = videoEffects
        updatedVideoEffects.videoClipConfigs = videoResult.trackConfigs

        // Add custom audio tracks
        var customAudioTracks: [(track: AVMutableCompositionTrack, config: AudioTrackConfig)] = []
        for trackConfig in audioTracks {
            PluginLog.print("🎵 Adding audio track: \(trackConfig.path)")
            let audioBuilder = AudioSequenceBuilder(
                audioPath: trackConfig.path,
                targetDuration: videoResult.totalDuration
            ).setVolume(trackConfig.volume)
                .setLoop(trackConfig.loop)
                .setAudioStartTime(trackConfig.audioStartUs)
                .setAudioEndTime(trackConfig.audioEndUs)
                .setCompositionStartTime(trackConfig.startUs == -1 ? nil : trackConfig.startUs)
                .setCompositionEndTime(trackConfig.endUs == -1 ? nil : trackConfig.endUs)

            if let track = try await audioBuilder.build(in: composition) {
                customAudioTracks.append((track: track, config: trackConfig))
            }
        }

        // Create audio mix with per-clip and per-track volume parameters
        var audioMix: AVAudioMix?
        let hasOriginalAudio = enableAudio && !videoResult.audioTracks.isEmpty
        let hasCustomAudio = !customAudioTracks.isEmpty

        if hasOriginalAudio || hasCustomAudio {
            audioMix = createAudioMix(
                originalTracks: videoResult.audioTracks,
                customAudioTracks: customAudioTracks,
                clipInstructions: videoResult.clipInstructions
            )
        }

        // Create video composition data
        let frameDuration = CMTime(
            value: 1,
            timescale: Int32(max(30, videoResult.frameRate))
        )
        let compositionRenderSize = videoResult.renderSize

        // Create instructions for each non-overlapping time segment
        var instructions: [AVVideoCompositionInstructionProtocol] = []

        PluginLog.print("")
        PluginLog.print("🎨 ===== CREATING VIDEO INSTRUCTIONS =====")
        PluginLog.print("   Total clips to process: \(videoResult.clipInstructions.count)")
        PluginLog.print(
            "   Target render size: \(videoResult.renderSize.width) x \(videoResult.renderSize.height)"
        )
        PluginLog.print("==========================================")
        PluginLog.print("")

        // Calculate pre-determined transforms for all clips
        var clipTransforms: [CGAffineTransform] = []
        for (index, clipInstruction) in videoResult.clipInstructions.enumerated() {
            PluginLog.print("🎬 Processing instruction for clip \(index)")
            PluginLog.print(
                "   Time range: \(String(format: "%.2f", clipInstruction.timeRange.start.seconds))s - \(String(format: "%.2f", (clipInstruction.timeRange.start + clipInstruction.timeRange.duration).seconds))s"
            )

            // Create layer instruction for this clip segment
            let transform = calculateTransform(
                from: clipInstruction.naturalSize,
                to: videoResult.renderSize,
                with: clipInstruction.transform,
                clipIndex: index
            )
            clipTransforms.append(transform)
        }

        // Calculate non-overlapping time segments
        let segments = calculateSegments(
            from: videoResult.clipInstructions,
            totalDuration: videoResult.totalDuration
        )

        for (segIndex, segmentRange) in segments.enumerated() {
            PluginLog.print("🎬 Processing segment \(segIndex)")
            PluginLog.print(
                "   Time range: \(String(format: "%.2f", segmentRange.start.seconds))s - \(String(format: "%.2f", (segmentRange.start + segmentRange.duration).seconds))s"
            )

            var activeTrackIDs: [CMPersistentTrackID] = []
            var layerInstructions: [AVVideoCompositionLayerInstruction] = []

            for (clipIndex, clipInstruction) in videoResult.clipInstructions.enumerated() {
                // Check if this clip is active during this segment
                let clipRange = clipInstruction.timeRange
                let intersection = CMTimeRangeGetIntersection(segmentRange, otherRange: clipRange)

                if CMTimeGetSeconds(intersection.duration) > 0 {
                    activeTrackIDs.append(clipInstruction.trackID)

                    let transform = clipTransforms[clipIndex]
                    let mutableLayerInstruction = AVMutableVideoCompositionLayerInstruction(
                        assetTrack: composition.track(withTrackID: clipInstruction.trackID)!
                    )
                    mutableLayerInstruction.setTransform(transform, at: .zero)
                    layerInstructions.append(mutableLayerInstruction)

                    PluginLog.print("   - Added trackID \(clipInstruction.trackID) (Clip \(clipIndex))")
                }
            }

            if !layerInstructions.isEmpty {
                // Use custom instruction that explicitly provides requiredSourceTrackIDs
                let instruction = CustomVideoCompositionInstruction(
                    timeRange: segmentRange,
                    sourceTrackIDs: activeTrackIDs,
                    layerInstructions: layerInstructions,
                    backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                )
                instructions.append(instruction)
                PluginLog.print("   ✅ Segment instruction created with \(layerInstructions.count) layers")
            }
            PluginLog.print("")
        }

        let videoCompositionData = VideoCompositionData(
            instructions: instructions,
            frameDuration: frameDuration,
            renderSize: compositionRenderSize
        )

        PluginLog.print("✅ Composition created successfully with \(videoClips.count) clips")

        // Return the first track ID for fallback on older iOS versions
        let sourceTrackID = videoResult.clipInstructions.first?.trackID ?? kCMPersistentTrackID_Invalid

        return (composition, videoCompositionData, videoResult.renderSize, audioMix, sourceTrackID, updatedVideoEffects)
    }

    /// Creates audio mix with per-clip and per-track volume parameters.
    private func createAudioMix(
        originalTracks: [AVMutableCompositionTrack],
        customAudioTracks: [(track: AVMutableCompositionTrack, config: AudioTrackConfig)],
        clipInstructions: [ClipInstruction]
    ) -> AVAudioMix {
        var audioMixInputParameters: [AVMutableAudioMixInputParameters] = []

        // Apply per-clip volume to original audio tracks
        for track in originalTracks {
            let inputParameters = AVMutableAudioMixInputParameters(track: track)

            // Find all instructions that apply to this specific audio track
            let relevantInstructions = clipInstructions.enumerated().filter { _, instruction in
                instruction.audioTrackID == track.trackID
            }

            for (index, clipInstruction) in relevantInstructions {
                let clipVolume = index < videoClips.count
                    ? (videoClips[index].volume ?? 1.0) : 1.0

                PluginLog.print("🔊 Setting volume ramp for track \(track.trackID): volume=\(clipVolume) at \(String(format: "%.2f", clipInstruction.timeRange.start.seconds))s")

                inputParameters.setVolumeRamp(
                    fromStartVolume: clipVolume,
                    toEndVolume: clipVolume,
                    timeRange: clipInstruction.timeRange
                )
            }

            audioMixInputParameters.append(inputParameters)
            PluginLog.print("🔊 Applied per-clip volume to original audio track (ID: \(track.trackID))")
        }

        // Apply volume to custom audio tracks
        for (track, config) in customAudioTracks {
            let inputParameters = AVMutableAudioMixInputParameters(track: track)
            inputParameters.setVolume(config.volume, at: .zero)
            audioMixInputParameters.append(inputParameters)
            PluginLog.print("🔊 Applied volume \(config.volume) to custom audio track: \(config.path)")
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixInputParameters

        return audioMix
    }

    /// Calculates the transform to center and fit a video in the target render size.
    ///
    /// - Parameters:
    ///   - naturalSize: Original size of the video
    ///   - renderSize: Target render size
    ///   - preferredTransform: Original transform from the video track
    /// - Returns: Combined transform to center and fit the video
    private func calculateTransform(
        from naturalSize: CGSize,
        to renderSize: CGSize,
        with preferredTransform: CGAffineTransform,
        clipIndex: Int
    ) -> CGAffineTransform {
        // If manual positioning is requested, use the preferred transform as-is.
        // The compositor will handle custom scaling and positioning based on VideoClip config.
        if clipIndex < videoClips.count {
            let clip = videoClips[clipIndex]
            if clip.x != nil || clip.y != nil || clip.width != nil || clip.height != nil {
                PluginLog.print("   🎯 Manual positioning detected for clip \(clipIndex), skipping fit and center transform")
                return preferredTransform
            }
        }

        // Get the display size after applying the original transform (handles rotation)
        let displaySize = naturalSize.applying(preferredTransform)
        let videoWidth = abs(displaySize.width)
        let videoHeight = abs(displaySize.height)

        PluginLog.print("   📐 Transform calculation:")
        PluginLog.print("      Natural size: \(naturalSize.width) x \(naturalSize.height)")
        PluginLog.print("      Display size (after rotation): \(videoWidth) x \(videoHeight)")
        PluginLog.print("      Target render size: \(renderSize.width) x \(renderSize.height)")

        // Calculate scale to fill the render size (we want videos to be the same size)
        let scaleX = renderSize.width / videoWidth
        let scaleY = renderSize.height / videoHeight
        let scale = min(scaleX, scaleY)

        let willBeScaled = abs(scale - 1.0) > 0.01
        let scalePercentage = scale * 100

        if willBeScaled {
            PluginLog.print(
                "      🔍 SCALING: \(String(format: "%.1f%%", scalePercentage)) (factor: \(String(format: "%.3f", scale)))"
            )
            PluginLog.print(
                "         Scale X: \(String(format: "%.3f", scaleX)) | Scale Y: \(String(format: "%.3f", scaleY))"
            )
        } else {
            PluginLog.print("      ✓ No scaling needed (video already fits render size)")
        }

        // Calculate the scaled video dimensions
        let scaledWidth = videoWidth * scale
        let scaledHeight = videoHeight * scale

        PluginLog.print(
            "      Final video size: \(String(format: "%.1f", scaledWidth)) x \(String(format: "%.1f", scaledHeight))"
        )

        // Calculate translation to center the scaled video
        let translateX = (renderSize.width - scaledWidth) / 2
        let translateY = (renderSize.height - scaledHeight) / 2

        // Build the transform step by step
        // 1. Start with the preferred transform (handles rotation)
        var transform = preferredTransform

        let angle = atan2(preferredTransform.b, preferredTransform.a)
        let degrees = angle * 180 / .pi
        PluginLog.print("      Rotation: \(String(format: "%.1f", degrees))°")

        // 2. Scale the video to fit the render size
        transform = transform.scaledBy(x: scale, y: scale)

        // 3. Translate to center position
        // Note: translation needs to account for rotation
        let isRotated90Or270 = abs(angle - .pi / 2) < 0.01 || abs(angle + .pi / 2) < 0.01

        let finalTranslateX: CGFloat
        let finalTranslateY: CGFloat

        if isRotated90Or270 {
            // For 90° or 270° rotation, swap translation coordinates
            finalTranslateX = translateY
            finalTranslateY = translateX
            transform = transform.translatedBy(x: finalTranslateX, y: finalTranslateY)
            PluginLog.print(
                "      Translation (rotated coords): x=\(String(format: "%.1f", finalTranslateX)), y=\(String(format: "%.1f", finalTranslateY))"
            )
        } else {
            finalTranslateX = translateX
            finalTranslateY = translateY
            transform = transform.translatedBy(x: finalTranslateX, y: finalTranslateY)
            PluginLog.print(
                "      Translation: x=\(String(format: "%.1f", finalTranslateX)), y=\(String(format: "%.1f", finalTranslateY))"
            )
        }

        PluginLog.print("   ✅ Transform applied for clip \(clipIndex)")
        PluginLog.print("")

        return transform
    }

    /// Calculates non-overlapping time segments from clip instructions.
    private func calculateSegments(from instructions: [ClipInstruction], totalDuration: CMTime) -> [CMTimeRange] {
        var points: [CMTime] = [.zero, totalDuration]
        for instruction in instructions {
            points.append(instruction.timeRange.start)
            points.append(CMTimeAdd(instruction.timeRange.start, instruction.timeRange.duration))
        }

        let sortedPoints = points
            .filter { CMTimeCompare($0, totalDuration) <= 0 }
            .sorted { CMTimeCompare($0, $1) < 0 }

        var uniquePoints: [CMTime] = []
        for point in sortedPoints {
            if let last = uniquePoints.last {
                if CMTimeCompare(last, point) != 0 {
                    uniquePoints.append(point)
                }
            } else {
                uniquePoints.append(point)
            }
        }

        var segments: [CMTimeRange] = []
        for i in 0..<uniquePoints.count - 1 {
            let start = uniquePoints[i]
            let end = uniquePoints[i+1]
            let duration = CMTimeSubtract(end, start)
            if CMTimeGetSeconds(duration) > 0 {
                segments.append(CMTimeRange(start: start, duration: duration))
            }
        }
        return segments
    }
}
