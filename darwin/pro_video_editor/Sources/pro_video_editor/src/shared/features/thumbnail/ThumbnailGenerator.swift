import AVFoundation
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

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
            do {
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
                            PluginLog.print("⚠️ Unexpected time: \(Int(key * 1000)) ms")
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
                                resized, format: config.outputFormat,
                                jpegQuality: config.jpegQuality)
                            resultData[index] = data

                            let elapsed = Int((Date().timeIntervalSince1970 - start) * 1000)
                            PluginLog.print(
                                "[\(index)] ✅ \(Int(key * 1000)) ms in \(elapsed) ms (\(data.count) bytes)"
                            )
                        } else {
                            let message = error?.localizedDescription ?? "Unknown error"
                            PluginLog.print(
                                "[\(index)] ❌ Failed at \(Int(key * 1000)) ms: \(message)")
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
            } catch {
                onError(error)
            }
        }
    }

    // MARK: - Image Processing

    /// Resizes a CGImage while maintaining aspect ratio.
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

    /// Compresses a CGImage to a Data object in the specified format across iOS and macOS platforms.
    private static func compressCGImage(_ cgImage: CGImage, format: String, jpegQuality: Int)
        -> Data
    {
        let quality = CGFloat(jpegQuality) / 100.0
        let isPng = format.lowercased() == "png"

        #if canImport(UIKit)
            let image = UIImage(cgImage: cgImage)
            if isPng {
                return image.pngData() ?? Data()
            } else {
                if format.lowercased() != "jpeg" && format.lowercased() != "jpg" {
                    PluginLog.print("⚠️ Format \(format) not supported, falling back to JPEG")
                }
                return image.jpegData(compressionQuality: quality) ?? Data()
            }
        #elseif canImport(AppKit)
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            if isPng {
                return bitmapRep.representation(using: .png, properties: [:]) ?? Data()
            } else {
                if format.lowercased() != "jpeg" && format.lowercased() != "jpg" {
                    PluginLog.print("⚠️ Format \(format) not supported, falling back to JPEG")
                }
                return bitmapRep.representation(
                    using: .jpeg, properties: [.compressionFactor: quality]) ?? Data()
            }
        #else
            return Data()
        #endif
    }

    // MARK: - Keyframe Extraction

    /// Extracts evenly distributed timestamps for keyframe extraction.
    private static func extractKeyframeTimestamps(asset: AVAsset, maxFrames: Int) async -> [NSValue]
    {
        let duration: CMTime
        if #available(iOS 15.0, macOS 13.0, *) {
            do {
                duration = try await asset.load(.duration)
            } catch {
                PluginLog.print("❌ Failed to load duration: \(error.localizedDescription)")
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
