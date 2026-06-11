import AVFoundation
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Exception thrown when no audio track is found in the video file.
class NoAudioTrackException: NSError, @unchecked Sendable {
  init() {
    super.init(
      domain: "ExtractAudio",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "No audio track found in video"]
    )
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

/// Service for extracting audio from video files using AVFoundation.
///
/// This class handles the audio extraction pipeline:
/// - Extracts audio track from video file
/// - Supports trimming (start/end time)
/// - Supports multiple output formats (M4A, AAC, CAF, WAV)
/// - Provides progress tracking during extraction
/// - Supports cancellation of active extraction jobs
class ExtractAudio {

  /// Extracts audio from a video file asynchronously.
  ///
  /// This method uses AVAssetExportSession for fast Passthrough export,
  /// or AVAssetReader + FileHandle for WAV transcoding.
  ///
  /// - Parameters:
  ///   - config: Complete extraction configuration
  ///   - onProgress: Callback invoked with progress updates (0.0 to 1.0)
  ///   - onComplete: Callback invoked on success with output bytes (nil if saved to file)
  ///   - onError: Callback invoked if extraction fails
  /// - Returns: Cancellation handle that can be used to stop the extraction
  static func extract(
    config: AudioExtractConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping (FlutterStandardTypedData?) -> Void,
    onError: @escaping (Error) -> Void
  ) -> AudioExtractJobHandle {

    let outputExtension = config.getOutputExtension().lowercased()
    if outputExtension == "wav" {
      return extractToWav(
        config: config,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError
      )
    }

    return extractPassthrough(
      config: config,
      onProgress: onProgress,
      onComplete: onComplete,
      onError: onError
    )
  }

  /// Extracts audio using passthrough (no transcoding) for M4A, AAC, CAF formats.
  private static func extractPassthrough(
    config: AudioExtractConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping (FlutterStandardTypedData?) -> Void,
    onError: @escaping (Error) -> Void
  ) -> AudioExtractJobHandle {

    class ExtractionContext {
      var isCancelled = false
      var progressTimer: Timer?
      var exportSession: AVAssetExportSession?
    }

    let context = ExtractionContext()

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let sourceURL = URL(fileURLWithPath: config.inputPath)
        let asset = AVURLAsset(url: sourceURL)

        let applySpeed = config.speed > 0 && config.speed != 1.0

        /// https://developer.apple.com/documentation/dispatch/dispatchsemaphore
        let semaphore = DispatchSemaphore(value: 0)
        var loadError: Error?

        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
          let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
          let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

          if tracksStatus == .failed || durationStatus == .failed {
            loadError = NSError(
              domain: "ExtractAudio",
              code: -10,
              userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
            )
          }
          semaphore.signal()
        }
        semaphore.wait()

        if let error = loadError { throw error }
        let duration = asset.duration

        let outputURL: URL
        if let outputPath = config.outputPath {
          outputURL = URL(fileURLWithPath: outputPath)
        } else {
          let tempDir = FileManager.default.temporaryDirectory
          let filename = "audio_\(Date().timeIntervalSince1970).\(config.getOutputExtension())"
          outputURL = tempDir.appendingPathComponent(filename)
        }

        try? FileManager.default.removeItem(at: outputURL)

        let fileExtension = outputURL.pathExtension.lowercased()
        // A speed change forces a re-encode through AVAssetExportPresetAppleM4A,
        // which only supports the .m4a (AAC) output file type.
        let outputFileType: AVFileType =
          applySpeed ? .m4a : ((fileExtension == "caf") ? .caf : .m4a)

        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
          throw NoAudioTrackException()
        }

        let sourceTimeRange: CMTimeRange
        if let startUs = config.startUs, let endUs = config.endUs {
          let startTime = CMTime(value: startUs, timescale: 1_000_000)
          let endTime = CMTime(value: endUs, timescale: 1_000_000)
          sourceTimeRange = CMTimeRange(
            start: startTime, duration: CMTimeSubtract(endTime, startTime))
        } else if let startUs = config.startUs {
          let startTime = CMTime(value: startUs, timescale: 1_000_000)
          sourceTimeRange = CMTimeRange(
            start: startTime, duration: CMTimeSubtract(duration, startTime))
        } else if let endUs = config.endUs {
          let endTime = CMTime(value: endUs, timescale: 1_000_000)
          sourceTimeRange = CMTimeRange(start: .zero, duration: endTime)
        } else {
          sourceTimeRange = audioTrack.timeRange
        }

        let composition = AVMutableComposition()
        guard
          let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        else {
          throw NSError(
            domain: "ExtractAudio", code: -13,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create composition audio track"]
          )
        }

        try compositionAudioTrack.insertTimeRange(sourceTimeRange, of: audioTrack, at: .zero)

        // Apply a pitch-preserving speed change by scaling the inserted range.
        if applySpeed {
          let scaled = CMTimeMultiplyByFloat64(
            sourceTimeRange.duration, multiplier: 1.0 / config.speed)
          compositionAudioTrack.scaleTimeRange(
            CMTimeRange(start: .zero, duration: sourceTimeRange.duration), toDuration: scaled)
        }

        // Passthrough can't re-time samples, so a speed change requires a
        // re-encoding preset.
        let presetName =
          applySpeed ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough
        guard
          let session = AVAssetExportSession(
            asset: composition,
            presetName: presetName
          )
        else {
          throw NSError(
            domain: "ExtractAudio", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"]
          )
        }

        session.outputURL = outputURL
        session.outputFileType = outputFileType
        if applySpeed {
          // Preserve the original pitch while time-stretching.
          session.audioTimePitchAlgorithm = .spectral
        }

        // Sync context access back to main thread to cleanly initialize timers
        DispatchQueue.main.async {
          guard !context.isCancelled else { return }
          context.exportSession = session

          onProgress(0.0)

          // Capturing context as unowned/weak or safely passing session fixes the warning
          context.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak context, weak session] _ in
            guard let context = context, let session = session, !context.isCancelled else { return }
            onProgress(Double(session.progress))
          }
        }

        session.exportAsynchronously {
          DispatchQueue.main.async {
            context.progressTimer?.invalidate()
            context.progressTimer = nil
          }

          if context.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
              onError(
                NSError(
                  domain: "ExtractAudio", code: -3,
                  userInfo: [NSLocalizedDescriptionKey: "Extraction was cancelled"]))
            }
            return
          }

          switch session.status {
          case .completed:
            do {
              if config.outputPath != nil {
                DispatchQueue.main.async {
                  onProgress(1.0)
                  onComplete(nil)
                }
              } else {
                let data = try Data(contentsOf: outputURL)
                try? FileManager.default.removeItem(at: outputURL)

                DispatchQueue.main.async {
                  onProgress(1.0)
                  let flutterData = FlutterStandardTypedData(bytes: data)
                  onComplete(flutterData)
                }
              }
            } catch {
              try? FileManager.default.removeItem(at: outputURL)
              DispatchQueue.main.async { onError(error) }
            }

          case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            let exportError =
              session.error
              ?? NSError(
                domain: "ExtractAudio", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Export failed"])
            DispatchQueue.main.async { onError(exportError) }

          case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
              onError(
                NSError(
                  domain: "ExtractAudio", code: -5,
                  userInfo: [NSLocalizedDescriptionKey: "Export was cancelled"]))
            }

          default:
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
              onError(
                NSError(
                  domain: "ExtractAudio", code: -6,
                  userInfo: [NSLocalizedDescriptionKey: "Unexpected status"]))
            }
          }
        }

      } catch {
        DispatchQueue.main.async {
          context.progressTimer?.invalidate()
          onError(error)
        }
      }
    }

    return {
      DispatchQueue.main.async {
        context.isCancelled = true
        context.exportSession?.cancelExport()
        context.progressTimer?.invalidate()
        context.progressTimer = nil
      }
    }
  }

  /// Extracts audio to WAV format by streaming raw PCM into a RIFF/WAV file.
  private static func extractToWav(
    config: AudioExtractConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping (FlutterStandardTypedData?) -> Void,
    onError: @escaping (Error) -> Void
  ) -> AudioExtractJobHandle {

    let maxWavDataSize: Int64 = 0xFFFF_FFFF - 36
    var assetReader: AVAssetReader?
    var isCancelled = false

    let task = Task.detached(priority: .userInitiated) {
      do {
        let sourceURL = URL(fileURLWithPath: config.inputPath)
        let asset = AVURLAsset(url: sourceURL)

        var duration = CMTime.zero

        if #available(macOS 12.0, iOS 15.0, *) {
          (_, duration) = try await asset.load(.tracks, .duration)
        } else {
          try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
              let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
              let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)

              if tracksStatus == .failed || durationStatus == .failed {
                continuation.resume(
                  throwing: NSError(
                    domain: "ExtractAudio",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to load asset properties"]
                  ))
              } else {
                duration = asset.duration
                continuation.resume()
              }
            }
          }
        }

        let outputURL: URL
        if let outputPath = config.outputPath {
          outputURL = URL(fileURLWithPath: outputPath)
        } else {
          let tempDir = FileManager.default.temporaryDirectory
          let filename = "audio_\(Date().timeIntervalSince1970).wav"
          outputURL = tempDir.appendingPathComponent(filename)
        }

        try? FileManager.default.removeItem(at: outputURL)

        let audioTracks: [AVAssetTrack]
        if #available(macOS 12.0, iOS 15.0, *) {
          audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } else {
          audioTracks = asset.tracks(withMediaType: .audio)
        }

        guard let audioTrack = audioTracks.first else {
          throw NoAudioTrackException()
        }

        let formatDescriptions: [CMAudioFormatDescription]
        if #available(macOS 12.0, iOS 15.0, *) {
          formatDescriptions = try await audioTrack.load(.formatDescriptions)
        } else {
          formatDescriptions = audioTrack.formatDescriptions as! [CMAudioFormatDescription]
        }

        guard let formatDescription = formatDescriptions.first else {
          throw NSError(
            domain: "ExtractAudio",
            code: -8,
            userInfo: [NSLocalizedDescriptionKey: "No audio format description found"]
          )
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee
        let sampleRate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)
        let bitsPerSample = 16

        var timeRange: CMTimeRange
        if let startUs = config.startUs, let endUs = config.endUs {
          let startTime = CMTime(value: startUs, timescale: 1_000_000)
          let endTime = CMTime(value: endUs, timescale: 1_000_000)
          timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
        } else if let startUs = config.startUs {
          let startTime = CMTime(value: startUs, timescale: 1_000_000)
          timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(duration, startTime))
        } else if let endUs = config.endUs {
          let endTime = CMTime(value: endUs, timescale: 1_000_000)
          timeRange = CMTimeRange(start: .zero, duration: endTime)
        } else {
          timeRange = audioTrack.timeRange
        }

        let applySpeed = config.speed > 0 && config.speed != 1.0

        let readerOutputSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: bitsPerSample,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        let readerOutput: AVAssetReaderOutput
        // Duration/start used only for progress reporting.
        let effectiveDuration: CMTime
        let progressStartSeconds: Double

        if applySpeed {
          // Build a composition holding only the requested range, then scale it
          // to apply the speed change. Reading it through an audio-mix output
          // lets us request a pitch-preserving time-stretch.
          let composition = AVMutableComposition()
          guard
            let compositionAudioTrack = composition.addMutableTrack(
              withMediaType: .audio,
              preferredTrackID: kCMPersistentTrackID_Invalid
            )
          else {
            throw NSError(
              domain: "ExtractAudio", code: -14,
              userInfo: [NSLocalizedDescriptionKey: "Failed to create composition audio track"])
          }

          try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
          let scaled = CMTimeMultiplyByFloat64(timeRange.duration, multiplier: 1.0 / config.speed)
          compositionAudioTrack.scaleTimeRange(
            CMTimeRange(start: .zero, duration: timeRange.duration), toDuration: scaled)

          let compositionReader = try AVAssetReader(asset: composition)
          let mixOutput = AVAssetReaderAudioMixOutput(
            audioTracks: composition.tracks(withMediaType: .audio),
            audioSettings: readerOutputSettings)
          mixOutput.audioTimePitchAlgorithm = .spectral
          mixOutput.alwaysCopiesSampleData = false

          guard compositionReader.canAdd(mixOutput) else {
            throw NSError(
              domain: "ExtractAudio", code: -7,
              userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
          }
          compositionReader.add(mixOutput)

          reader = compositionReader
          readerOutput = mixOutput
          effectiveDuration = scaled
          // Composition samples start at zero.
          progressStartSeconds = 0.0
        } else {
          let trackReader = try AVAssetReader(asset: asset)
          trackReader.timeRange = timeRange

          let trackOutput = AVAssetReaderTrackOutput(
            track: audioTrack, outputSettings: readerOutputSettings)
          trackOutput.alwaysCopiesSampleData = false

          guard trackReader.canAdd(trackOutput) else {
            throw NSError(
              domain: "ExtractAudio", code: -7,
              userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
          }
          trackReader.add(trackOutput)

          reader = trackReader
          readerOutput = trackOutput
          effectiveDuration = timeRange.duration
          progressStartSeconds = CMTimeGetSeconds(timeRange.start)
        }
        assetReader = reader

        let fm = FileManager.default
        guard fm.createFile(atPath: outputURL.path, contents: nil) else {
          throw NSError(
            domain: "ExtractAudio", code: -9,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create output file"])
        }

        let fileHandle = try FileHandle(forWritingTo: outputURL)
        var writeSuccess = false
        defer {
          try? fileHandle.close()
          if !writeSuccess { try? fm.removeItem(at: outputURL) }
        }

        fileHandle.write(
          buildWavHeader(
            pcmDataSize: 0, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample
          ))

        guard reader.startReading() else {
          throw reader.error
            ?? NSError(
              domain: "ExtractAudio", code: -10,
              userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        DispatchQueue.main.async { onProgress(0.0) }

        let totalDuration = CMTimeGetSeconds(effectiveDuration)
        var totalPcmBytes: Int64 = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
          if isCancelled { break }

          if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)

            totalPcmBytes += Int64(length)
            if totalPcmBytes > maxWavDataSize {
              reader.cancelReading()
              throw NSError(
                domain: "ExtractAudio", code: -13,
                userInfo: [NSLocalizedDescriptionKey: "WAV output exceeds 4 GB Limit."])
            }

            var chunk = Data(count: length)
            _ = chunk.withUnsafeMutableBytes { ptr in
              CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            fileHandle.write(chunk)
          }

          let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          let elapsed = CMTimeGetSeconds(currentTime) - progressStartSeconds
          let progress = totalDuration > 0 ? min(max(elapsed / totalDuration, 0.0), 0.99) : 0.0
          DispatchQueue.main.async { onProgress(progress) }
        }

        if reader.status == .failed {
          throw reader.error
            ?? NSError(
              domain: "ExtractAudio", code: -11,
              userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed during reading"])
        }

        if isCancelled {
          reader.cancelReading()
          DispatchQueue.main.async {
            onError(
              NSError(
                domain: "ExtractAudio", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Extraction was cancelled"]))
          }
        } else {
          fileHandle.seek(toFileOffset: 0)
          fileHandle.write(
            buildWavHeader(
              pcmDataSize: Int(totalPcmBytes), sampleRate: sampleRate, channels: channels,
              bitsPerSample: bitsPerSample))

          writeSuccess = true

          if config.outputPath != nil {
            DispatchQueue.main.async {
              onProgress(1.0)
              onComplete(nil)
            }
          } else {
            let data = try Data(contentsOf: outputURL)
            try? fm.removeItem(at: outputURL)
            DispatchQueue.main.async {
              onProgress(1.0)
              let flutterData = FlutterStandardTypedData(bytes: data)
              onComplete(flutterData)
            }
          }
        }

      } catch {
        DispatchQueue.main.async { onError(error) }
      }
    }

    return {
      isCancelled = true
      task.cancel()
      assetReader?.cancelReading()
    }
  }

  /// Builds a standard 44-byte RIFF/WAV header for 16-bit PCM audio.
  private static func buildWavHeader(
    pcmDataSize: Int,
    sampleRate: Int,
    channels: Int,
    bitsPerSample: Int
  ) -> Data {
    let byteRate = sampleRate * channels * (bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)

    var header = Data()
    header.append(contentsOf: [UInt8]("RIFF".utf8))
    header.append(UInt32(36 + pcmDataSize).littleEndianBytes)
    header.append(contentsOf: [UInt8]("WAVE".utf8))
    header.append(contentsOf: [UInt8]("fmt ".utf8))
    header.append(UInt32(16).littleEndianBytes)
    header.append(UInt16(1).littleEndianBytes)
    header.append(UInt16(channels).littleEndianBytes)
    header.append(UInt32(sampleRate).littleEndianBytes)
    header.append(UInt32(byteRate).littleEndianBytes)
    header.append(UInt16(blockAlign).littleEndianBytes)
    header.append(UInt16(bitsPerSample).littleEndianBytes)
    header.append(contentsOf: [UInt8]("data".utf8))
    header.append(UInt32(pcmDataSize).littleEndianBytes)
    return header
  }
}

extension UInt32 {
  fileprivate var littleEndianBytes: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
  }
}

extension UInt16 {
  fileprivate var littleEndianBytes: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
  }
}
