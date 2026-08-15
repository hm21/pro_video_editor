import AVFoundation
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Service for merging the audio of several trimmed clip windows into a single,
/// seamlessly concatenated audio file using AVFoundation.
///
/// The pipeline decodes every segment to one uniform 16-bit PCM format
/// (`targetSampleRate` / `targetChannels`), concatenates the PCM back-to-back
/// with no gaps, and then — for non-WAV formats — transcodes the concatenated
/// WAV to the requested container. A segment whose source has no audio track
/// contributes silence of its normal output length instead of throwing.
///
/// A single-segment call with the default (unpinned) output format delegates to
/// `ExtractAudio` so its bytes are identical to `extractAudioToFile`.
class MergeAudio {

  /// Mutable, lock-guarded cancellation state shared with the returned handle.
  private final class CancelState {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _childHandle: AudioExtractJobHandle?

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _isCancelled
    }

    func setChildHandle(_ handle: @escaping AudioExtractJobHandle) {
      lock.lock()
      let alreadyCancelled = _isCancelled
      _childHandle = handle
      lock.unlock()
      if alreadyCancelled { handle() }
    }

    func cancel() {
      lock.lock()
      _isCancelled = true
      let handle = _childHandle
      lock.unlock()
      handle?()
    }
  }

  /// Error thrown internally when the merge is cancelled.
  private struct CancelledError: Error {}

  /// Merges the configured segments into one audio file asynchronously.
  ///
  /// - Parameters:
  ///   - config: The merge configuration (segments + output format).
  ///   - onProgress: Progress callback (0.0 to 1.0).
  ///   - onComplete: Success callback with the result map
  ///     (`outputPath`, `totalDurationUs`, `segments`).
  ///   - onError: Failure callback.
  /// - Returns: A cancellation handle.
  static func merge(
    config: AudioMergeConfig,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping ([String: Any]) -> Void,
    onError: @escaping (Error) -> Void
  ) -> AudioExtractJobHandle {

    let cancelState = CancelState()

    let task = Task.detached(priority: .userInitiated) {
      do {
        try await runMerge(
          config: config,
          cancelState: cancelState,
          onProgress: onProgress,
          onComplete: onComplete,
          onError: onError)
      } catch {
        onError(error)
      }
    }

    return {
      cancelState.cancel()
      task.cancel()
    }
  }

  // MARK: - Orchestration

  private static func runMerge(
    config: AudioMergeConfig,
    cancelState: CancelState,
    onProgress: @escaping (Double) -> Void,
    onComplete: @escaping ([String: Any]) -> Void,
    onError: @escaping (Error) -> Void
  ) async throws {
    onProgress(0.0)

    // Fast path: a single segment with the default (unpinned) output format and
    // a real audio track delegates to ExtractAudio for byte-for-byte parity
    // with extractAudioToFile.
    if config.segments.count == 1, !config.hasExplicitFormat {
      let segment = config.segments[0]
      let asset = AVURLAsset(url: URL(fileURLWithPath: segment.inputPath))
      // `try?` on an optional-returning throwing call yields a double optional;
      // flatten with `?? nil` so "no audio track" is not mistaken for "no throw".
      let probedTrack = (try? await MediaInfoExtractor.loadAudioTrack(from: asset)) ?? nil
      if probedTrack != nil {
        if cancelState.isCancelled { throw CancelledError() }
        let handle = ExtractAudio.extract(
          config: config.extractConfig(for: segment),
          onProgress: onProgress,
          onComplete: { _ in
            Task.detached {
              let durationUs = await MediaInfoExtractor.getAudioDuration(config.outputPath)
              onComplete(
                singleSegmentResult(outputPath: config.outputPath, durationUs: durationUs))
            }
          },
          onError: onError)
        cancelState.setChildHandle(handle)
        return
      }
      // No audio track -> fall through to the general path (produces silence).
    }

    let (targetRate, targetChannels) = await resolveOutputFormat(config: config)
    let bytesPerFrame = Int64(targetChannels * 2)

    let isWav = config.getOutputExtension().lowercased() == "wav"
    let outputURL = URL(fileURLWithPath: config.outputPath)
    let pcmURL: URL =
      isWav
      ? outputURL
      : FileManager.default.temporaryDirectory
        .appendingPathComponent("merge_\(config.id)_\(Date().timeIntervalSince1970).wav")

    try? FileManager.default.removeItem(at: pcmURL)
    guard FileManager.default.createFile(atPath: pcmURL.path, contents: nil) else {
      throw NSError(
        domain: "MergeAudio", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot create output file"])
    }

    let fileHandle = try FileHandle(forWritingTo: pcmURL)
    var success = false
    defer {
      try? fileHandle.close()
      if !success { try? FileManager.default.removeItem(at: pcmURL) }
    }

    // Placeholder header, rewritten once the total size is known.
    fileHandle.write(
      buildWavHeader(pcmDataSize: 0, sampleRate: targetRate, channels: targetChannels))

    var segmentFrames: [Int64] = []
    var totalPcmBytes: Int64 = 0
    let maxWavDataSize: Int64 = 0xFFFF_FFFF - 36
    let count = config.segments.count

    for (index, segment) in config.segments.enumerated() {
      if cancelState.isCancelled { throw CancelledError() }

      let asset = AVURLAsset(url: URL(fileURLWithPath: segment.inputPath))
      let audioTrack = (try? await MediaInfoExtractor.loadAudioTrack(from: asset)) ?? nil

      let bytesWritten: Int64
      if let audioTrack = audioTrack {
        bytesWritten = try decodeSegment(
          asset: asset,
          audioTrack: audioTrack,
          segment: segment,
          targetRate: targetRate,
          targetChannels: targetChannels,
          fileHandle: fileHandle,
          segmentIndex: index,
          segmentCount: count,
          cancelState: cancelState,
          onProgress: onProgress)
      } else {
        // No audio track: contribute silence of the segment's output length.
        let nominalUs = Double(segment.endUs - segment.startUs) / segment.speed
        let frames = Int64((nominalUs * Double(targetRate) / 1_000_000.0).rounded())
        bytesWritten = try writeSilence(
          frames: frames, bytesPerFrame: bytesPerFrame, fileHandle: fileHandle,
          cancelState: cancelState)
        onProgress(min(Double(index + 1) / Double(count), 0.99))
      }

      totalPcmBytes += bytesWritten
      if totalPcmBytes > maxWavDataSize {
        throw NSError(
          domain: "MergeAudio", code: -2,
          userInfo: [NSLocalizedDescriptionKey: "WAV output exceeds 4 GB limit."])
      }
      segmentFrames.append(bytesWritten / bytesPerFrame)
    }

    if cancelState.isCancelled { throw CancelledError() }

    // Finalize the WAV header with the real data size.
    fileHandle.seek(toFileOffset: 0)
    fileHandle.write(
      buildWavHeader(
        pcmDataSize: Int(totalPcmBytes), sampleRate: targetRate, channels: targetChannels))
    try? fileHandle.close()
    success = true

    // Transcode the concatenated PCM WAV to the requested container if needed.
    if !isWav {
      do {
        try await transcode(pcmURL: pcmURL, to: outputURL, format: config.format.lowercased())
        try? FileManager.default.removeItem(at: pcmURL)
      } catch {
        try? FileManager.default.removeItem(at: pcmURL)
        throw error
      }
    }

    onProgress(1.0)
    onComplete(
      buildResult(
        outputPath: config.outputPath, segmentFrames: segmentFrames, sampleRate: targetRate))
  }

  // MARK: - Segment decode

  /// Decodes one segment's trimmed, speed-adjusted window to uniform PCM and
  /// appends it to `fileHandle`. Returns the number of PCM bytes written.
  private static func decodeSegment(
    asset: AVURLAsset,
    audioTrack: AVAssetTrack,
    segment: AudioMergeSegmentConfig,
    targetRate: Int,
    targetChannels: Int,
    fileHandle: FileHandle,
    segmentIndex: Int,
    segmentCount: Int,
    cancelState: CancelState,
    onProgress: @escaping (Double) -> Void
  ) throws -> Int64 {
    let startTime = CMTime(value: segment.startUs, timescale: 1_000_000)
    let endTime = CMTime(value: segment.endUs, timescale: 1_000_000)
    let trimRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))

    let composition = AVMutableComposition()
    guard
      let compositionAudioTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw NSError(
        domain: "MergeAudio", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create composition audio track"])
    }

    try compositionAudioTrack.insertTimeRange(trimRange, of: audioTrack, at: .zero)

    let applySpeed = segment.speed > 0 && segment.speed != 1.0
    if applySpeed {
      let scaled = CMTimeMultiplyByFloat64(trimRange.duration, multiplier: 1.0 / segment.speed)
      compositionAudioTrack.scaleTimeRange(
        CMTimeRange(start: .zero, duration: trimRange.duration), toDuration: scaled)
    }
    let effectiveDuration = CMTimeGetSeconds(
      applySpeed
        ? CMTimeMultiplyByFloat64(trimRange.duration, multiplier: 1.0 / segment.speed)
        : trimRange.duration)

    // Force a uniform 16-bit interleaved LE PCM output at the target rate and
    // channel count; the audio-mix output resamples/downmixes as needed.
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: targetRate,
      AVNumberOfChannelsKey: targetChannels,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let reader = try AVAssetReader(asset: composition)
    let mixOutput = AVAssetReaderAudioMixOutput(
      audioTracks: composition.tracks(withMediaType: .audio), audioSettings: outputSettings)
    mixOutput.audioTimePitchAlgorithm = .spectral
    mixOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(mixOutput) else {
      throw NSError(
        domain: "MergeAudio", code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
    }
    reader.add(mixOutput)

    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "MergeAudio", code: -5,
          userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
    }

    var bytesWritten: Int64 = 0
    while let sampleBuffer = mixOutput.copyNextSampleBuffer() {
      if cancelState.isCancelled {
        reader.cancelReading()
        throw CancelledError()
      }
      if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var chunk = Data(count: length)
        _ = chunk.withUnsafeMutableBytes { ptr in
          CMBlockBufferCopyDataBytes(
            blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        fileHandle.write(chunk)
        bytesWritten += Int64(length)
      }

      let currentTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      let fraction = effectiveDuration > 0 ? min(max(currentTime / effectiveDuration, 0.0), 1.0) : 1.0
      let overall = (Double(segmentIndex) + fraction) / Double(segmentCount)
      onProgress(min(overall, 0.99))
    }

    if reader.status == .failed {
      throw reader.error
        ?? NSError(
          domain: "MergeAudio", code: -6,
          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed during reading"])
    }

    return bytesWritten
  }

  /// Writes `frames` frames of silence (zeroed PCM) to `fileHandle`, returning
  /// the number of bytes written.
  private static func writeSilence(
    frames: Int64, bytesPerFrame: Int64, fileHandle: FileHandle, cancelState: CancelState
  ) throws -> Int64 {
    var remaining = frames * bytesPerFrame
    let chunkSize = 1 << 20  // 1 MB
    let zeros = Data(count: min(Int(remaining), chunkSize))
    while remaining > 0 {
      if cancelState.isCancelled { throw CancelledError() }
      let n = Int(min(remaining, Int64(chunkSize)))
      fileHandle.write(n == zeros.count ? zeros : Data(count: n))
      remaining -= Int64(n)
    }
    return frames * bytesPerFrame
  }

  // MARK: - Format helpers

  /// Resolves the uniform output sample rate and channel count.
  private static func resolveOutputFormat(config: AudioMergeConfig) async -> (Int, Int) {
    var rate = config.sampleRate ?? 0
    var channels = config.channels ?? 0

    if rate == 0 || channels == 0 {
      for segment in config.segments {
        let sr = await MediaInfoExtractor.getAudioSampleRate(segment.inputPath)
        if sr > 0 {
          if rate == 0 { rate = sr }
          if channels == 0 {
            channels = await MediaInfoExtractor.getAudioChannelCount(segment.inputPath) ?? 2
          }
          break
        }
      }
    }

    if rate <= 0 { rate = 44100 }
    if channels <= 0 { channels = 2 }
    return (rate, channels)
  }

  /// Transcodes a PCM WAV file to the requested container using an export
  /// session (AppleM4A re-encode for aac/m4a, passthrough for caf).
  private static func transcode(pcmURL: URL, to outputURL: URL, format: String) async throws {
    let asset = AVURLAsset(url: pcmURL)
    let isCaf = format == "caf"
    let presetName = isCaf ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
    let fileType: AVFileType = isCaf ? .caf : .m4a

    guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
      throw NSError(
        domain: "MergeAudio", code: -7,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
    }
    try? FileManager.default.removeItem(at: outputURL)

    do {
      // Through the shared driver rather than a continuation of its own: a
      // checked continuation is immune to cancellation, so a cancelled merge
      // used to keep encoding its container to completion.
      try await ExportSessionDriver.run(
        session, to: outputURL, as: fileType, label: "MergeAudio",
        failureDomain: "MergeAudio")
    } catch {
      // The path is the caller's, so a container that stopped mid-write must
      // not be left there looking finished.
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  // MARK: - Result

  private static func singleSegmentResult(outputPath: String, durationUs: Int64) -> [String: Any] {
    [
      "outputPath": outputPath,
      "totalDurationUs": durationUs,
      "segments": [["outputStartUs": Int64(0), "outputDurationUs": durationUs]],
    ]
  }

  /// Builds the result map from per-segment frame counts.
  ///
  /// Offsets are derived from cumulative frame boundaries so
  /// `outputStart[i] + outputDuration[i] == outputStart[i+1]` holds exactly and
  /// `sum(outputDuration) == totalDuration`.
  private static func buildResult(
    outputPath: String, segmentFrames: [Int64], sampleRate: Int
  ) -> [String: Any] {
    var bounds: [Int64] = [0]
    for frames in segmentFrames { bounds.append(bounds.last! + frames) }

    func framesToUs(_ frames: Int64) -> Int64 {
      Int64((Double(frames) * 1_000_000.0 / Double(sampleRate)).rounded())
    }

    var segments: [[String: Any]] = []
    for index in 0..<segmentFrames.count {
      let startUs = framesToUs(bounds[index])
      let endUs = framesToUs(bounds[index + 1])
      segments.append(["outputStartUs": startUs, "outputDurationUs": endUs - startUs])
    }

    return [
      "outputPath": outputPath,
      "totalDurationUs": framesToUs(bounds.last!),
      "segments": segments,
    ]
  }

  // MARK: - WAV header

  /// Builds a standard 44-byte RIFF/WAV header for 16-bit PCM audio.
  private static func buildWavHeader(pcmDataSize: Int, sampleRate: Int, channels: Int) -> Data {
    let bitsPerSample = 16
    let byteRate = sampleRate * channels * (bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)

    var header = Data()
    func appendU32(_ value: UInt32) {
      var v = value.littleEndian
      header.append(Data(bytes: &v, count: 4))
    }
    func appendU16(_ value: UInt16) {
      var v = value.littleEndian
      header.append(Data(bytes: &v, count: 2))
    }

    header.append(contentsOf: [UInt8]("RIFF".utf8))
    appendU32(UInt32(36 + pcmDataSize))
    header.append(contentsOf: [UInt8]("WAVE".utf8))
    header.append(contentsOf: [UInt8]("fmt ".utf8))
    appendU32(16)
    appendU16(1)
    appendU16(UInt16(channels))
    appendU32(UInt32(sampleRate))
    appendU32(UInt32(byteRate))
    appendU16(UInt16(blockAlign))
    appendU16(UInt16(bitsPerSample))
    header.append(contentsOf: [UInt8]("data".utf8))
    appendU32(UInt32(pcmDataSize))
    return header
  }
}
