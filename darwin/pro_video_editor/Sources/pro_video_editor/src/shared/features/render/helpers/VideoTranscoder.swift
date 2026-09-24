import AVFoundation
import CoreImage
import Foundation

/// Utility for pre-transcoding HEVC 10-bit HDR videos to H.264 8-bit SDR.
///
/// This is necessary because GPU-based effect pipelines have compatibility
/// issues with HEVC Main 10 Profile videos. By transcoding to H.264 first,
/// we can then safely apply effects like ColorMatrix, Blur, or Overlay.
internal class VideoTranscoder {

  // MARK: - Result Types

  /// Result of a transcoding operation.
  enum TranscodeResult {
    /// Transcoding succeeded. `trimmed` describes an output that holds only
    /// part of the source: the window the clip plays and its cadence; `nil`
    /// after a whole-source transcode, whose timeline and frame rate match
    /// the source's.
    case success(outputPath: String, trimmed: Trimmed?)

    /// Transcoding failed with error
    case error(Error)
  }

  /// How a clip plays a transcode of only part of its source.
  struct Trimmed {
    /// The span of the output the clip plays (see
    /// ``clipWindow(playing:writtenTrack:)``).
    let window: SourceRange

    /// The cadence measured from the output's frames, which the render uses
    /// instead of its `nominalFrameRate` (see ``VideoClip/frameRateOverride``).
    /// The source's own rate where the frames cannot be read or are too few
    /// to measure; `nil` when that cannot be read either.
    let frameRate: Float?
  }

  /// What the pre-transcode hands to the render.
  struct PreTranscode {
    /// The clips to render, each pointing at the file and window it now plays.
    let clips: [VideoClip]

    /// Every file this pass wrote, once each; the caller removes them.
    let producedFiles: [String]
  }

  /// A span of a source in microseconds, `startUs` inclusive, `endUs`
  /// exclusive.
  struct SourceRange: Hashable {
    let startUs: Int64
    let endUs: Int64

    var durationUs: Int64 { endUs - startUs }
  }

  /// One pre-transcode: a source and the range of it to encode, `nil` for all
  /// of it. Clips that resolve to the same key share one output file.
  struct TranscodeKey: Hashable {
    let path: String
    let range: SourceRange?
  }

  // MARK: - Clip windows

  /// The share of a source that the clips playing it must stay under for the
  /// pre-transcode to encode only their windows. At or above it the whole
  /// source is encoded, as before windows were considered: trimming would save
  /// little, and several clips that together cover the source share one
  /// transcode instead of re-encoding it piecewise.
  static let trimThreshold = 0.9

  /// How far past a clip window the trimmed pre-transcode encodes, as far as
  /// the source runs.
  ///
  /// A trimmed export ends its audio track tens of milliseconds before its
  /// video even where the source has sound (42 ms for 1–3 s of `hevc.mp4`).
  /// `trimToCommonTrackEnd` reads that as a track-end mismatch and cuts it off
  /// the clip, frames included, which a window inside the source never lost
  /// on the whole-source transcode. Encoding past the window leaves that
  /// shortfall behind it. As long as ``TrackEndTrimmer/maxTrackEndMismatch``,
  /// so no shortfall the trim would act on reaches into the window.
  static let windowTailUs = CMTimeConvertScale(
    TrackEndTrimmer.maxTrackEndMismatch, timescale: 1_000_000, method: .default
  ).value

  /// The range of the source each clip window needs encoded, or `nil` for the
  /// whole source; parallel to `windows`.
  ///
  /// `windows` are the `(startUs, endUs)` of every clip that plays one source,
  /// where a `nil` bound runs to the source's start or end. Each clip gets its
  /// own window only when the distinct windows together stay under
  /// ``trimThreshold`` of `sourceDurationUs`; otherwise all of them fall back
  /// to the whole source. So does every clip of a source whose duration is
  /// unknown or one of whose windows holds no part of it — the render then
  /// sees the same files and windows it saw before.
  static func plannedRanges(
    for windows: [(startUs: Int64?, endUs: Int64?)], sourceDurationUs: Int64
  ) -> [SourceRange?] {
    let whole = [SourceRange?](repeating: nil, count: windows.count)
    guard sourceDurationUs > 0 else { return whole }

    var ranges: [SourceRange] = []
    for window in windows {
      let start = max(0, window.startUs ?? 0)
      let end = min(sourceDurationUs, window.endUs ?? sourceDurationUs)
      guard end > start else { return whole }
      ranges.append(SourceRange(startUs: start, endUs: end))
    }

    let encodedUs = Set(ranges).reduce(Int64(0)) { $0 + $1.durationUs }
    guard Double(encodedUs) < trimThreshold * Double(sourceDurationUs) else { return whole }
    return ranges
  }

  /// The clip window that plays all of `trackRange`, in microseconds.
  ///
  /// Rounded outwards: the render intersects a clip window with the track's
  /// own range, so a window a fraction of a microsecond too wide lands exactly
  /// on the track, while one too narrow would cut its last frame short.
  static func window(covering trackRange: CMTimeRange) -> SourceRange {
    let start = CMTimeConvertScale(
      trackRange.start, timescale: 1_000_000, method: .roundTowardNegativeInfinity)
    let end = CMTimeConvertScale(
      CMTimeRangeGetEnd(trackRange), timescale: 1_000_000,
      method: .roundTowardPositiveInfinity)
    return SourceRange(startUs: start.value, endUs: end.value)
  }

  /// The part of the source encoded for `window`: the window and up to
  /// ``windowTailUs`` after it, as far as the source runs.
  static func encodedRange(for window: SourceRange, sourceDurationUs: Int64) -> SourceRange {
    SourceRange(
      startUs: window.startUs,
      endUs: max(window.endUs, min(sourceDurationUs, window.endUs + windowTailUs)))
  }

  /// The clip window on the trimmed pre-transcode of `window`, whose video
  /// track spans `trackRange`.
  ///
  /// The output starts where `window` does, so the clip plays the window's
  /// length of it and stops before the encoded tail. Where the written track
  /// ends sooner, at the end of the source, which has no tail to encode, the
  /// window ends with the track: rounded outwards (see
  /// ``window(covering:)``), since the render cuts the clip hard at it.
  static func clipWindow(playing window: SourceRange, writtenTrack trackRange: CMTimeRange)
    -> SourceRange
  {
    let track = self.window(covering: trackRange)
    return SourceRange(startUs: track.startUs, endUs: min(window.durationUs, track.endUs))
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

  /// Transcodes a video, or `range` of it, to H.264 8-bit SDR format for
  /// effect compatibility.
  ///
  /// Uses HDR → SDR tonemapping to convert 10-bit HDR to 8-bit SDR,
  /// which allows proper GPU effect processing.
  ///
  /// - Parameters:
  ///   - videoPath: Path to the input video
  ///   - range: The part of the source the clip plays; `nil` encodes all of
  ///     it. A tail after it is encoded too (see ``windowTailUs``).
  ///   - sourceDurationUs: The source's duration, which bounds that tail
  /// - Returns: TranscodeResult indicating success or error
  static func transcodeToH264(
    _ videoPath: String, range: SourceRange? = nil, sourceDurationUs: Int64 = 0
  ) async -> TranscodeResult {
    let encoded = range.map { encodedRange(for: $0, sourceDurationUs: sourceDurationUs) }
    let span = encoded.map { " [\($0.startUs)µs, \($0.endUs)µs)" } ?? ""
    PluginLog.print(
      "🎬 Starting HEVC 10-bit HDR → H.264 8-bit SDR transcoding for: \(videoPath)\(span)")

    let inputURL = URL(fileURLWithPath: videoPath)
    // A random suffix on top of the timestamp: concurrent renders pick their
    // names before the gate serializes their encodes, and two that land in
    // the same millisecond would otherwise share one — the second export then
    // fails on the existing file and the clip renders from the HDR source.
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transcoded_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).mp4")

    do {
      try await transcodeVideo(from: inputURL, to: outputURL, range: encoded)

      // Verify output
      let outputInfo = await MediaInfoExtractor.getVideoFormatInfo(outputURL.path)
      PluginLog.print("✅ Transcoding completed: \(outputURL.path)")
      PluginLog.print(
        "   Output: isHevc=\(outputInfo.isHevc), bitDepth=\(outputInfo.bitDepth), isHdr=\(outputInfo.isHdr)"
      )

      guard let range else { return .success(outputPath: outputURL.path, trimmed: nil) }
      let asset = AVURLAsset(url: outputURL)
      let track = try await MediaInfoExtractor.loadVideoTrack(from: asset)
      let window = clipWindow(
        playing: range, writtenTrack: await TrackEndTrimmer.timeRange(of: track))
      // An empty window would drop the clip from the render without a word;
      // failing here keeps it on the source instead.
      guard window.durationUs > 0 else {
        throw NSError(
          domain: "VideoTranscoder", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Trimmed transcode holds no video"])
      }
      // The render times the clip's frames by its rate, which this shorter
      // file's `nominalFrameRate` misreads; measure it from the frames. Where
      // that fails, the source's rate is still closer than this file's: the
      // pre-transcode keeps the source's frame timing.
      var frameRate = typicalFrameRate(of: track, in: asset)
      if frameRate == nil {
        frameRate = await nominalFrameRate(of: inputURL)
      }
      let fps = frameRate.map { "\($0)" } ?? "?"
      PluginLog.print("   Window: [\(window.startUs)µs, \(window.endUs)µs) at \(fps) fps")
      return .success(
        outputPath: outputURL.path, trimmed: Trimmed(window: window, frameRate: frameRate))

    } catch {
      PluginLog.print("❌ Transcoding failed: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: outputURL)
      return .error(error)
    }
  }

  /// Transcodes the clips whose source needs it and points them at the result.
  ///
  /// Each source is checked once. When its clips play only a small part of it
  /// (see ``plannedRanges(for:sourceDurationUs:)``), each distinct window is
  /// encoded on its own and its clips are rewritten to play it from the
  /// output's start; otherwise the source is encoded in full, once, and its
  /// clips keep their windows.
  ///
  /// A clip that cannot be transcoded keeps its original path: the render then
  /// runs on the HDR source, which is worse than a transcode but better than no
  /// render at all. Two failures must not degrade that way and throw instead,
  /// after removing the files already written: a *cancelled* job, which would
  /// build the whole composition on exactly the source the pre-transcode
  /// exists to avoid, only to be thrown away; and a *stalled* encode
  /// (``SetupStageExport/isStall(_:)``), which says the encoder is starved or
  /// wedged, not that the clip is untranscodable — rendering the HDR source
  /// through the compositor on that encoder would produce a wrong or equally
  /// stalled result the caller would then keep.
  ///
  /// - Parameter clips: The clips to render
  /// - Returns: The clips rewritten onto their transcoded files, and those files
  /// - Throws: `CancellationError` if the job was cancelled mid-transcode, or
  ///   the watchdog's error if a transcode stalled.
  static func transcodeClipsIfNeeded(_ clips: [VideoClip]) async throws -> PreTranscode {
    var rewritten = clips
    var produced: [String] = []
    var outputs: [TranscodeKey: (path: String, trimmed: Trimmed?)] = [:]
    // Keys whose transcode failed; their clips stay on the source.
    var failed: Set<TranscodeKey> = []

    var paths: [String] = []
    for clip in clips where !paths.contains(clip.inputPath) {
      paths.append(clip.inputPath)
    }

    for path in paths {
      guard await needsTranscoding(path) else {
        PluginLog.print("✅ No transcoding needed for: \(path)")
        continue
      }
      let indices = clips.indices.filter { clips[$0].inputPath == path }
      let sourceDurationUs = await durationUs(of: path)
      let ranges = plannedRanges(
        for: indices.map { (clips[$0].startUs, clips[$0].endUs) },
        sourceDurationUs: sourceDurationUs)

      for (index, range) in zip(indices, ranges) {
        let key = TranscodeKey(path: path, range: range)
        // A source window that several clips share is transcoded once: a
        // second pass would re-encode the same range and leave one of the two
        // outputs with nothing to clean it up.
        if outputs[key] == nil, !failed.contains(key) {
          switch await transcodeToH264(path, range: range, sourceDurationUs: sourceDurationUs) {
          case .success(let outputPath, let trimmed):
            outputs[key] = (outputPath, trimmed)
            produced.append(outputPath)
          case .error(let error):
            if error is CancellationError || Task.isCancelled {
              cleanupTranscodedFiles(produced)
              throw CancellationError()
            }
            if SetupStageExport.isStall(error) {
              cleanupTranscodedFiles(produced)
              throw error
            }
            PluginLog.print("⚠️ Transcoding failed for \(path), using original")
            failed.insert(key)
          }
        }

        guard let output = outputs[key] else { continue }
        let clip = clips[index]
        if let trimmed = output.trimmed {
          rewritten[index] = clip.reading(
            output.path, startUs: trimmed.window.startUs, endUs: trimmed.window.endUs,
            frameRateOverride: trimmed.frameRate)
        } else {
          rewritten[index] = clip.reading(
            output.path, startUs: clip.startUs, endUs: clip.endUs)
        }
      }
    }

    return PreTranscode(clips: rewritten, producedFiles: produced)
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

  /// How many frames ``typicalFrameRate(of:in:)`` reads at most: enough to
  /// pin the rate down on a coarse timescale, and a window of a long source
  /// is not read in full just to time it.
  static let maxTimedFrames = 300

  /// The frame rate `track` actually runs at, measured from its frames (see
  /// ``typicalFrameRate(ofFrameDurations:)``); `nil` when they cannot be
  /// read or are too few to tell.
  ///
  /// `nominalFrameRate` averages over the whole track, which a short trimmed
  /// file misreads: a sliver of a frame at its start, or a partial one at its
  /// end, counts as a whole frame (0.4 s of 30 fps footage reads 33.3).
  static func typicalFrameRate(of track: AVAssetTrack, in asset: AVAsset) -> Float? {
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }
    defer { reader.cancelReading() }

    var frames: [CMSampleTimingInfo] = []
    while frames.count < maxTimedFrames, let sample = output.copyNextSampleBuffer() {
      for index in 0..<CMSampleBufferGetNumSamples(sample) {
        var timing = CMSampleTimingInfo()
        if CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr,
          timing.presentationTimeStamp.isNumeric
        {
          frames.append(timing)
        }
      }
    }
    // Decode order differs from presentation order around B-frames, and only
    // the first and last *shown* frame can be cut short.
    frames.sort { CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0 }
    return typicalFrameRate(ofFrameDurations: frames.map(\.duration))
  }

  /// The frame rate of frames lasting `durations`, in presentation order.
  ///
  /// Only the first and the last frame of a trimmed file can be cut short: a
  /// sliver of the frame before the window, and the one the file ends in. The
  /// rate comes from the frames between them, from those within 5 % of their
  /// median duration: that leaves out the gap of a dropped frame in
  /// variable-rate footage, and averaging them undoes a timescale too coarse
  /// for the cadence, which rounds each frame to a neighbouring tick (16 or
  /// 17 ms for 60 fps on a 1000 timescale, whose median alone reads 58.8).
  ///
  /// A rate within 0.01 of a whole number, or as close as rounding the frames
  /// to ticks can explain, is taken as that number, since the render cuts it
  /// down to whole frames per second and 59.99999 would become 59. 59.94
  /// stays 59.94 on a timescale that tells the two apart. `nil` without a
  /// whole frame to time, or when the frames are too few for their ticks to
  /// tell neighbouring whole rates apart.
  static func typicalFrameRate(ofFrameDurations durations: [CMTime]) -> Float? {
    guard durations.count > 2 else { return nil }
    let wholeFrames = durations.dropFirst().dropLast().filter { $0.isNumeric && $0 > .zero }
    guard let timescale = wholeFrames.map(\.timescale).max(), timescale > 0 else { return nil }

    // In ticks, where the rounding happened; one track shares one timescale.
    let ticks = wholeFrames.map {
      CMTimeConvertScale($0, timescale: timescale, method: .roundHalfAwayFromZero).value
    }.sorted()
    let median = ticks[ticks.count / 2]
    let typical = ticks.filter { abs($0 - median) <= max(1, median / 20) }
    let span = typical.reduce(0.0) { $0 + Double($1) }
    guard span > 0 else { return nil }
    let rate = Double(typical.count) * Double(timescale) / span
    // Rounding every frame to a tick moves the sum of a run of them by less
    // than one tick.
    let uncertainty = max(0.01, rate / span)
    guard rate.isFinite, uncertainty < 0.5 else { return nil }
    let wholeRate = rate.rounded()
    return Float(abs(rate - wholeRate) < uncertainty ? wholeRate : rate)
  }

  /// The `nominalFrameRate` of the video at `url`, snapped to a whole number
  /// within 0.01 like a measured one; `nil` when it cannot be read.
  private static func nominalFrameRate(of url: URL) async -> Float? {
    guard
      let track = try? await MediaInfoExtractor.loadVideoTrack(from: AVURLAsset(url: url))
    else { return nil }
    let rate: Float
    if #available(iOS 15.0, macOS 13.0, *) {
      rate = (try? await track.load(.nominalFrameRate)) ?? 0
    } else {
      rate = track.nominalFrameRate
    }
    guard rate.isFinite, rate > 0 else { return nil }
    let wholeRate = rate.rounded()
    return abs(rate - wholeRate) < 0.01 ? wholeRate : rate
  }

  /// The source's duration in microseconds, or 0 when it cannot be read.
  private static func durationUs(of path: String) async -> Int64 {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      duration = (try? await asset.load(.duration)) ?? .zero
    } else {
      duration = asset.duration
    }
    guard duration.isNumeric else { return 0 }
    return CMTimeConvertScale(duration, timescale: 1_000_000, method: .roundHalfAwayFromZero)
      .value
  }

  /// Performs the actual video transcoding using AVAssetExportSession.
  /// This is simpler and more reliable than AVAssetWriter for basic transcoding.
  ///
  /// `range` limits the encode to that part of the source, video and audio
  /// alike; the output's time zero is the range's start.
  private static func transcodeVideo(
    from inputURL: URL, to outputURL: URL, range: SourceRange?
  ) async throws {
    let asset = AVURLAsset(
      url: inputURL,
      options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: true
      ])

    guard
      let exportSession = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetHighestQuality)
    else {
      throw NSError(
        domain: "VideoTranscoder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
    }

    exportSession.shouldOptimizeForNetworkUse = true
    if let range {
      exportSession.timeRange = CMTimeRange(
        start: CMTime(value: range.startUs, timescale: 1_000_000),
        end: CMTime(value: range.endUs, timescale: 1_000_000))
    }

    // Create video composition for HDR → SDR conversion
    let videoTrack: AVAssetTrack

    if #available(iOS 15.0, macOS 13.0, *) {
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let vTrack = videoTracks.first else {
        throw NSError(
          domain: "VideoTranscoder", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"]
        )
      }
      videoTrack = vTrack
    } else {
      guard let vTrack = asset.tracks(withMediaType: .video).first else {
        throw NSError(
          domain: "VideoTranscoder", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "No video track found"]
        )
      }
      videoTrack = vTrack
    }

    // Get video properties
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float

    if #available(iOS 15.0, macOS 13.0, *) {
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

    let processImage: (CIImage) -> CIImage = { sourceImage in
      var image = sourceImage.clampedToExtent()

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

      return image.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    if #available(iOS 26.0, macOS 26.0, *) {
      let videoComposition = try await AVVideoComposition(applyingFiltersTo: asset) {
        params in
        let cropped = processImage(params.sourceImage)
        return AVCIImageFilteringResult(resultImage: cropped, ciContext: nil)
      }
      exportSession.videoComposition = videoComposition

    } else {
      // Fallback block for older OS versions
      let videoComposition = AVMutableVideoComposition(asset: asset) { request in
        let cropped = processImage(request.sourceImage)
        request.finish(with: cropped, context: nil)
      }

      videoComposition.renderSize = renderSize
      videoComposition.frameDuration = CMTime(
        value: 1, timescale: CMTimeScale(nominalFrameRate))

      #if os(iOS)
        if #available(iOS 14.0, *) {
          videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
          videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
          videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
      #else  // macOS branch
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
      #endif

      exportSession.videoComposition = videoComposition
    }

    PluginLog.print("🎬 Transcoding with AVAssetExportSession...")
    PluginLog.print("   Input size: \(naturalSize), Output size: \(renderSize)")

    // A whole-clip re-encode: gated against every other encode in the process
    // and bounded by the stall watchdog like the main render (#201).
    try await SetupStageExport.run(
      exportSession, to: outputURL, as: .mp4,
      diagnostics: TranscodeExportDiagnostics(input: inputURL.lastPathComponent),
      label: "Transcode", failureDomain: "VideoTranscoder")

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

  /// Calculates appropriate bitrate based on resolution and frame rate (Mac optimization legacy).
  private static func calculateBitrate(size: CGSize, frameRate: Float) -> Int {
    let pixels = Int(size.width * size.height)
    let fps = max(24, min(60, Int(frameRate)))

    // Roughly 0.1 bits per pixel per frame for H.264 High profile
    return max(2_000_000, pixels * fps / 10)
  }
}

/// Diagnostic context for the HDR pre-transcode, mirroring
/// ``RenderExportDiagnostics`` so a stall surfaces the same shape of message
/// as one on the main encode.
struct TranscodeExportDiagnostics: ExportDiagnostics {
  /// File name of the clip being transcoded.
  let input: String

  /// e.g. `[progress=0.00 input=IMG_0042.MOV]`
  func context(progress: Double) -> String {
    String(format: "[progress=%.2f input=%@]", progress, input)
  }

  func timeoutMessage(seconds: Int, progress: Double) -> String {
    "Transcode export timed out after \(seconds)s \(context(progress: progress))"
  }

  func stallMessage(seconds: Int, progress: Double) -> String {
    "Transcode export stalled after \(seconds)s with no progress \(context(progress: progress))"
  }
}
