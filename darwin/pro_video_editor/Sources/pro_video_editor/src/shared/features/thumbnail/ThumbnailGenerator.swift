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

      // The output maps 1:1 to `times`: `result[i]` is the thumbnail for
      // `times[i]` (and therefore for the caller's `timestamps[i]`). A frame that
      // fails or is cancelled is represented positionally as an empty `Data()`
      // rather than being compacted out — dropping it would shift every later
      // frame onto the wrong timestamp. Callers must treat an empty entry as
      // "no thumbnail for this timestamp".
      let results = await generateThumbnailData(
        generator: generator,
        times: times,
        config: config,
        onProgress: onProgress
      )

      onComplete(results)
    }
  }

  // MARK: - Frame extraction

  /// Decodes every requested frame and returns the compressed thumbnails aligned
  /// index-for-index with `times`.
  ///
  /// The returned array is always `times.count` long. Each slot holds the
  /// compressed image for the timestamp at the same index, or an empty `Data()`
  /// when that frame failed or was cancelled. This positional, stable
  /// representation lets the caller map `result[i]` to `timestamps[i]` without
  /// any reordering or compaction.
  private static func generateThumbnailData(
    generator: AVAssetImageGenerator,
    times: [NSValue],
    config: ThumbnailConfig,
    onProgress: @escaping (Double) -> Void
  ) async -> [Data] {
    // An empty request must resolve immediately; feeding an empty array to the
    // generator would never invoke a completion handler and hang the caller.
    guard !times.isEmpty else { return [] }

    if #available(iOS 16.0, macOS 13.0, *) {
      return await generateThumbnailDataOrdered(
        generator: generator, times: times, config: config, onProgress: onProgress)
    }

    return await generateThumbnailDataConcurrent(
      generator: generator, times: times, config: config, onProgress: onProgress)
  }

  /// Modern path (iOS 16+/macOS 13+): consume the ordered
  /// `AVAssetImageGenerator.images(for:)` async sequence.
  ///
  /// Elements arrive serially, so no locking is needed, but the write index is
  /// still derived from each element's `requestedTime` — never from a running
  /// counter — so the alignment guarantee holds regardless of delivery order.
  @available(iOS 16.0, macOS 13.0, *)
  private static func generateThumbnailDataOrdered(
    generator: AVAssetImageGenerator,
    times: [NSValue],
    config: ThumbnailConfig,
    onProgress: @escaping (Double) -> Void
  ) async -> [Data] {
    let totalCount = times.count
    var indices = indexMap(times: times)
    var resultData = [Data?](repeating: nil, count: totalCount)
    var completed = 0
    let start = Date().timeIntervalSince1970

    for await frame in generator.images(for: times.map { $0.timeValue }) {
      let index = indices[timeKey(frame.requestedTime)]?.popLast() ?? -1

      var data: Data?
      do {
        let cgImage = try frame.image
        let rendered = makeThumbnailData(cgImage, config: config)
        data = rendered
        let elapsed = Int((Date().timeIntervalSince1970 - start) * 1000)
        PluginLog.print("[\(index)] ✅ frame in \(elapsed) ms (\(rendered.count) bytes)")
      } catch {
        PluginLog.print("[\(index)] ❌ frame failed: \(error.localizedDescription)")
      }

      if index >= 0, index < totalCount {
        resultData[index] = data
      }

      completed += 1
      onProgress(Double(completed) / Double(totalCount))
    }

    return resultData.map { $0 ?? Data() }
  }

  /// Legacy path (pre-iOS 16 / macOS 13): `generateCGImagesAsynchronously(forTimes:)`
  /// guarantees neither ordered nor serial delivery — on modern OS builds the
  /// completion handler can fire concurrently and out of order (observed on
  /// iOS 26.5).
  ///
  /// Every shared value (`resultData`, `completed`, `resumed`, and the
  /// time → index map) is therefore mutated under a single lock, the write index
  /// is resolved from `requestedTime`, and the continuation is resumed exactly
  /// once even when frames fail or cancel.
  ///
  /// Left at module-internal (not `private`) so the RunnerTests can exercise this
  /// legacy path directly on modern OS versions, which otherwise always take the
  /// ordered async path above.
  static func generateThumbnailDataConcurrent(
    generator: AVAssetImageGenerator,
    times: [NSValue],
    config: ThumbnailConfig,
    onProgress: @escaping (Double) -> Void
  ) async -> [Data] {
    let totalCount = times.count

    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var indices = indexMap(times: times)
      var resultData = [Data?](repeating: nil, count: totalCount)
      var completed = 0
      var resumed = false
      let start = Date().timeIntervalSince1970

      generator.generateCGImagesAsynchronously(forTimes: times) {
        requestedTime, cgImage, _, _, error in

        // Resize + compress happen off the lock; only shared-state mutation is
        // guarded so heavy decoding still runs concurrently.
        var data: Data?
        if let cgImage = cgImage {
          data = makeThumbnailData(cgImage, config: config)
        }

        lock.lock()
        let index = indices[timeKey(requestedTime)]?.popLast() ?? -1
        if index >= 0, index < totalCount {
          resultData[index] = data
        }
        completed += 1
        let progress = Double(completed) / Double(totalCount)
        let shouldResume = completed == totalCount && !resumed
        if shouldResume { resumed = true }
        let payload = shouldResume ? resultData.map { $0 ?? Data() } : nil
        lock.unlock()

        if let data = data {
          let elapsed = Int((Date().timeIntervalSince1970 - start) * 1000)
          PluginLog.print("[\(index)] ✅ frame in \(elapsed) ms (\(data.count) bytes)")
        } else {
          let message = error?.localizedDescription ?? "Unknown error"
          PluginLog.print("[\(index)] ❌ frame failed: \(message)")
        }

        onProgress(progress)

        if let payload = payload {
          continuation.resume(returning: payload)
        }
      }
    }
  }

  /// Builds a map from each requested time's stable key to the result indices
  /// that requested it, so a completion callback can resolve its output slot from
  /// `requestedTime` alone. Buckets are reversed so `popLast()` (O(1)) hands out
  /// ascending indices when the same timestamp is requested more than once.
  private static func indexMap(times: [NSValue]) -> [String: [Int]] {
    var map: [String: [Int]] = [:]
    for (i, value) in times.enumerated() {
      map[timeKey(value.timeValue), default: []].append(i)
    }
    for key in map.keys {
      map[key]?.reverse()
    }
    return map
  }

  /// Stable dictionary key for a requested `CMTime`.
  ///
  /// Every requested time is built with timescale `1_000_000` and the generators
  /// return the requested time unchanged, so an exact `(value, timescale)` key
  /// matches reliably without any floating-point comparison.
  private static func timeKey(_ time: CMTime) -> String {
    "\(time.value)/\(time.timescale)"
  }

  /// Resizes a decoded frame to the configured bounds and compresses it into the
  /// configured output format.
  private static func makeThumbnailData(_ cgImage: CGImage, config: ThumbnailConfig) -> Data {
    let resized = resizeCGImageKeepingAspect(
      cgImage: cgImage,
      targetWidth: config.outputWidth,
      targetHeight: config.outputHeight,
      boxFit: config.boxFit
    )

    return compressCGImage(
      resized,
      format: config.outputFormat,
      jpegQuality: config.jpegQuality
    )
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
