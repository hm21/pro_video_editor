import AVFoundation
import AppKit
import CoreImage
import Foundation

/// Service for rendering video with applied effects and transformations.
///
/// This class handles the complete video rendering pipeline using AVFoundation:
/// - Supports multiple video clips concatenation
/// - Applies visual effects (rotation, flip, crop, scale, color matrix, blur)
/// - Manages audio mixing (original audio volume + custom audio track)
/// - Supports playback speed adjustment
/// - Provides progress tracking during rendering
/// - Supports cancellation of active render jobs
///
/// All rendering operations are performed asynchronously on a dedicated queue.
class RenderVideo {
    static let queue = DispatchQueue(label: "RenderVideoQueue")

    // MARK: - Public Methods

    /// Starts an asynchronous video render job using RenderConfig.
    ///
    /// This method configures and starts an AVFoundation export session to process
    /// the video with the specified effects. The operation runs asynchronously and
    /// provides callbacks for progress updates, completion, and errors.
    ///
    /// - Parameters:
    ///   - config: Complete render configuration including input, output, and effects
    ///   - onProgress: Callback invoked with progress updates (0.0 to 1.0)
    ///   - onComplete: Callback invoked on success with output bytes (nil if saved to file)
    ///   - onError: Callback invoked if rendering fails
    /// - Returns: RenderJobHandle that can be used to cancel the render job
    @discardableResult
    static func render(
        config: RenderConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Data?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> RenderJobHandle {
        let handle = RenderJobHandle()
        queue.async(group: nil, qos: .default, flags: []) {
            let renderTask = Task {
                guard !config.videoClips.isEmpty else {
                    onError(
                        NSError(
                            domain: "RenderVideo",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Video clips cannot be empty"]
                        ))
                    return
                }
                
                var transcodedFiles: [String] = []
                var workingConfig = config
                
                // HEVC 10-bit HDR videos cause issues with AVFoundation's compositor
                // They must be pre-transcoded to H.264 8-bit SDR for ANY effect processing
                print("🔍 Checking for HEVC 10-bit videos that need transcoding...")
                
                // Pre-transcode HEVC 10-bit HDR videos to H.264 8-bit SDR
                let inputPaths = config.videoClips.map { $0.inputPath }
                let transcodeMap = await VideoTranscoder.transcodeClipsIfNeeded(inputPaths)
                
                // Track transcoded files for cleanup
                transcodedFiles = transcodeMap.values.filter { $0.contains("transcoded_") }
                
                if !transcodedFiles.isEmpty {
                    print("✅ Pre-transcoded \(transcodedFiles.count) HEVC 10-bit videos to H.264")
                    
                    // Update config with transcoded paths
                    let updatedClips = config.videoClips.map { clip -> VideoClip in
                        if let newPath = transcodeMap[clip.inputPath], newPath != clip.inputPath {
                            return VideoClip(
                                inputPath: newPath,
                                startUs: clip.startUs,
                                endUs: clip.endUs
                            )
                        }
                        return clip
                    }
                    
                    // Create new config with updated clips
                    workingConfig = config.copyWith(videoClips: updatedClips)
                }
                
                var outputURL: URL!

                let finalize: () -> Void = {
                    try? cleanup(config.outputPath == nil ? [outputURL] : [])
                    // Clean up transcoded files
                    VideoTranscoder.cleanupTranscodedFiles(transcodedFiles)
                }

                let handleCompletion: (Result<Data?, Error>) -> Void = { result in
                    switch result {
                    case .success(let data): onComplete(data)
                    case .failure(let error): onError(error)
                    }
                    finalize()
                }

                do {
                    if let outputPath = workingConfig.outputPath {
                        // Ensure file extension matches the requested format
                        let url = URL(fileURLWithPath: outputPath)
                        let pathExtension = url.pathExtension.lowercased()
                        let requestedFormat = workingConfig.outputFormat.lowercased()
                        
                        if pathExtension != requestedFormat {
                            print("⚠️ WARNING: Output path extension '.\(pathExtension)' doesn't match requested format '.\(requestedFormat)'")
                            print("⚠️ Correcting file extension to match format...")
                            
                            // Replace extension with correct format
                            let pathWithoutExtension = url.deletingPathExtension()
                            outputURL = pathWithoutExtension.appendingPathExtension(requestedFormat)
                        } else {
                            outputURL = url
                        }
                    } else {
                        outputURL = temporaryURL(for: workingConfig.outputFormat)
                    }

                    print("")
                    print("🎬 ===== RENDER CONFIG =====")
                    print("   Video clips: \(workingConfig.videoClips.count)")
                    print("   📁 Output format: \(workingConfig.outputFormat)")
                    print("   📹 Output path: \(outputURL.path)")
                    print("   🔊 Enable Audio: \(workingConfig.enableAudio)")
                    print("   🔊 Original audio volume: \(workingConfig.originalAudioVolume ?? 1.0)")
                    print("   🔊 Custom audio path: \(workingConfig.customAudioPath ?? "none")")
                    print("   🔊 Custom audio volume: \(workingConfig.customAudioVolume ?? 1.0)")
                    print("===========================")
                    print("")

                    // Create configuration for video effects
                    var effectsConfig = VideoCompositorConfig()

                    // Use composition helper to merge multiple video clips
                    let (composition, videoComposition, renderSize, audioMix, sourceTrackID) =
                        try await applyComposition(
                            videoClips: workingConfig.videoClips,
                            videoEffects: effectsConfig,
                            enableAudio: workingConfig.enableAudio,
                            customAudioPath: workingConfig.customAudioPath,
                            customAudioStartTimeUs: workingConfig.customAudioStartTimeUs,
                            originalAudioVolume: workingConfig.originalAudioVolume,
                            customAudioVolume: workingConfig.customAudioVolume,
                            loopCustomAudio: workingConfig.loopCustomAudio
                        )
                    
                    // Set source track ID for fallback on older macOS versions
                    effectsConfig.sourceTrackID = sourceTrackID

                    // Apply playback speed to the entire composition
                    applyPlaybackSpeed(composition: composition, speed: workingConfig.playbackSpeed)

                    // Get the first video track for orientation info
                    let firstClipURL = URL(fileURLWithPath: workingConfig.videoClips[0].inputPath)
                    let firstAsset = AVURLAsset(url: firstClipURL)
                    let videoTrack = try await loadVideoTrack(from: firstAsset)

                    let preferredTransform: CGAffineTransform
                    if #available(macOS 15.0, *) {
                        preferredTransform = try await videoTrack.load(.preferredTransform)
                    } else {
                        preferredTransform = videoTrack.preferredTransform
                    }

                    let videoRotationDegrees = extractRotationFromTransform(preferredTransform)
                    effectsConfig.videoRotationDegrees = videoRotationDegrees
                    effectsConfig.shouldApplyOrientationCorrection = abs(videoRotationDegrees) > 1.0
                    effectsConfig.originalNaturalSize = videoTrack.naturalSize

                    let croppedSize = applyCrop(
                        config: &effectsConfig,
                        naturalSize: renderSize,
                        rotateTurns: workingConfig.rotateTurns,
                        cropX: workingConfig.cropX,
                        cropY: workingConfig.cropY,
                        cropWidth: workingConfig.cropWidth,
                        cropHeight: workingConfig.cropHeight
                    )
                    applyRotation(config: &effectsConfig, rotateTurns: workingConfig.rotateTurns)
                    applyFlip(config: &effectsConfig, flipX: workingConfig.flipX, flipY: workingConfig.flipY)
                    applyScale(config: &effectsConfig, scaleX: workingConfig.scaleX, scaleY: workingConfig.scaleY)
                    applyColorMatrix(
                        config: &effectsConfig, to: videoComposition,
                        matrixList: workingConfig.colorMatrixList)
                    applyBlur(config: &effectsConfig, sigma: workingConfig.blur)
                    applyImageLayer(config: &effectsConfig, imageData: workingConfig.imageData, withCropping: workingConfig.imageBytesWithCropping)

                    var finalRenderSize = videoComposition.renderSize

                    // Only update renderSize if cropping was actually applied
                    if workingConfig.cropWidth != nil || workingConfig.cropHeight != nil {
                        finalRenderSize = croppedSize
                    } else {
                        if let rotateTurns = workingConfig.rotateTurns {
                            let normalizedRotation = (rotateTurns % 4 + 4) % 4
                            if normalizedRotation == 1 || normalizedRotation == 3 {
                                finalRenderSize = CGSize(
                                    width: finalRenderSize.height,
                                    height: finalRenderSize.width
                                )
                            }
                        }
                    }

                    let effectiveScaleX = workingConfig.scaleX ?? 1.0
                    let effectiveScaleY = workingConfig.scaleY ?? 1.0

                    if effectiveScaleX != 1.0 || effectiveScaleY != 1.0 {
                        finalRenderSize = CGSize(
                            width: finalRenderSize.width * CGFloat(effectiveScaleX),
                            height: finalRenderSize.height * CGFloat(effectiveScaleY)
                        )
                    } else if effectsConfig.scaleX != 1.0 || effectsConfig.scaleY != 1.0 {
                        finalRenderSize = CGSize(
                            width: finalRenderSize.width * effectsConfig.scaleX,
                            height: finalRenderSize.height * effectsConfig.scaleY
                        )
                    }

                    videoComposition.renderSize = finalRenderSize

                    let compositorClass = makeVideoCompositorSubclass(with: effectsConfig)
                    videoComposition.customVideoCompositorClass = compositorClass

                    let preset = applyBitrate(requestedBitrate: workingConfig.bitrate)

                    let export = try prepareExportSession(
                        composition: composition,
                        videoComposition: videoComposition,
                        audioMix: audioMix,
                        outputURL: outputURL,
                        outputFormat: workingConfig.outputFormat,
                        preset: preset,
                        startUs: workingConfig.startUs,
                        endUs: workingConfig.endUs,
                        shouldOptimizeForNetworkUse: workingConfig.shouldOptimizeForNetworkUse
                    )

                    handle.attach(export: export)

                    try await monitorExportProgress(export, onProgress: onProgress)

                    if workingConfig.outputPath != nil {
                        handleCompletion(.success(nil))
                    } else {
                        let data = try Data(contentsOf: outputURL)
                        handleCompletion(.success(data))
                    }
                } catch {
                    handleCompletion(.failure(error))
                }
            }
            handle.attach(task: renderTask)
        }

        return handle
    }

    // MARK: - Helper Methods

    private static func hasGpuIntensiveEffects(_ config: RenderConfig) -> Bool {
        // Check for effects that require GPU processing and may fail with HEVC 10-bit HDR
        let hasImageOverlay = config.imageData != nil
        let hasBlur = config.blur != nil && config.blur! > 0
        let hasColorMatrix = !config.colorMatrixList.isEmpty
        return hasImageOverlay || hasBlur || hasColorMatrix
    }

    private static func makeVideoCompositorSubclass(with config: VideoCompositorConfig)
        -> AVVideoCompositing.Type
    {
        class CustomCompositor: VideoCompositor {}
        CustomCompositor.config = config
        return CustomCompositor.self
    }

    private static func uniqueFilename(prefix: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let timestamp = formatter.string(from: Date())
        return "\(prefix)_\(timestamp).\(ext)"
    }

    private static func temporaryURL(for format: String) -> URL {
        let filename = uniqueFilename(prefix: "output", extension: format)
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
        if #available(macOS 13.0, *) {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw NSError(
                    domain: "RenderVideo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }
            return track
        } else {
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw NSError(
                    domain: "RenderVideo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }
            return track
        }
    }

    private static func extractRotationFromTransform(_ transform: CGAffineTransform) -> Double {
        let rotationAngle = atan2(transform.b, transform.a)
        return rotationAngle * 180 / Double.pi
    }

    private static func prepareExportSession(
        composition: AVAsset,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        outputURL: URL,
        outputFormat: String,
        preset: String,
        startUs: Int64?,
        endUs: Int64?,
        shouldOptimizeForNetworkUse: Bool
    ) throws -> AVAssetExportSession {
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(
                domain: "RenderVideo", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
        }
        
        let fileType = mapFormatToMimeType(format: outputFormat)
        print("📹 Export session setup:")
        print("   - Requested format: \(outputFormat)")
        print("   - AVFileType: \(fileType.rawValue)")
        print("   - Output URL: \(outputURL.path)")
        
        export.outputURL = outputURL
        export.outputFileType = fileType
        export.videoComposition = videoComposition
        
        // Apply global trim (timeRange) if startUs or endUs is provided
        if startUs != nil || endUs != nil {
            let compositionDuration = composition.duration
            let startTime = startUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? .zero
            let endTime = endUs.map { CMTime(value: $0, timescale: 1_000_000) } ?? compositionDuration
            let duration = CMTimeSubtract(endTime, startTime)
            
            // Ensure we don't exceed composition bounds
            let clampedDuration = CMTimeMinimum(duration, CMTimeSubtract(compositionDuration, startTime))
            
            if CMTimeGetSeconds(clampedDuration) > 0 {
                export.timeRange = CMTimeRange(start: startTime, duration: clampedDuration)
                print("   - TimeRange applied: \(String(format: "%.2f", CMTimeGetSeconds(startTime)))s - \(String(format: "%.2f", CMTimeGetSeconds(CMTimeAdd(startTime, clampedDuration))))s")
            }
        }

        // Check if composition has audio tracks
        let hasAudioTracks = (composition as? AVMutableComposition)?.tracks(withMediaType: .audio).isEmpty == false
        
        // Apply audio mix if available
        if let audioMix = audioMix, hasAudioTracks {
            export.audioMix = audioMix
            print("🔊 Audio mix applied to export session")
        } else if !hasAudioTracks {
            print("ℹ️ No audio tracks in composition - exporting video only")
        }
        
        // Apply fast start optimization (moves moov atom to beginning for streaming)
        export.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
        if shouldOptimizeForNetworkUse {
            print("🚀 Fast start enabled - optimizing for network streaming")
        }

        return export
    }

    private static func monitorExportProgress(
        _ export: AVAssetExportSession,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let updateInterval: TimeInterval = 0.2
        if #available(macOS 15.0, *) {
            // Monitor progress in background using new async API
            let progressTask = Task {
                for try await state in export.states(updateInterval: updateInterval) {
                    if case .exporting(let progress) = state {
                        onProgress(progress.fractionCompleted)
                    }
                }
            }

            // Start export using new async API (replaces deprecated exportAsynchronously)
            try await export.export(to: export.outputURL!, as: export.outputFileType!)

            // Ensure progress monitoring completes
            try await progressTask.value
        } else {
            let intervalNs = UInt64(updateInterval * 1_000_000_000)
            export.exportAsynchronously {}
            while export.status == .waiting || export.status == .exporting {
                if export.status == .exporting {
                    let normalizedProgress = min(max(export.progress, 0), 1.0)
                    onProgress(Double(normalizedProgress))
                }
                try await Task.sleep(nanoseconds: intervalNs)
            }

            guard export.status == .completed else {
                throw export.error
                    ?? NSError(
                        domain: "RenderVideo", code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Export failed with status \(export.status.rawValue)"
                        ])
            }
        }
    }

    private static func cleanup(_ urls: [URL]) throws {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

final class RenderJobHandle {
    private let lock = NSLock()
    private var exportSession: AVAssetExportSession?
    private var renderTask: Task<Void, Never>?
    private var canceled = false

    func attach(export: AVAssetExportSession) {
        lock.lock()
        defer { lock.unlock() }
        exportSession = export
        if canceled {
            export.cancelExport()
        }
    }

    func attach(task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        renderTask = task
        if canceled {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let session = exportSession
        let task = renderTask
        lock.unlock()

        task?.cancel()
        session?.cancelExport()
    }
}
