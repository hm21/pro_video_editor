import AVFoundation
import CoreImage
import Foundation

class RenderVideo {
    static let queue = DispatchQueue(label: "RenderVideoQueue")

    @discardableResult
    static func render(
        inputPath: String,
        imageData: Data?,
        inputFormat: String,
        outputFormat: String,
        outputPath: String?,
        rotateTurns: Int?,
        flipX: Bool,
        flipY: Bool,
        cropWidth: Int?,
        cropHeight: Int?,
        cropX: Int?,
        cropY: Int?,
        scaleX: Float?,
        scaleY: Float?,
        bitrate: Int?,
        enableAudio: Bool,
        playbackSpeed: Float?,
        startUs: Int64?,
        endUs: Int64?,
        colorMatrixList: [[Double]],
        blur: Double?,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Data?) -> Void,
        onError: @escaping (Error) -> Void
    ) -> RenderJobHandle {
        let handle = RenderJobHandle()
        queue.async {
            let renderTask = Task {
                var inputURL: URL!
                var outputURL: URL!

                let finalize: () -> Void = {
                    try? cleanup(outputPath == nil ? [outputURL] : [])
                }

                let handleCompletion: (Result<Data?, Error>) -> Void = { result in
                    switch result {
                    case .success(let data): onComplete(data)
                    case .failure(let error): onError(error)
                    }
                    finalize()
                }

                do {
                    inputURL = URL(fileURLWithPath: inputPath)
                    if let outputPath = outputPath {
                        outputURL = URL(fileURLWithPath: outputPath)
                    } else {
                        outputURL = temporaryURL(for: outputFormat)
                    }

                    let asset = AVURLAsset(url: inputURL)
                    let composition = AVMutableComposition()
                    var config = VideoCompositorConfig()

                    let videoTrack = try await loadVideoTrack(from: asset)

                    let timeRange = await applyTrim(asset: asset, startUs: startUs, endUs: endUs)

                    let videoCompositionTrack = try insertVideoTrack(
                        into: composition,
                        from: videoTrack,
                        timeRange: timeRange
                    )

                    // Apply audio track
                    await applyAudio(
                        from: asset, to: composition, timeRange: timeRange, enableAudio: enableAudio
                    )
                    applyPlaybackSpeed(composition: composition, speed: playbackSpeed)

                    // Enhanced video composition with orientation handling
                    let (videoComposition, correctedNaturalSize, preferredTransform) =
                        try await createVideoComposition(
                            asset: asset,
                            track: videoCompositionTrack,
                            duration: composition.duration
                        )

                    let videoRotationDegrees = extractRotationFromTransform(preferredTransform)
                    config.videoRotationDegrees = videoRotationDegrees
                    config.shouldApplyOrientationCorrection = abs(videoRotationDegrees) > 1.0
                    config.originalNaturalSize = videoTrack.naturalSize

                    let croppedSize = applyCrop(
                        config: &config,
                        naturalSize: correctedNaturalSize,
                        rotateTurns: rotateTurns,
                        cropX: cropX,
                        cropY: cropY,
                        cropWidth: cropWidth,
                        cropHeight: cropHeight
                    )

                    applyRotation(config: &config, rotateTurns: rotateTurns)
                    applyFlip(config: &config, flipX: flipX, flipY: flipY)
                    applyScale(config: &config, scaleX: scaleX, scaleY: scaleY)
                    applyColorMatrix(
                        config: &config, to: videoComposition, matrixList: colorMatrixList)
                    applyBlur(config: &config, sigma: blur)
                    applyImageLayer(config: &config, imageData: imageData)

                    var finalRenderSize = videoComposition.renderSize

                    // Only update renderSize if cropping was actually applied
                    if cropWidth != nil || cropHeight != nil {
                        finalRenderSize = croppedSize
                    } else {
                        if let rotateTurns = rotateTurns {
                            let normalizedRotation = (rotateTurns % 4 + 4) % 4
                            if normalizedRotation == 1 || normalizedRotation == 3 {
                                finalRenderSize = CGSize(
                                    width: finalRenderSize.height,
                                    height: finalRenderSize.width
                                )
                            }
                        }
                    }

                    let effectiveScaleX = scaleX ?? 1.0
                    let effectiveScaleY = scaleY ?? 1.0

                    if effectiveScaleX != 1.0 || effectiveScaleY != 1.0 {
                        finalRenderSize = CGSize(
                            width: finalRenderSize.width * CGFloat(effectiveScaleX),
                            height: finalRenderSize.height * CGFloat(effectiveScaleY)
                        )
                    } else if config.scaleX != 1.0 || config.scaleY != 1.0 {
                        finalRenderSize = CGSize(
                            width: finalRenderSize.width * config.scaleX,
                            height: finalRenderSize.height * config.scaleY
                        )
                    }

                    videoComposition.renderSize = finalRenderSize

                    let compositorClass = makeVideoCompositorSubclass(with: config)
                    videoComposition.customVideoCompositorClass = compositorClass

                    let preset = applyBitrate(requestedBitrate: bitrate)

                    let export = try prepareExportSession(
                        composition: composition,
                        videoComposition: videoComposition,
                        outputURL: outputURL,
                        outputFormat: outputFormat,
                        preset: preset
                    )
                    handle.attach(export: export)

                    try await monitorExportProgress(export, onProgress: onProgress)

                    if outputPath != nil {
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

    private static func writeInputVideo(_ data: Data, format: String) throws -> URL {
        let filename = uniqueFilename(prefix: "input", extension: format)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    private static func temporaryURL(for format: String) -> URL {
        let filename = uniqueFilename(prefix: "output", extension: format)
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
        if #available(iOS 15.0, *) {
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

    private static func insertVideoTrack(
        into composition: AVMutableComposition,
        from videoTrack: AVAssetTrack,
        timeRange: CMTimeRange
    ) throws -> AVMutableCompositionTrack {
        guard
            let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw NSError(
                domain: "RenderVideo", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create video track"])
        }
        try track.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        return track
    }

    private static func createVideoComposition(
        asset: AVAsset,
        track: AVCompositionTrack,
        duration: CMTime
    ) async throws -> (AVMutableVideoComposition, CGSize, CGAffineTransform) {
        // Get the original video track to extract properties
        let originalVideoTracks: [AVAssetTrack]
        if #available(iOS 15.0, *) {
            originalVideoTracks = try await asset.loadTracks(withMediaType: .video)
        } else {
            originalVideoTracks = asset.tracks(withMediaType: .video)
        }

        guard let originalVideoTrack = originalVideoTracks.first else {
            throw NSError(
                domain: "RenderVideo", code: 150,
                userInfo: [NSLocalizedDescriptionKey: "No original video track found"])
        }

        // Get video properties
        let naturalSize: CGSize
        let nominalFrameRate: Float
        let preferredTransform: CGAffineTransform

        if #available(iOS 15.0, *) {
            naturalSize = try await originalVideoTrack.load(.naturalSize)
            nominalFrameRate = try await originalVideoTrack.load(.nominalFrameRate)
            preferredTransform = try await originalVideoTrack.load(.preferredTransform)
        } else {
            naturalSize = originalVideoTrack.naturalSize
            nominalFrameRate = originalVideoTrack.nominalFrameRate
            preferredTransform = originalVideoTrack.preferredTransform
        }

        // Calculate display size after applying transform (handles rotation)
        let displaySize = naturalSize.applying(preferredTransform)
        let correctedSize = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        let composition = AVMutableVideoComposition()
        composition.frameDuration = CMTime(value: 1, timescale: Int32(max(30, nominalFrameRate)))
        composition.renderSize = correctedSize

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        return (composition, correctedSize, preferredTransform)
    }

    private static func extractRotationFromTransform(_ transform: CGAffineTransform) -> Double {
        let rotationAngle = atan2(transform.b, transform.a)
        return rotationAngle * 180 / Double.pi
    }

    private static func prepareExportSession(
        composition: AVAsset,
        videoComposition: AVVideoComposition,
        outputURL: URL,
        outputFormat: String,
        preset: String
    ) throws -> AVAssetExportSession {
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(
                domain: "RenderVideo", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
        }
        export.outputURL = outputURL
        export.outputFileType = mapFormatToMimeType(format: outputFormat)
        export.videoComposition = videoComposition
        return export
    }

    private static func monitorExportProgress(
        _ export: AVAssetExportSession,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let updateInterval: TimeInterval = 0.2
        /*  if #available(macOS 15.0, *) {
        
             for try await state in export.states(updateInterval: updateInterval) {
                 switch state {
                 case .waiting:
                     break
                 case .pending:
                     break
                 case .exporting(let progress):
                     onProgress(progress.fractionCompleted)
                 @unknown default:
                     throw NSError(
                         domain: "RenderVideo", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Unknown export state encountered"]
                     )
                 }
             }
         } else { */
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
        /*  } */
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
