import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Service for rendering a stop-motion video from a sequence of still images.
///
/// Each frame is held for a fixed duration and encoded into a single video
/// using `AVAssetWriter` and a pixel-buffer adaptor. The output is silent;
/// audio can be added afterwards via the regular render pipeline.
internal enum StopMotionGenerator {
  private static let queue = DispatchQueue(
    label: "ch.waio.pro_video_editor.stopmotion", qos: .userInitiated)

  /// Starts an asynchronous stop-motion render job.
  ///
  /// - Parameters:
  ///   - config: The stop-motion render configuration.
  ///   - onProgress: Called with progress in the range 0.0...1.0.
  ///   - onComplete: Called with the encoded video bytes, or `nil` when written
  ///     directly to `config.outputPath`.
  ///   - onError: Called when the job fails or is cancelled.
  /// - Returns: A cancellable job handle.
  @discardableResult
  static func generate(
    config: StopMotionConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping (Data?) -> Void,
    onError: @escaping (Error) -> Void
  ) -> RenderJobHandle {
    let handle = RenderJobHandle()
    queue.async {
      let task = Task {
        do {
          let data = try await encode(config: config, onProgress: onProgress)
          onComplete(data)
        } catch {
          onError(error)
        }
      }
      handle.attach(task: task)
    }
    return handle
  }

  // MARK: - Encoding

  private static func encode(
    config: StopMotionConfig,
    onProgress: @escaping (Double) -> Void
  ) async throws -> Data? {
    guard !config.frames.isEmpty else {
      throw NSError(
        domain: "StopMotion", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Frames cannot be empty"])
    }

    // Decode the first frame (orientation-corrected, full size) to derive the
    // output size when not provided.
    guard let firstImage = decodeImage(config.frames[0].imageData, maxPixelSize: nil) else {
      throw NSError(
        domain: "StopMotion", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to decode first frame"])
    }

    let targetWidth = evenize(config.width ?? firstImage.width)
    let targetHeight = evenize(config.height ?? firstImage.height)
    let maxDimension = max(targetWidth, targetHeight)

    let outputURL = resolveOutputURL(
      outputPath: config.outputPath, format: config.outputFormat)

    let writer = try AVAssetWriter(
      outputURL: outputURL, fileType: mapFormatToMimeType(format: config.outputFormat))

    let bitrate = config.bitrate ?? defaultBitrate(width: targetWidth, height: targetHeight)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: targetWidth,
      AVVideoHeightKey: targetHeight,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate
      ],
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: targetWidth,
      kCVPixelBufferHeightKey as String: targetHeight,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: attributes)

    guard writer.canAdd(input) else {
      throw NSError(
        domain: "StopMotion", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to writer"])
    }
    writer.add(input)

    guard writer.startWriting() else {
      throw writer.error
        ?? NSError(
          domain: "StopMotion", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
    }
    writer.startSession(atSourceTime: .zero)

    let defaultDurationUs = Int64((1_000_000.0 / config.frameRate).rounded())
    var cursorUs: Int64 = 0
    let frameCount = config.frames.count

    do {
      for (index, frame) in config.frames.enumerated() {
        try Task.checkCancellation()

        let image = index == 0
          ? firstImage : decodeImage(frame.imageData, maxPixelSize: maxDimension)
        guard let image = image else {
          throw NSError(
            domain: "StopMotion", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Failed to decode frame \(index)"])
        }

        // Wait until the writer can accept more samples.
        while !input.isReadyForMoreMediaData {
          try Task.checkCancellation()
          try await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
        }

        guard
          let buffer = makePixelBuffer(
            from: image, width: targetWidth, height: targetHeight, fit: config.fit,
            pool: adaptor.pixelBufferPool)
        else {
          throw NSError(
            domain: "StopMotion", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }

        let presentationTime = CMTime(value: cursorUs, timescale: 1_000_000)
        guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
          throw writer.error
            ?? NSError(
              domain: "StopMotion", code: 7,
              userInfo: [NSLocalizedDescriptionKey: "Failed to append frame \(index)"])
        }

        let durationUs = frame.durationUs ?? defaultDurationUs
        cursorUs += max(durationUs, 1)
        // Reserve 1.0 for after finishWriting so the finalize step stays
        // visible and the last value before completion is < 100%.
        onProgress(min(Double(index + 1) / Double(frameCount), 0.99))
      }
    } catch {
      input.markAsFinished()
      writer.cancelWriting()
      cleanupIfTemporary(outputURL, outputPath: config.outputPath)
      throw error
    }

    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: cursorUs, timescale: 1_000_000))

    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }

    guard writer.status == .completed else {
      cleanupIfTemporary(outputURL, outputPath: config.outputPath)
      throw writer.error
        ?? NSError(
          domain: "StopMotion", code: 8,
          userInfo: [NSLocalizedDescriptionKey: "Writer finished with status \(writer.status.rawValue)"]
        )
    }

    onProgress(1.0)

    if config.outputPath != nil {
      return nil
    }

    let data = try Data(contentsOf: outputURL)
    try? FileManager.default.removeItem(at: outputURL)
    return data
  }

  // MARK: - Helpers

  /// Decodes an encoded image, applying its EXIF orientation. When
  /// [maxPixelSize] is provided the image is also downscaled so its largest
  /// dimension does not exceed that value (keeps memory/CPU low for big photos).
  private static func decodeImage(_ data: Data, maxPixelSize: Int?) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    var options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Bake the EXIF orientation into the pixels so portrait photos are not
      // rendered sideways.
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    if let maxPixelSize = maxPixelSize {
      options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
    }

    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// Rounds a dimension down to the nearest even value (codec requirement),
  /// with a minimum of 2.
  private static func evenize(_ value: Int) -> Int {
    return max(2, value - (value % 2))
  }

  private static func defaultBitrate(width: Int, height: Int) -> Int {
    return max(1_000_000, width * height * 4)
  }

  private static func resolveOutputURL(outputPath: String?, format: String) -> URL {
    if let outputPath = outputPath {
      let url = URL(fileURLWithPath: outputPath)
      if url.pathExtension.lowercased() != format.lowercased() {
        return url.deletingPathExtension().appendingPathExtension(format.lowercased())
      }
      return url
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
    let random = UInt32.random(in: 0...UInt32.max)
    let filename = "stopmotion_\(formatter.string(from: Date()))_\(random).\(format)"
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  }

  private static func cleanupIfTemporary(_ url: URL, outputPath: String?) {
    if outputPath == nil {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Renders [image] into a BGRA pixel buffer of the target size using the
  /// requested fit mode and a black background.
  private static func makePixelBuffer(
    from image: CGImage, width: Int, height: Int, fit: String,
    pool: CVPixelBufferPool?
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    if let pool = pool {
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    }
    if buffer == nil {
      let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ]
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &buffer)
    }
    guard let pixelBuffer = buffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    guard
      let context = CGContext(
        data: base, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
    else { return nil }

    // Fill background black.
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Draw the image directly: a CGBitmapContext over a CVPixelBuffer already
    // maps row 0 to the top, matching the pixel buffer's orientation, so no
    // extra vertical flip is needed (flipping here would upend the video).
    let drawRect = fitRect(
      imageWidth: image.width, imageHeight: image.height,
      targetWidth: width, targetHeight: height, fit: fit)
    context.draw(image, in: drawRect)

    return pixelBuffer
  }

  /// Computes the destination rect (top-left origin) for the given fit mode.
  private static func fitRect(
    imageWidth: Int, imageHeight: Int, targetWidth: Int, targetHeight: Int, fit: String
  ) -> CGRect {
    let iw = CGFloat(imageWidth)
    let ih = CGFloat(imageHeight)
    let tw = CGFloat(targetWidth)
    let th = CGFloat(targetHeight)

    switch fit {
    case "stretch":
      return CGRect(x: 0, y: 0, width: tw, height: th)
    case "cover":
      let scale = max(tw / iw, th / ih)
      let w = iw * scale
      let h = ih * scale
      return CGRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
    default:  // "contain"
      let scale = min(tw / iw, th / ih)
      let w = iw * scale
      let h = ih * scale
      return CGRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
    }
  }
}
