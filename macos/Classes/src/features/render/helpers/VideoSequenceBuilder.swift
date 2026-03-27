import AVFoundation
import Foundation

/// Builder class for creating video sequences in compositions.
///
/// Handles multiple video clips, audio tracks, volume control,
/// and composition assembly.
internal class VideoSequenceBuilder {
    
    private let videoClips: [VideoClip]
    private var enableAudio: Bool = true
    private var originalAudioVolume: Float = 1.0
    
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
    
    /// Sets the volume for original video audio.
    ///
    /// - Parameter volume: Volume multiplier (0.0 to 1.0+)
    /// - Returns: Self for chaining
    func setOriginalAudioVolume(_ volume: Float) -> VideoSequenceBuilder {
        self.originalAudioVolume = volume
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
        print("🔍 Total video duration: \(durationMs) ms")
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
        
        print("🎬 Building video sequence with \(videoClips.count) clips")
        print("🔊 Audio enabled: \(enableAudio)")
        
        var totalDuration = CMTime.zero
        var maxRenderSize = CGSize.zero
        var maxFrameRate: Float = 30.0
        var originalAudioTracks: [AVMutableCompositionTrack] = []
        var clipInstructions: [ClipInstruction] = []
        
        // Create single video track for all clips
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
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
                print("🔊 Created SHARED audio track for all clips (will prevent empty segments)")
            }
        }
        
        // Process each video clip
        for (index, clip) in videoClips.enumerated() {
            print("📹 Processing clip \(index): \(clip.inputPath)")
            
            let url = URL(fileURLWithPath: clip.inputPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("❌ ERROR: Video file does not exist: \(clip.inputPath)")
                throw NSError(
                    domain: "VideoSequenceBuilder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Video file does not exist: \(clip.inputPath)"]
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
            print("📹 Clip \(index) properties:")
            print("   - Natural size: \(naturalSize.width) x \(naturalSize.height)")
            print("   - Rotation: \(degrees)° (transform: [\(preferredTransform.a), \(preferredTransform.b), \(preferredTransform.c), \(preferredTransform.d), \(preferredTransform.tx), \(preferredTransform.ty)])")
            print("   - Display size: \(correctedSize.width) x \(correctedSize.height)")
            print("   - Frame rate: \(nominalFrameRate) fps")
            
            // Update max render size
            if correctedSize.width > maxRenderSize.width || correctedSize.height > maxRenderSize.height {
                let oldSize = maxRenderSize
                maxRenderSize = correctedSize
                print("   - ⬆️ Max render size updated: \(oldSize.width)x\(oldSize.height) → \(maxRenderSize.width)x\(maxRenderSize.height)")
            }
            
            // Update max frame rate
            if nominalFrameRate > maxFrameRate {
                maxFrameRate = nominalFrameRate
            }
            
            // Calculate time range for this clip
            let clipTimeRange = await calculateTimeRange(for: clip, from: asset)
            let clipDuration = clipTimeRange.duration
            
            // Insert video clip into the composition track
            try compositionVideoTrack.insertTimeRange(
                clipTimeRange,
                of: videoTrack,
                at: totalDuration
            )
            
            // Store instruction for this clip segment
            clipInstructions.append(ClipInstruction(
                timeRange: CMTimeRange(start: totalDuration, duration: clipDuration),
                transform: preferredTransform,
                naturalSize: naturalSize,
                renderSize: correctedSize
            ))
            
            // Add audio to shared track if enabled
            if enableAudio, let audioTrack = try? await MediaInfoExtractor.loadAudioTrack(from: asset), let sharedAudioTrack = sharedAudioTrack {
                print("🔊 Processing audio for clip \(index)...")
                print("   ✅ Audio track loaded from asset")
                print("      Track ID: \(audioTrack.trackID)")
                print("      Duration: \(String(format: "%.2f", audioTrack.timeRange.duration.seconds))s")
                print("      Format: \(audioTrack.mediaType)")
                
                do {
                    try sharedAudioTrack.insertTimeRange(
                        clipTimeRange,
                        of: audioTrack,
                        at: totalDuration
                    )
                    print("   ✅ Audio inserted into SHARED track!")
                    print("      Source time range: \(String(format: "%.2f", clipTimeRange.start.seconds))s - \(String(format: "%.2f", (clipTimeRange.start + clipTimeRange.duration).seconds))s")
                    print("      Inserted at composition time: \(String(format: "%.2f", totalDuration.seconds))s")
                    print("      Audio duration: \(String(format: "%.2f", clipTimeRange.duration.seconds))s")
                } catch {
                    print("   ❌ ERROR inserting audio: \(error.localizedDescription)")
                    print("      Error details: \(error)")
                }
            }
            
            totalDuration = CMTimeAdd(totalDuration, clipDuration)
            print("✅ Clip \(index) added successfully")
            print("   - Duration: \(String(format: "%.2f", clipDuration.seconds))s")
            print("   - Time range in composition: \(String(format: "%.2f", totalDuration.seconds - clipDuration.seconds))s - \(String(format: "%.2f", totalDuration.seconds))s")
        }
        
        print("")
        print("📊 ===== VIDEO SEQUENCE SUMMARY =====")
        print("   Total clips: \(videoClips.count)")
        print("   Total duration: \(String(format: "%.2f", totalDuration.seconds))s")
        print("   Max render size: \(maxRenderSize.width) x \(maxRenderSize.height)")
        print("   Max frame rate: \(maxFrameRate) fps")
        print("   Clip instructions: \(clipInstructions.count)")
        
        // Handle shared audio track - add to result if it has segments, otherwise remove from composition
        if let audioTrack = sharedAudioTrack {
            if !audioTrack.segments.isEmpty {
                originalAudioTracks.append(audioTrack)
                print("   🔊 AUDIO TRACKS: 1 (shared track with \(audioTrack.segments.count) segment(s))")
                for (segIdx, segment) in audioTrack.segments.enumerated() {
                    let timeMapping = segment as AVCompositionTrackSegment
                    print("      Segment \(segIdx): \(String(format: "%.2f", timeMapping.timeMapping.target.start.seconds))s - \(String(format: "%.2f", (timeMapping.timeMapping.target.start + timeMapping.timeMapping.target.duration).seconds))s (duration: \(String(format: "%.2f", timeMapping.timeMapping.target.duration.seconds))s)")
                }
            } else {
                // Remove empty audio track from composition to prevent export errors
                composition.removeTrack(audioTrack)
                print("   🔊 AUDIO TRACKS: 0 (shared track was empty and removed from composition)")
            }
        } else {
            print("   🔊 AUDIO TRACKS: 0 (no audio track created)")
        }
        
        print("=====================================")
        print("")
        
        return VideoSequenceResult(
            videoTrack: compositionVideoTrack,
            audioTracks: originalAudioTracks,
            totalDuration: totalDuration,
            renderSize: maxRenderSize,
            frameRate: maxFrameRate,
            clipInstructions: clipInstructions
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
}

/// Custom video composition instruction that explicitly provides source track IDs.
/// This is required for older macOS versions where
/// AVMutableVideoCompositionInstruction doesn't properly derive track IDs
/// from layer instructions when using a custom video compositor.
internal class CustomVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
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
    
    init(timeRange: CMTimeRange, 
         sourceTrackID: CMPersistentTrackID,
         layerInstructions: [AVVideoCompositionLayerInstruction],
         backgroundColor: CGColor? = nil) {
        self.timeRange = timeRange
        self._requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.layerInstructions = layerInstructions
        self.backgroundColor = backgroundColor
        super.init()
    }
}
