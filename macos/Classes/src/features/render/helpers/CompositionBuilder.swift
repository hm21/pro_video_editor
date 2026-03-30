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
    private var customAudioPath: String?
    private var customAudioStartTimeUs: Int64?
    private var originalAudioVolume: Float = 1.0
    private var customAudioVolume: Float = 1.0
    private var loopCustomAudio: Bool = true

    /// Initializes builder with configuration.
    ///
    /// - Parameters:
    ///   - videoClips: Array of video clips to process
    ///   - videoEffects: Video effect configuration
    init(videoClips: [VideoClip], videoEffects: VideoCompositorConfig) {
        self.videoClips = videoClips
        self.videoEffects = videoEffects
    }

    /// Enables or disables audio.
    ///
    /// - Parameter enabled: If true, includes original audio from video clips
    /// - Returns: Self for chaining
    func setEnableAudio(_ enabled: Bool) -> CompositionBuilder {
        self.enableAudio = enabled
        return self
    }

    /// Sets custom audio path.
    ///
    /// - Parameter path: Path to custom audio file
    /// - Returns: Self for chaining
    func setCustomAudioPath(_ path: String?) -> CompositionBuilder {
        self.customAudioPath = path
        return self
    }

    /// Sets the start time offset for the custom audio.
    ///
    /// - Parameter startTimeUs: Start time in microseconds from the beginning of the audio file
    /// - Returns: Self for chaining
    func setCustomAudioStartTime(_ startTimeUs: Int64?) -> CompositionBuilder {
        self.customAudioStartTimeUs = startTimeUs
        return self
    }

    /// Sets volume for original video audio.
    ///
    /// - Parameter volume: Volume multiplier (0.0 to 1.0+)
    /// - Returns: Self for chaining
    func setOriginalAudioVolume(_ volume: Float?) -> CompositionBuilder {
        self.originalAudioVolume = volume ?? 1.0
        return self
    }

    /// Sets volume for custom audio.
    ///
    /// - Parameter volume: Volume multiplier (0.0 to 1.0+)
    /// - Returns: Self for chaining
    func setCustomAudioVolume(_ volume: Float?) -> CompositionBuilder {
        self.customAudioVolume = volume ?? 1.0
        return self
    }

    /// Sets whether custom audio should loop.
    ///
    /// - Parameter loop: If true, audio repeats to match video duration
    /// - Returns: Self for chaining
    func setLoopCustomAudio(_ loop: Bool) -> CompositionBuilder {
        self.loopCustomAudio = loop
        return self
    }

    /// Builds the complete composition.
    ///
    /// - Returns: Tuple containing composition, video composition, render size, audio mix, and source track ID
    /// - Throws: Error if composition creation fails
    func build() async throws -> (
        AVMutableComposition, VideoCompositionData, CGSize, AVAudioMix?, CMPersistentTrackID
    ) {
        guard !videoClips.isEmpty else {
            throw NSError(
                domain: "CompositionBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
            )
        }

        print("🎬 Creating composition with \(videoClips.count) video clips")
        print("🔊 Audio enabled: \(enableAudio)")

        let composition = AVMutableComposition()

        // Build video sequence
        let videoBuilder = VideoSequenceBuilder(videoClips: videoClips)
            .setEnableAudio(enableAudio)
            .setOriginalAudioVolume(originalAudioVolume)

        // Log audio mixing configuration
        if customAudioPath != nil && !(customAudioPath?.isEmpty ?? true) && enableAudio
            && originalAudioVolume > 0.0
        {
            print(
                "✅ Audio mixing ENABLED (original: \(originalAudioVolume)x, custom: \(customAudioVolume)x)"
            )
            print("✅ AVFoundation will handle sample rate conversion automatically")
        }

        let videoResult = try await videoBuilder.build(in: composition)

        // Add custom audio track if provided
        var customAudioTrack: AVMutableCompositionTrack?
        if let customPath = customAudioPath, !customPath.isEmpty {
            print("🎵 Adding custom audio track: \(customPath)")
            let audioBuilder = AudioSequenceBuilder(
                audioPath: customPath,
                targetDuration: videoResult.totalDuration
            ).setVolume(customAudioVolume)
                .setLoop(loopCustomAudio)
                .setStartTime(customAudioStartTimeUs)

            customAudioTrack = try await audioBuilder.build(in: composition)
        }

        // Create audio mix with volume parameters
        // Always create audio mix when we have audio tracks to ensure volume control works
        var audioMix: AVAudioMix?
        let hasOriginalAudio = enableAudio && !videoResult.audioTracks.isEmpty
        let hasCustomAudio = customAudioTrack != nil

        if hasOriginalAudio || hasCustomAudio {
            audioMix = createAudioMix(
                originalTracks: videoResult.audioTracks,
                customTrack: customAudioTrack,
                originalVolume: originalAudioVolume,
                customVolume: customAudioVolume
            )
        }

        // Create video composition data
        let frameDuration = CMTime(
            value: 1,
            timescale: Int32(max(30, videoResult.frameRate))
        )
        let compositionRenderSize = videoResult.renderSize

        // Create instructions for each clip segment
        // Use custom instruction class to ensure requiredSourceTrackIDs is properly set
        // This fixes issues on older macOS versions
        var instructions: [AVVideoCompositionInstructionProtocol] = []

        print("")
        print("🎨 ===== CREATING VIDEO INSTRUCTIONS =====")
        print("   Total clips to process: \(videoResult.clipInstructions.count)")
        print(
            "   Target render size: \(videoResult.renderSize.width) x \(videoResult.renderSize.height)"
        )
        print("==========================================")
        print("")

        for (index, clipInstruction) in videoResult.clipInstructions.enumerated() {
            print("🎬 Processing instruction for clip \(index)")
            print(
                "   Time range: \(String(format: "%.2f", clipInstruction.timeRange.start.seconds))s - \(String(format: "%.2f", (clipInstruction.timeRange.start + clipInstruction.timeRange.duration).seconds))s"
            )

            // Create layer instruction for this clip segment
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(
                assetTrack: videoResult.videoTrack
            )

            // Calculate transform to center and scale the video in the render size
            let transform = calculateTransform(
                from: clipInstruction.naturalSize,
                to: videoResult.renderSize,
                with: clipInstruction.transform,
                clipIndex: index
            )

            // Set transform at the start of THIS instruction's time range (relative to instruction start)
            layerInstruction.setTransform(transform, at: .zero)

            // Use custom instruction that explicitly provides requiredSourceTrackIDs
            let instruction = CustomVideoCompositionInstruction(
                timeRange: clipInstruction.timeRange,
                sourceTrackID: videoResult.videoTrack.trackID,
                layerInstructions: [layerInstruction],
                backgroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            )

            print(
                "   ⚙️ Layer instruction configured with transform (trackID: \(videoResult.videoTrack.trackID))"
            )
            print("")

            instructions.append(instruction)
        }

        let videoCompositionData = VideoCompositionData(
            instructions: instructions,
            frameDuration: frameDuration,
            renderSize: compositionRenderSize
        )

        print("✅ Composition created successfully with \(videoClips.count) clips")

        // Return the track ID for fallback on older macOS versions
        let sourceTrackID = videoResult.videoTrack.trackID

        return (composition, videoCompositionData, videoResult.renderSize, audioMix, sourceTrackID)
    }

    /// Creates audio mix with volume parameters.
    private func createAudioMix(
        originalTracks: [AVMutableCompositionTrack],
        customTrack: AVMutableCompositionTrack?,
        originalVolume: Float,
        customVolume: Float
    ) -> AVAudioMix {
        var audioMixInputParameters: [AVMutableAudioMixInputParameters] = []

        // Apply volume to original audio tracks
        for track in originalTracks {
            let inputParameters = AVMutableAudioMixInputParameters(track: track)
            inputParameters.setVolume(originalVolume, at: .zero)
            audioMixInputParameters.append(inputParameters)
            print("🔊 Applied volume \(originalVolume) to original audio track")
        }

        // Apply volume to custom audio track
        if let customTrack = customTrack {
            let inputParameters = AVMutableAudioMixInputParameters(track: customTrack)
            inputParameters.setVolume(customVolume, at: .zero)
            audioMixInputParameters.append(inputParameters)
            print("🔊 Applied volume \(customVolume) to custom audio track")
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
        // Get the display size after applying the original transform (handles rotation)
        let displaySize = naturalSize.applying(preferredTransform)
        let videoWidth = abs(displaySize.width)
        let videoHeight = abs(displaySize.height)

        print("   📐 Transform calculation:")
        print("      Natural size: \(naturalSize.width) x \(naturalSize.height)")
        print("      Display size (after rotation): \(videoWidth) x \(videoHeight)")
        print("      Target render size: \(renderSize.width) x \(renderSize.height)")

        // Calculate scale to fill the render size (we want videos to be the same size)
        let scaleX = renderSize.width / videoWidth
        let scaleY = renderSize.height / videoHeight
        let scale = min(scaleX, scaleY)

        let willBeScaled = abs(scale - 1.0) > 0.01
        let scalePercentage = scale * 100

        if willBeScaled {
            print(
                "      🔍 SCALING: \(String(format: "%.1f%%", scalePercentage)) (factor: \(String(format: "%.3f", scale)))"
            )
            print(
                "         Scale X: \(String(format: "%.3f", scaleX)) | Scale Y: \(String(format: "%.3f", scaleY))"
            )
        } else {
            print("      ✓ No scaling needed (video already fits render size)")
        }

        // Calculate the scaled video dimensions
        let scaledWidth = videoWidth * scale
        let scaledHeight = videoHeight * scale

        print(
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
        print("      Rotation: \(String(format: "%.1f", degrees))°")

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
            print(
                "      Translation (rotated coords): x=\(String(format: "%.1f", finalTranslateX)), y=\(String(format: "%.1f", finalTranslateY))"
            )
        } else {
            finalTranslateX = translateX
            finalTranslateY = translateY
            transform = transform.translatedBy(x: finalTranslateX, y: finalTranslateY)
            print(
                "      Translation: x=\(String(format: "%.1f", finalTranslateX)), y=\(String(format: "%.1f", finalTranslateY))"
            )
        }

        print("   ✅ Transform applied for clip \(clipIndex)")
        print("")

        return transform
    }
}
