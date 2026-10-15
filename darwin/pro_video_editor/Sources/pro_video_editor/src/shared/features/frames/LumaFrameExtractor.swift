import AVFoundation
import Accelerate
import CoreVideo
import Foundation

/// Decodes a range of a video in one forward pass and delivers every frame
/// as a small upright 8-bit luma image with its source timestamp.
///
/// Built for motion analysis: the decoder's own Y plane is scaled and turned
/// upright with vImage, so no RGB conversion or image encoding is involved.
enum LumaFrameExtractor {

  /// Streams the frames of `config`'s range.
  ///
  /// `onFrame` is invoked in decode order with the frame's presentation time
  /// in microseconds, its size and its row-major luma bytes. `onComplete`
  /// fires after the last frame; `onError` fires instead on failure or when
  /// the job is cancelled through the returned handle (with a
  /// `CancellationError`).
  static func streamFrames(
    config: FrameStreamConfig,
    onFrame: @escaping (
      _ ptsUs: Int64, _ width: Int, _ height: Int, _ luma: Data, _ progress: Double
    ) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void
  ) -> ThumbnailJobHandle {
    let task = Task {
      do {
        try await extract(config: config, onFrame: onFrame)
        try Task.checkCancellation()
        onComplete()
      } catch {
        onError(error)
      }
    }
    return ThumbnailJobHandle(cancel: { task.cancel() })
  }

  private static func extract(
    config: FrameStreamConfig,
    onFrame: (Int64, Int, Int, Data, Double) -> Void
  ) async throws {
    guard FileManager.default.fileExists(atPath: config.inputPath) else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 404,
        userInfo: [
          NSLocalizedDescriptionKey: "Video file not found at path: \(config.inputPath)"
        ])
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: config.inputPath))
    let track = try await loadVideoTrack(from: asset)
    let durationUs = Int64(CMTimeGetSeconds(asset.duration) * 1_000_000)
    // A track that opens with an empty edit shows nothing of its own there;
    // AVAssetReader still hands out a frame for it, which is not a frame of
    // the file.
    let firstMediaUs = leadingEmptyEditEndUs(of: track)
    let startUs = max(firstMediaUs, config.startUs ?? 0)
    let endUs = min(config.endUs ?? durationUs, durationUs)
    guard endUs > startUs else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 400,
        userInfo: [NSLocalizedDescriptionKey: "The frame range is empty"])
    }

    let orientation = Orientation(track.preferredTransform)
    let natural = track.naturalSize
    let displayWidth = orientation.swapsAxes ? natural.height : natural.width
    let displayHeight = orientation.swapsAxes ? natural.width : natural.height
    let fit = min(
      Double(config.outputWidth) / Double(displayWidth),
      Double(config.outputHeight) / Double(displayHeight))
    let outWidth = max(1, Int(Double(displayWidth) * fit))
    let outHeight = max(1, Int(Double(displayHeight) * fit))
    // Scaled in the decoder's orientation, then turned upright.
    let scaledWidth = orientation.swapsAxes ? outHeight : outWidth
    let scaledHeight = orientation.swapsAxes ? outWidth : outHeight

    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(value: startUs, timescale: 1_000_000),
      end: CMTime(value: endUs, timescale: 1_000_000))
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 500,
        userInfo: [NSLocalizedDescriptionKey: "Cannot read the video track"])
    }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "LumaFrameExtractor", code: 500,
          userInfo: [NSLocalizedDescriptionKey: "Cannot start reading the video"])
    }
    defer {
      if reader.status == .reading { reader.cancelReading() }
    }

    let minSpacingUs: Int64? = config.maxFrameRate.map {
      // A millisecond of slack keeps a 30 fps cap from dropping frames of a
      // 30 fps video whose timestamps jitter.
      Int64(1_000_000 / $0) - 1_000
    }
    var scaled = [UInt8](repeating: 0, count: scaledWidth * scaledHeight)
    var upright = [UInt8](repeating: 0, count: outWidth * outHeight)
    var lastPts: Int64?
    var delivered = 0
    let nominalFrameUs =
      track.nominalFrameRate > 0 ? 1_000_000 / Double(track.nominalFrameRate) : 33_333

    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      let ptsUs = Int64(
        (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
          .rounded())
      guard ptsUs >= startUs, ptsUs < endUs,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
      else { continue }
      if let last = lastPts {
        // A repeated timestamp is no new frame, and the analysis needs them
        // strictly in order.
        if ptsUs <= last { continue }
        if let spacing = minSpacingUs, ptsUs - last < spacing { continue }
      }
      // Decoded samples carry no duration; the spacing to the previous frame
      // stands in for it, so the last frame reports a progress of 1.
      let frameUs = lastPts.map { Double(ptsUs - $0) } ?? nominalFrameUs
      lastPts = ptsUs

      try scaleLuma(pixelBuffer, into: &scaled, width: scaledWidth, height: scaledHeight)
      try orientation.apply(
        scaled, width: scaledWidth, height: scaledHeight, into: &upright)
      delivered += 1
      let progress = min(
        1, (Double(ptsUs) + frameUs - Double(startUs)) / Double(endUs - startUs))
      onFrame(ptsUs, outWidth, outHeight, Data(upright), progress)
    }

    if reader.status == .failed {
      throw reader.error
        ?? NSError(
          domain: "LumaFrameExtractor", code: 500,
          userInfo: [NSLocalizedDescriptionKey: "Reading the video failed"])
    }
    guard delivered > 0 else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 500,
        userInfo: [NSLocalizedDescriptionKey: "No frames could be decoded in the range"])
    }
  }

  /// Scales the Y plane of `pixelBuffer` into `out`.
  private static func scaleLuma(
    _ pixelBuffer: CVPixelBuffer, into out: inout [UInt8], width: Int, height: Int
  ) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 500,
        userInfo: [NSLocalizedDescriptionKey: "Decoded frame has no luma plane"])
    }
    var source = vImage_Buffer(
      data: base,
      height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    let error = out.withUnsafeMutableBytes { raw -> vImage_Error in
      var destination = vImage_Buffer(
        data: raw.baseAddress, height: vImagePixelCount(height),
        width: vImagePixelCount(width), rowBytes: width)
      return vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
    }
    guard error == kvImageNoError else {
      throw NSError(
        domain: "LumaFrameExtractor", code: Int(error),
        userInfo: [NSLocalizedDescriptionKey: "Scaling a frame failed (\(error))"])
    }
  }

  /// Where the track's own media begins when it opens with empty edits, in
  /// microseconds of its timeline; 0 otherwise.
  private static func leadingEmptyEditEndUs(of track: AVAssetTrack) -> Int64 {
    var endUs: Int64 = 0
    for segment in track.segments {
      guard segment.isEmpty else { break }
      endUs = Int64(CMTimeGetSeconds(CMTimeRangeGetEnd(segment.timeMapping.target)) * 1_000_000)
    }
    return endUs
  }

  private static func loadVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
    let track: AVAssetTrack?
    if #available(iOS 15.0, macOS 13.0, *) {
      track = try await asset.loadTracks(withMediaType: .video).first
    } else {
      track = asset.tracks(withMediaType: .video).first
    }
    guard let track else {
      throw NSError(
        domain: "LumaFrameExtractor", code: 404,
        userInfo: [NSLocalizedDescriptionKey: "No video track found"])
    }
    return track
  }

  /// How the decoder's frames are turned to stand upright: an optional
  /// horizontal mirror, then a number of clockwise quarter turns.
  struct Orientation {
    let mirrored: Bool
    let quarterTurns: Int

    init(_ transform: CGAffineTransform) {
      mirrored = transform.a * transform.d - transform.b * transform.c < 0
      // A mirror applied first negates the transform's first column.
      let a = mirrored ? -transform.a : transform.a
      let b = mirrored ? -transform.b : transform.b
      let turns = Int((atan2(Double(b), Double(a)) / (Double.pi / 2)).rounded())
      quarterTurns = ((turns % 4) + 4) % 4
    }

    var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// Writes `source` (`width` × `height`) upright into `out`.
    func apply(_ source: [UInt8], width: Int, height: Int, into out: inout [UInt8]) throws {
      var input = source
      if mirrored {
        var mirroredCopy = source
        let error = input.withUnsafeMutableBytes { src in
          mirroredCopy.withUnsafeMutableBytes { dst in
            var s = vImage_Buffer(
              data: src.baseAddress, height: vImagePixelCount(height),
              width: vImagePixelCount(width), rowBytes: width)
            var d = vImage_Buffer(
              data: dst.baseAddress, height: vImagePixelCount(height),
              width: vImagePixelCount(width), rowBytes: width)
            return vImageHorizontalReflect_Planar8(&s, &d, vImage_Flags(kvImageNoFlags))
          }
        }
        guard error == kvImageNoError else { throw rotateError(error) }
        input = mirroredCopy
      }
      if quarterTurns == 0 {
        out = input
        return
      }
      let outWidth = swapsAxes ? height : width
      let outHeight = swapsAxes ? width : height
      let rotation: UInt8
      switch quarterTurns {
      case 1: rotation = UInt8(kRotate90DegreesClockwise)
      case 2: rotation = UInt8(kRotate180DegreesClockwise)
      default: rotation = UInt8(kRotate270DegreesClockwise)
      }
      let error = input.withUnsafeMutableBytes { src in
        out.withUnsafeMutableBytes { dst in
          var s = vImage_Buffer(
            data: src.baseAddress, height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width)
          var d = vImage_Buffer(
            data: dst.baseAddress, height: vImagePixelCount(outHeight),
            width: vImagePixelCount(outWidth), rowBytes: outWidth)
          return vImageRotate90_Planar8(&s, &d, rotation, 0, vImage_Flags(kvImageNoFlags))
        }
      }
      guard error == kvImageNoError else { throw rotateError(error) }
    }

    private func rotateError(_ error: vImage_Error) -> Error {
      NSError(
        domain: "LumaFrameExtractor", code: Int(error),
        userInfo: [NSLocalizedDescriptionKey: "Turning a frame upright failed (\(error))"])
    }
  }
}
