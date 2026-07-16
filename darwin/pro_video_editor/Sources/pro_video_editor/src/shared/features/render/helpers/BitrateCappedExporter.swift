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

  /// Completes a `CheckedContinuation` exactly once, from whichever of the
  /// normal completion path (`group.notify`) or the cancellation handler fires
  /// first.
  ///
  /// The cancellation handler needs this because a writer-input pump parked on a
  /// wedged encoder never calls `group.leave()`, so `group.notify` would never
  /// fire and the task would hang forever — holding the process-wide export
  /// gate. Resuming from `onCancel` unwinds it instead.
  private final class ContinuationTerminator {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?
    private var finished = false

    /// Registers the continuation. If [finish] already ran (the task was
    /// cancelled before the continuation body executed), resumes it at once.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
      lock.lock()
      if finished, let pending = pending {
        self.pending = nil
        lock.unlock()
        continuation.resume(with: pending)
      } else {
        cont = continuation
        lock.unlock()
      }
    }

    /// Resumes the continuation once; later calls are ignored. Returns `true`
    /// only for the call that actually completed it, so the winner can own any
    /// side effects (e.g. deleting the partial output) without a late cancel
    /// clobbering an already-succeeded export.
    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
      lock.lock()
      if finished {
        lock.unlock()
        return false
      }
      finished = true
      let continuation = cont
      cont = nil
      if continuation == nil { pending = result }
      lock.unlock()
      continuation?.resume(with: result)
      return true
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
        AVVideoAverageBitRateKey: videoBitrate,
        // Disable B-frames. Frame reordering forces a composition-time offset
        // (ctts / an edit list) and a decoder reorder buffer that must be
        // flushed and refilled at every loop restart. On short looped clips
        // that refill intermittently starves AVPlayerItemVideoOutput — the
        // player delivers no frame for a whole loop while audio keeps playing.
        // An all-P-frame stream decodes linearly and loops cleanly.
        AVVideoAllowFrameReorderingKey: false,
        // Keep keyframes frequent so a loop seek to zero (and any scrub) lands
        // on or near an IDR instead of decoding a long GOP first.
        AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
      ],
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else {
      throw error(3, "Cannot add video input to writer")
    }
    writer.add(videoInput)

    // Audio: read the mixed tracks as interleaved LPCM downmixed to at most
    // stereo (an explicit channel layout makes the reader downmix >2-channel
    // surround sources deterministically), then re-encode to AAC. The reader
    // output and writer input are only added once BOTH are confirmed, so a
    // rejected writer input never leaves an undrained output on the reader.
    var audioOutput: AVAssetReaderAudioMixOutput?
    var audioInput: AVAssetWriterInput?
    if !audioTracks.isEmpty {
      let format = await audioFormat(for: audioTracks.first)
      let output = AVAssetReaderAudioMixOutput(
        audioTracks: audioTracks, audioSettings: readerLPCMSettings(format))
      output.audioMix = audioMix
      output.alwaysCopiesSampleData = false
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: writerAACSettings(format))
      input.expectsMediaDataInRealTime = false
      if reader.canAdd(output) && writer.canAdd(input) {
        reader.add(output)
        writer.add(input)
        audioOutput = output
        audioInput = input
      } else {
        PluginLog.print("⚠️ Cannot wire audio reader/writer - exporting video only")
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
    let terminator = ContinuationTerminator()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        terminator.attach(cont)
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
            terminator.finish(.failure(CancellationError()))
            return
          }
          if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            terminator.finish(.failure(reader.error ?? error(6, "Reading composed frames failed")))
            return
          }
          if writer.status == .failed {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            terminator.finish(.failure(writer.error ?? error(7, "Writing encoded samples failed")))
            return
          }
          writer.finishWriting {
            if writer.status == .completed {
              terminator.finish(.success(()))
            } else {
              try? FileManager.default.removeItem(at: outputURL)
              terminator.finish(
                .failure(
                  writer.error
                    ?? error(8, "Writer finished with status \(writer.status.rawValue)")))
            }
          }
        }
      }
    } onCancel: {
      cancelState.cancel()
      // Unblocks the pumps: copyNextSampleBuffer returns nil after cancel. Also
      // tear down the writer and complete the continuation directly — a pump
      // parked on a wedged encoder (isReadyForMoreMediaData stuck false) is
      // never re-invoked to observe the cancel, so group.notify would never
      // fire and the task would hang holding the export gate. Only delete the
      // output if this cancel actually won the race (the export hadn't already
      // finished successfully).
      reader.cancelReading()
      writer.cancelWriting()
      if terminator.finish(.failure(CancellationError())) {
        try? FileManager.default.removeItem(at: outputURL)
      }
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

  /// The decoded audio format the reader delivers and the writer encodes.
  ///
  /// [channels] is clamped to at most stereo and [sampleRate] to what AAC
  /// accepts. A mono source stays mono; stereo and any surround layout
  /// (5.1, 7.1, …) resolve to stereo, and the reader is given an explicit
  /// channel layout ([readerLPCMSettings]) so it performs the downmix
  /// deterministically instead of leaving multichannel reduction to the AAC
  /// encoder (whose implicit behavior varies by OS version).
  private struct AudioFormat {
    let sampleRate: Double
    let channels: Int
  }

  private static func audioFormat(for track: AVAssetTrack?) async -> AudioFormat {
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

    return AudioFormat(
      sampleRate: sampleRate > 48_000 ? 48_000 : sampleRate,
      channels: min(max(channels, 1), 2))
  }

  /// Interleaved 16-bit LPCM reader settings at [format]. The explicit
  /// channel count plus [channelLayoutData] make `AVAssetReaderAudioMixOutput`
  /// downmix a >2-channel source to the target layout up front, rather than
  /// vending the source channel count and leaving the downmix to the AAC
  /// encoder.
  private static func readerLPCMSettings(_ format: AudioFormat) -> [String: Any] {
    return [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channels,
      AVChannelLayoutKey: channelLayoutData(channels: format.channels),
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  /// AAC writer settings matching the reader's LPCM channel count/sample rate.
  private static func writerAACSettings(_ format: AudioFormat) -> [String: Any] {
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channels,
      AVEncoderBitRateKey: 128_000,
    ]
  }

  /// Encodes a mono or stereo `AudioChannelLayout` as `Data` for
  /// `AVChannelLayoutKey`.
  private static func channelLayoutData(channels: Int) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag =
      channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
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
