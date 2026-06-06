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
      let videoURL = URL(fileURLWithPath: config.inputPath)
      if !FileManager.default.fileExists(atPath: config.inputPath) {
        let error = NSError(
          domain: "ThumbnailGenerator", code: 404,
          userInfo: [NSLocalizedDescriptionKey: "Video file not found at path: \(config.inputPath)"]
        )
        onError(error)
        return
      }
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

      let results = await withCheckedContinuation { continuation in
        var resultData = [Data?](repeating: nil, count: times.count)

        let totalCount = times.count
        var completed = 0
        let start = Date().timeIntervalSince1970

        generator.generateCGImagesAsynchronously(forTimes: times) {
          requestedTime, cgImage, actualTime, result, error in

          let index = completed

          if let cgImage = cgImage {
            let resized = resizeCGImageKeepingAspect(
              cgImage: cgImage,
              targetWidth: config.outputWidth,
              targetHeight: config.outputHeight,
              boxFit: config.boxFit
            )

            let data = compressCGImage(
              resized,
              format: config.outputFormat,
              jpegQuality: config.jpegQuality
            )

            resultData[index] = data

            let elapsed = Int((Date().timeIntervalSince1970 - start) * 1000)

            PluginLog.print(
              "[\(index)] ✅ frame in \(elapsed) ms (\(data.count) bytes)"
            )
          } else {
            let message = error?.localizedDescription ?? "Unknown error"
            PluginLog.print("[\(index)] ❌ frame failed: \(message)")

            let reportableError =
              error
              ?? NSError(
                domain: "ThumbnailGenerator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Frame generation failed at index \(index)"]
              )
            onError(reportableError)
          }

          completed += 1

          onProgress(Double(completed) / Double(totalCount))

          if completed == totalCount {
            continuation.resume(returning: resultData.compactMap { $0 })
          }
        }
      }

      onComplete(results)
    }
  }

  // MARK: - Keyframe timestamps

  private static func extractKeyframeTimestamps(
    asset: AVAsset,
    maxFrames: Int
  ) async -> [NSValue] {

    let duration: CMTime

    if #available(iOS 15.0, macOS 13.0, *) {
      do {
        duration = try await asset.load(.duration)
      } catch {
        PluginLog.print("❌ Failed to load duration: \(error)")
        return []
      }
    } else {
      duration = asset.duration
    }

    guard duration.seconds.isFinite, duration.seconds > 0 else {
      return []
    }

    let safeFrames = max(1, maxFrames)
    let step = duration.seconds / Double(safeFrames)

    return (0..<safeFrames).map { i in
      let time = CMTime(
        seconds: Double(i) * step,
        preferredTimescale: 1_000_000
      )
      return NSValue(time: time)
    }
  }

  // MARK: - Image processing

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

    let newWidth = max(1, Int(originalWidth * scale))
    let newHeight = max(1, Int(originalHeight * scale))

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

  // MARK: - Compression

  private static func compressCGImage(
    _ cgImage: CGImage,
    format: String,
    jpegQuality: Int
  ) -> Data {

    let quality = CGFloat(jpegQuality) / 100.0
    let isPng = format.lowercased() == "png"

    #if canImport(UIKit)
      let image = UIImage(cgImage: cgImage)

      if isPng {
        return image.pngData() ?? Data()
      } else {
        return image.jpegData(compressionQuality: quality) ?? Data()
      }

    #elseif canImport(AppKit)
      let bitmapRep = NSBitmapImageRep(cgImage: cgImage)

      if isPng {
        return bitmapRep.representation(using: .png, properties: [:]) ?? Data()
      } else {
        return bitmapRep.representation(
          using: .jpeg,
          properties: [.compressionFactor: quality]
        ) ?? Data()
      }
    #else
      return Data()
    #endif
  }
}
