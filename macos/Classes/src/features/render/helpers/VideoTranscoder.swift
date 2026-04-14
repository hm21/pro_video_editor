import AVFoundation
import CoreImage
import Foundation

/// Utility for pre-transcoding HEVC 10-bit HDR videos to H.264 8-bit SDR.
///
/// This is necessary because GPU-based effect pipelines on macOS have compatibility
/// issues with HEVC Main 10 Profile videos. By transcoding to H.264 first,
/// we can then safely apply effects like ColorMatrix, Blur, or Overlay.
internal class VideoTranscoder {

    // MARK: - Result Types

    /// Result of a transcoding operation.
    enum TranscodeResult {
        /// Transcoding succeeded, contains path to transcoded file
        case success(outputPath: String)

        /// No transcoding needed, original file is compatible
        case notNeeded(originalPath: String)

        /// Transcoding failed with error
        case error(Error)
    }

    // MARK: - Public Methods

    /// Checks if a video needs transcoding for effect compatibility.
    ///
    /// - Parameter videoPath: Path to the video file
    /// - Returns: True if transcoding is needed
    static func needsTranscoding(_ videoPath: String) async -> Bool {
        let formatInfo = await MediaInfoExtractor.getVideoFormatInfo(videoPath)
        let needsTranscode = formatInfo.needsTranscodingForEffects()

        PluginLog.print(
            "🔍 Video transcoding check: path=\(videoPath), "
                + "isHevc=\(formatInfo.isHevc), bitDepth=\(formatInfo.bitDepth), "
                + "isHdr=\(formatInfo.isHdr), needsTranscoding=\(needsTranscode)")

        return needsTranscode
    }

    /// Transcodes a video to H.264 8-bit SDR format for effect compatibility.
    ///
    /// Uses HDR → SDR tonemapping to convert 10-bit HDR to 8-bit SDR,
    /// which allows proper GPU effect processing.
    ///
    /// - Parameter videoPath: Path to the input video
    /// - Returns: TranscodeResult indicating success, not-needed, or error
    static func transcodeToH264(_ videoPath: String) async -> TranscodeResult {
        // Check if transcoding is needed
        guard await needsTranscoding(videoPath) else {
            PluginLog.print("✅ No transcoding needed for: \(videoPath)")
            return .notNeeded(originalPath: videoPath)
        }

        PluginLog.print("🎬 Starting HEVC 10-bit HDR → H.264 8-bit SDR transcoding for: \(videoPath)")

        let inputURL = URL(fileURLWithPath: videoPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcoded_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")

        do {
            try await transcodeVideo(from: inputURL, to: outputURL)

            // Verify output
            let outputInfo = await MediaInfoExtractor.getVideoFormatInfo(outputURL.path)
            PluginLog.print("✅ Transcoding completed: \(outputURL.path)")
            PluginLog.print(
                "   Output: isHevc=\(outputInfo.isHevc), bitDepth=\(outputInfo.bitDepth), isHdr=\(outputInfo.isHdr)"
            )

            return .success(outputPath: outputURL.path)

        } catch {
            PluginLog.print("❌ Transcoding failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            return .error(error)
        }
    }

    /// Transcodes multiple video clips if needed.
    ///
    /// - Parameter inputPaths: List of input video paths
    /// - Returns: Dictionary mapping original path to transcoded path (or original if no transcoding needed)
    static func transcodeClipsIfNeeded(_ inputPaths: [String]) async -> [String: String] {
        var result: [String: String] = [:]

        for inputPath in inputPaths {
            switch await transcodeToH264(inputPath) {
            case .success(let outputPath):
                result[inputPath] = outputPath
            case .notNeeded(let originalPath):
                result[inputPath] = originalPath
            case .error:
                PluginLog.print("⚠️ Transcoding failed for \(inputPath), using original")
                result[inputPath] = inputPath
            }
        }

        return result
    }

    /// Cleans up transcoded temporary files.
    ///
    /// - Parameter transcodedPaths: Collection of transcoded file paths to delete
    static func cleanupTranscodedFiles(_ transcodedPaths: [String]) {
        for path in transcodedPaths {
            if path.contains("transcoded_") {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    PluginLog.print("🗑️ Cleaned up transcoded file: \(path)")
                } catch {
                    PluginLog.print("⚠️ Failed to clean up \(path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private Methods

    /// Performs the actual video transcoding using AVAssetExportSession.
    /// This is simpler and more reliable than AVAssetWriter for basic transcoding.
    private static func transcodeVideo(from inputURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(
            url: inputURL,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])

        // Use AVAssetExportSession for simpler, more reliable transcoding
        guard
            let exportSession = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw NSError(
                domain: "VideoTranscoder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        exportSession.shouldOptimizeForNetworkUse = true
        if #unavailable(macOS 15.0) {
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
        }

        // Create video composition for HDR → SDR conversion
        let videoTrack: AVAssetTrack
        if #available(macOS 13.0, *) {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let vTrack = videoTracks.first else {
                throw NSError(
                    domain: "VideoTranscoder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }
            videoTrack = vTrack
        } else {
            guard let vTrack = asset.tracks(withMediaType: .video).first else {
                throw NSError(
                    domain: "VideoTranscoder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No video track found"])
            }
            videoTrack = vTrack
        }

        // Get video properties
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Float

        if #available(macOS 13.0, *) {
            naturalSize = try await videoTrack.load(.naturalSize)
            preferredTransform = try await videoTrack.load(.preferredTransform)
            nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        } else {
            naturalSize = videoTrack.naturalSize
            preferredTransform = videoTrack.preferredTransform
            nominalFrameRate = videoTrack.nominalFrameRate
        }

        // Calculate render size accounting for rotation
        let renderSize = calculateOutputSize(
            naturalSize: naturalSize, transform: preferredTransform)

        // Create video composition with SDR color space filter
        if #available(macOS 26.0, *) {
            let videoComposition = try await AVVideoComposition(applyingFiltersTo: asset) { params in
                var image = params.sourceImage.clampedToExtent()

                if let colorMatrix = CIFilter(name: "CIColorMatrix") {
                    colorMatrix.setValue(image, forKey: kCIInputImageKey)
                    colorMatrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

                    if let output = colorMatrix.outputImage {
                        image = output
                    }
                }

                let cropped = image.cropped(to: CGRect(origin: .zero, size: renderSize))
                return AVCIImageFilteringResult(resultImage: cropped, ciContext: nil)
            }
            exportSession.videoComposition = videoComposition
        } else {
            let videoComposition = AVMutableVideoComposition(asset: asset) { request in
                var image = request.sourceImage.clampedToExtent()

                if let colorMatrix = CIFilter(name: "CIColorMatrix") {
                    colorMatrix.setValue(image, forKey: kCIInputImageKey)
                    colorMatrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

                    if let output = colorMatrix.outputImage {
                        image = output
                    }
                }

                let cropped = image.cropped(to: CGRect(origin: .zero, size: renderSize))
                request.finish(with: cropped, context: nil)
            }

            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate))

            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

            exportSession.videoComposition = videoComposition
        }

        PluginLog.print("🎬 Transcoding with AVAssetExportSession...")
        PluginLog.print("   Input size: \(naturalSize), Output size: \(renderSize)")

        // Export
        if #available(macOS 15.0, *) {
            try await exportSession.export(to: outputURL, as: .mp4)
        } else {
            await exportSession.export()
            guard exportSession.status == .completed else {
                let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
                throw NSError(
                    domain: "VideoTranscoder", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Export failed: \(errorMessage)"])
            }
        }

        PluginLog.print("✅ Transcoding completed successfully")
    }

    /// Calculates output size accounting for rotation.
    private static func calculateOutputSize(naturalSize: CGSize, transform: CGAffineTransform)
        -> CGSize
    {
        let rotationAngle = atan2(transform.b, transform.a)
        let radians = abs(rotationAngle)

        // Check if rotation is ~90° or ~270°
        if radians > .pi / 4 && radians < 3 * .pi / 4 {
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        }
        return naturalSize
    }

    /// Calculates appropriate bitrate based on resolution and frame rate.
    private static func calculateBitrate(size: CGSize, frameRate: Float) -> Int {
        let pixels = Int(size.width * size.height)
        let fps = max(24, min(60, Int(frameRate)))

        // Roughly 0.1 bits per pixel per frame for H.264 High profile
        return max(2_000_000, pixels * fps / 10)
    }
}
