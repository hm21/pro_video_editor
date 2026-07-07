import AVFoundation
import Foundation

/// Renders a composition through AVAssetReader → AVAssetWriter so the
/// requested video bitrate is actually enforced.
///
/// `AVAssetExportSession` presets pick their own bitrate (a 1080p preset
/// encodes at 10-16 Mbit/s regardless of the request), so a bitrate cap can
/// only be honored by writing the video track ourselves with
/// `AVVideoAverageBitRateKey` — the same pattern `StopMotionGenerator` uses.
///
/// The reader consumes the composed frames via
/// `AVAssetReaderVideoCompositionOutput`, so the full `AVVideoComposition`
/// (custom compositor with filters/blur/layers/transitions, frame-rate cap,
/// render size) and the `AVAudioMix` (track volumes/fades) behave exactly as
/// they do in the export-session path.
internal enum BitrateCappedExporter {

  /// Thread-safe cancellation flag shared between the task-cancellation
  /// handler and the sample pump queues.
  private final class CancelState {
    private let lock = NSLock()
    private var canceled = false

    func cancel() {
      lock.lock()
      canceled = true
      lock.unlock()
    }

    var isCanceled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return canceled
    }
  }

  /// Exports [asset] to [outputURL], encoding video as H.264 with
  /// `AVVideoAverageBitRateKey` set to [videoBitrate] and audio as AAC.
  ///
  /// - Parameters:
  ///   - asset: The (composed) asset to render.
  ///   - videoComposition: Video composition applied while reading frames.
  ///   - audioMix: Optional audio mix applied while reading audio.
  ///   - outputURL: Destination file (replaced if it exists).
  ///   - fileType: Output container type (.mp4 / .mov).
  ///   - videoBitrate: Target average video bitrate in bits per second.
  ///   - timeRange: Optional global trim range, in asset time.
  ///   - optimizeForNetworkUse: Writes the moov atom at the front when true.
  ///   - onProgress: Called with progress in 0.0...0.99 while encoding.
  ///
  /// Cancellation: responds to task cancellation (the render job handle
  /// cancels the surrounding task); the partial output file is removed.
  static func export(
    asset: AVAsset,
    videoComposition: AVVideoComposition,
    audioMix: AVAudioMix?,
    outputURL: URL,
    fileType: AVFileType,
    videoBitrate: Int,
    timeRange: CMTimeRange?,
    optimizeForNetworkUse: Bool,
    onProgress: @escaping (Double) -> Void
  ) async throws {
    let videoTracks = try await loadTracks(from: asset, mediaType: .video)
    guard !videoTracks.isEmpty else {
      throw error(1, "No video tracks to export")
    }
    let audioTracks = try await loadTracks(from: asset, mediaType: .audio)

    // The writer refuses to overwrite an existing file.
    try? FileManager.default.removeItem(at: outputURL)

    // Reader: composed video frames + mixed audio.
    let reader = try AVAssetReader(asset: asset)
    if let timeRange = timeRange {
      reader.timeRange = timeRange
    }

    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: videoTracks,
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    videoOutput.videoComposition = videoComposition
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      throw error(2, "Cannot add video composition output to reader")
    }
    reader.add(videoOutput)

    var audioOutput: AVAssetReaderAudioMixOutput?
    if !audioTracks.isEmpty {
      let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
      output.audioMix = audioMix
      output.alwaysCopiesSampleData = false
      if reader.canAdd(output) {
        reader.add(output)
        audioOutput = output
      } else {
        PluginLog.print("⚠️ Cannot add audio mix output to reader - exporting video only")
      }
    }

    // Writer: H.264 at the requested bitrate, AAC audio.
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    writer.shouldOptimizeForNetworkUse = optimizeForNetworkUse

    let width = evenDimension(videoComposition.renderSize.width)
    let height = evenDimension(videoComposition.renderSize.height)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: videoBitrate
      ],
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else {
      throw error(3, "Cannot add video input to writer")
    }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if audioOutput != nil {
      let settings = await audioSettings(for: audioTracks.first)
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = false
      if writer.canAdd(input) {
        writer.add(input)
        audioInput = input
      } else {
        PluginLog.print("⚠️ Cannot add audio input to writer - exporting video only")
        audioOutput = nil
      }
    }

    // Progress is derived from the video PTS against the exported duration.
    let assetDuration: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      assetDuration = try await asset.load(.duration)
    } else {
      assetDuration = asset.duration
    }
    let exportStart = timeRange?.start ?? .zero
    let totalSeconds = CMTimeGetSeconds(timeRange?.duration ?? assetDuration)

    guard reader.startReading() else {
      throw reader.error ?? error(4, "AVAssetReader.startReading failed")
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      throw writer.error ?? error(5, "AVAssetWriter.startWriting failed")
    }
    writer.startSession(atSourceTime: exportStart)

    let cancelState = CancelState()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let group = DispatchGroup()

        pump(
          input: videoInput, output: videoOutput, group: group,
          queue: DispatchQueue(label: "ch.waio.pro_video_editor.bitrate_export.video"),
          cancelState: cancelState
        ) { sample in
          guard totalSeconds > 0 else { return }
          let pts = CMSampleBufferGetPresentationTimeStamp(sample)
          let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, exportStart))
          // Reserve 1.0 for after finishWriting, like the export-session path.
          onProgress(min(max(seconds / totalSeconds, 0), 0.99))
        }

        if let audioInput = audioInput, let audioOutput = audioOutput {
          pump(
            input: audioInput, output: audioOutput, group: group,
            queue: DispatchQueue(label: "ch.waio.pro_video_editor.bitrate_export.audio"),
            cancelState: cancelState,
            onSample: nil)
        }

        group.notify(queue: DispatchQueue(label: "ch.waio.pro_video_editor.bitrate_export.done")) {
          if cancelState.isCanceled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            cont.resume(throwing: CancellationError())
            return
          }
          if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            cont.resume(throwing: reader.error ?? error(6, "Reading composed frames failed"))
            return
          }
          if writer.status == .failed {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            cont.resume(throwing: writer.error ?? error(7, "Writing encoded samples failed"))
            return
          }
          writer.finishWriting {
            if writer.status == .completed {
              cont.resume()
            } else {
              try? FileManager.default.removeItem(at: outputURL)
              cont.resume(
                throwing: writer.error
                  ?? error(8, "Writer finished with status \(writer.status.rawValue)"))
            }
          }
        }
      }
    } onCancel: {
      cancelState.cancel()
      // Unblocks the pumps: copyNextSampleBuffer returns nil after cancel.
      reader.cancelReading()
    }
  }

  // MARK: - Sample pumping

  /// Copies samples from [output] into [input] on [queue] until the source is
  /// drained, an append fails, or the export is canceled. Calls
  /// `group.leave()` exactly once when this track is done.
  private static func pump(
    input: AVAssetWriterInput,
    output: AVAssetReaderOutput,
    group: DispatchGroup,
    queue: DispatchQueue,
    cancelState: CancelState,
    onSample: ((CMSampleBuffer) -> Void)?
  ) {
    group.enter()
    var finished = false  // Confined to [queue]; guards double-leave.
    input.requestMediaDataWhenReady(on: queue) {
      while input.isReadyForMoreMediaData {
        if finished { return }
        if cancelState.isCanceled {
          finished = true
          input.markAsFinished()
          group.leave()
          return
        }
        guard let sample = output.copyNextSampleBuffer() else {
          finished = true
          input.markAsFinished()
          group.leave()
          return
        }
        if !input.append(sample) {
          // Writer moved to .failed; surface the error after both pumps stop.
          finished = true
          input.markAsFinished()
          group.leave()
          return
        }
        onSample?(sample)
      }
    }
  }

  // MARK: - Helpers

  private static func loadTracks(
    from asset: AVAsset, mediaType: AVMediaType
  ) async throws -> [AVAssetTrack] {
    if #available(iOS 15.0, macOS 13.0, *) {
      return try await asset.loadTracks(withMediaType: mediaType)
    } else {
      return asset.tracks(withMediaType: mediaType)
    }
  }

  /// AAC output settings derived from the source track where possible.
  private static func audioSettings(for track: AVAssetTrack?) async -> [String: Any] {
    var sampleRate = 44_100.0
    var channels = 2

    if let track = track {
      let formatDescriptions: [Any]
      if #available(iOS 15.0, macOS 13.0, *) {
        formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
      } else {
        formatDescriptions = track.formatDescriptions
      }
      for description in formatDescriptions {
        let formatDesc = description as! CMFormatDescription
        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
          if basic.pointee.mSampleRate > 0 {
            sampleRate = basic.pointee.mSampleRate
          }
          if basic.pointee.mChannelsPerFrame > 0 {
            channels = Int(basic.pointee.mChannelsPerFrame)
          }
          break
        }
      }
    }

    // Clamp to what the AAC encoder accepts; stereo is enough for this
    // pipeline (matching the mixed output of the export-session path).
    let aacSampleRate = sampleRate > 48_000 ? 48_000.0 : sampleRate
    let aacChannels = min(max(channels, 1), 2)

    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: aacSampleRate,
      AVNumberOfChannelsKey: aacChannels,
      AVEncoderBitRateKey: 128_000,
    ]
  }

  /// Rounds a render dimension to the nearest even integer (H.264
  /// requirement), with a minimum of 2.
  private static func evenDimension(_ value: CGFloat) -> Int {
    let rounded = Int(value.rounded())
    return max(2, rounded - (rounded % 2))
  }

  private static func error(_ code: Int, _ message: String) -> NSError {
    return NSError(
      domain: "BitrateCappedExporter", code: code,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
