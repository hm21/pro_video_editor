import AVFoundation
import AppKit
import Foundation

/// Service for generating video thumbnail images.
///
/// This class provides functionality to extract frames from video files and convert
/// them into compressed image thumbnails. It supports two extraction modes:
/// - Timestamp-based: Extract frames at specific time positions
/// - Keyframe-based: Extract evenly distributed keyframes (I-frames)
///
/// All operations are performed asynchronously with progress reporting.
class ThumbnailGenerator {

    // MARK: - Public Methods

    /// Asynchronously generates thumbnails from a video file.
    ///
    /// This method determines the extraction mode based on the configuration:
    /// - If timestampsUs is provided, extracts frames at specified timestamps
    /// - If maxOutputFrames is provided, extracts evenly distributed keyframes
    /// - Returns empty list if neither is specified
    ///
    /// All thumbnails are generated in parallel for optimal performance.
    ///
    /// - Parameters:
    ///   - config: Configuration specifying extraction mode, dimensions, and format
    ///   - onProgress: Callback invoked with progress updates (0.0 to 1.0)
    ///   - onComplete: Callback invoked with list of compressed image data on success
    ///   - onError: Callback invoked with error if generation fails
    static func getThumbnails(
        config: ThumbnailConfig,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping ([Data]) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        Task {
            let videoURL = URL(fileURLWithPath: config.inputPath)
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if config.lastFrameTolerance {
                // Use a small tolerance so AVFoundation decodes the
                // nearest frame instead of jumping to a distant keyframe.
                generator.requestedTimeToleranceBefore = CMTime(
                    seconds: 0.1, preferredTimescale: 1_000_000)
                generator.requestedTimeToleranceAfter = .zero
            } else {
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
            }

            let times: [NSValue]
            if !config.timestampsUs.isEmpty {
                times = config.timestampsUs.map {
                    NSValue(time: CMTime(value: $0, timescale: 1_000_000))
                }
            } else if let maxFrames = config.maxOutputFrames {
                times = await extractKeyframeTimestamps(asset: asset, maxFrames: maxFrames)
            } else {
                onComplete([])
                return
            }

            // MARK: - Frame Extraction

            let timeIndexMap: [Double: Int] = Dictionary(
                uniqueKeysWithValues:
                    times.enumerated().map { (index, time) in
                        (time.timeValue.seconds, index)
                    }
            )

            let results = await withCheckedContinuation { continuation in
                var resultData = [Data?](repeating: nil, count: times.count)
                var completed = 0
                let start = Date().timeIntervalSince1970
                let totalCount = times.count

                generator.generateCGImagesAsynchronously(forTimes: times) {
                    requestedTime, cgImage, actualTime, result, error in

                    let key = requestedTime.seconds
                    guard let index = timeIndexMap[key] else {
                        print("⚠️ Unexpected time: \(Int(key * 1000)) ms")
                        return
                    }

                    if let cgImage = cgImage {
                        let resized = resizeCGImageKeepingAspect(
                            cgImage: cgImage,
                            targetWidth: config.outputWidth,
                            targetHeight: config.outputHeight,
                            boxFit: config.boxFit
                        )
                        let data = compressCGImage(
                            resized, format: config.outputFormat, jpegQuality: config.jpegQuality)
                        resultData[index] = data

                        let elapsed = Int((Date().timeIntervalSince1970 - start) * 1000)
                        print(
                            "[\(index)] ✅ \(Int(key * 1000)) ms in \(elapsed) ms (\(data.count) bytes)"
                        )
                    } else {
                        let message = error?.localizedDescription ?? "Unknown error"
                        print("[\(index)] ❌ Failed at \(Int(key * 1000)) ms: \(message)")
                    }

                    completed += 1
                    onProgress(Double(completed) / Double(totalCount))

                    if completed == totalCount {
                        continuation.resume(returning: resultData.compactMap { $0 })
                    }
                }
            }

            let filteredResults = results.filter { !$0.isEmpty }
            onComplete(filteredResults)
        }
    }

    // MARK: - Image Processing

    /// Resizes a CGImage while maintaining aspect ratio.
    ///
    /// This method supports two scaling modes:
    /// - "contain": Scales the image to fit entirely within target dimensions
    /// - "cover": Scales the image to completely fill target dimensions
    ///
    /// - Parameters:
    ///   - cgImage: Source image to resize
    ///   - targetWidth: Target width in pixels
    ///   - targetHeight: Target height in pixels
    ///   - boxFit: Scaling mode ("contain" or "cover")
    /// - Returns: Resized CGImage maintaining original aspect ratio
    private static func resizeCGImageKeepingAspect(
        cgImage: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        boxFit: String
    ) -> CGImage {
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)

        let widthRatio = CGFloat(targetWidth) / originalWidth
        let heightRatio = CGFloat(targetHeight) / originalHeight

        let scale: CGFloat = {
            switch boxFit.lowercased() {
            case "cover": return max(widthRatio, heightRatio)
            default: return min(widthRatio, heightRatio)
            }
        }()

        let newWidth = Int(originalWidth * scale)
        let newHeight = Int(originalHeight * scale)

        let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()!
    }

    /// Compresses a CGImage to a Data object in the specified format.
    ///
    /// Supported formats:
    /// - "png": Lossless compression
    /// - "jpeg"/"jpg": Lossy compression with configurable quality
    ///
    /// - Parameters:
    ///   - cgImage: Source image to compress
    ///   - format: Output format ("png", "jpeg", or "jpg")
    ///   - jpegQuality: JPEG compression quality (0-100). Only affects JPEG format.
    /// - Returns: Compressed image as Data
    private static func compressCGImage(_ cgImage: CGImage, format: String, jpegQuality: Int)
        -> Data
    {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let imageType: NSBitmapImageRep.FileType = {
            switch format.lowercased() {
            case "png": return .png
            case "jpeg", "jpg":
                return .jpeg
            default:
                print("⚠️ Format \(format) not supported, falling back to JPEG")
                return .jpeg
            }
        }()
        let quality = CGFloat(jpegQuality) / 100.0
        return bitmapRep.representation(using: imageType, properties: [.compressionFactor: quality])
            ?? Data()
    }

    // MARK: - Keyframe Extraction

    /// Extracts evenly distributed timestamps for keyframe extraction.
    ///
    /// This method calculates timestamps evenly spaced across the video duration
    /// for extracting a representative set of frames.
    ///
    /// - Parameters:
    ///   - asset: The video asset to extract timestamps from
    ///   - maxFrames: Maximum number of timestamps to generate
    /// - Returns: Array of NSValue-wrapped CMTime timestamps
    private static func extractKeyframeTimestamps(asset: AVAsset, maxFrames: Int) async -> [NSValue]
    {
        let duration: CMTime
        if #available(macOS 13.0, *) {
            do {
                duration = try await asset.load(.duration)
            } catch {
                print("❌ Failed to load duration: \(error.localizedDescription)")
                return []
            }
        } else {
            duration = asset.duration
        }

        guard duration.seconds.isFinite && duration.seconds > 0 else { return [] }

        let step = duration.seconds / Double(maxFrames)
        return (0..<maxFrames).map {
            let time = CMTime(seconds: Double($0) * step, preferredTimescale: 1_000_000)
            return NSValue(time: time)
        }
    }
}
