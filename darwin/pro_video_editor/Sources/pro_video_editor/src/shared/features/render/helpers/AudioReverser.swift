import AVFoundation
import Foundation

/// Pre-renders a reversed audio segment into a CoreAudio PCM temp file.
///
/// Unlike the frame-slice approach used by the old `reverseTimeRanges`
/// implementation (which reverses ~30 chunk positions per second but plays
/// each chunk forward, causing ~30 audible artefacts per second), this
/// class decodes the audio to raw PCM, reverses every sample in-place,
/// and writes the result as a CAF/PCM file. The caller inserts that file
/// into the composition with a single `insertTimeRange` call — no clicks,
/// no gaps, and the audio sounds exactly like the video played backwards.
internal enum AudioReverser {

  /// Result of a successful reversal.
  struct Result {
    /// Temporary CAF/PCM file.  The caller MUST delete this once
    /// the AVAssetExportSession has finished.
    let outputURL: URL
    /// Duration of the reversed audio.
    let duration: CMTime
  }

  // MARK: - Public API

  /// Decodes [startTime, endTime) from `inputPath`, reverses the PCM
  /// samples on the frame level (stereo 16-bit, 44.1 kHz), and writes
  /// the result to a temporary CAF/PCM file.
  ///
  /// Returns `nil` on failure (no audio track, empty PCM, write error)
  /// so the caller can fall back gracefully to no audio rather than
  /// failing the whole render.
  static func reverse(
    inputPath: String,
    startTime: CMTime,
    endTime: CMTime
  ) async -> Result? {
    let sourceURL = URL(fileURLWithPath: inputPath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      PluginLog.print("⚠️ AudioReverser: source file not found: \(inputPath)")
      return nil
    }

    let asset = AVURLAsset(url: sourceURL)

    // Resolve actual asset duration for the "until end" case.
    let assetDuration: CMTime
    if #available(iOS 15.0, macOS 13.0, *) {
      assetDuration = (try? await asset.load(.duration)) ?? .zero
    } else {
      assetDuration = asset.duration
    }

    let effectiveStart = CMTimeMaximum(startTime, .zero)
    let effectiveEnd = CMTimeMinimum(endTime, assetDuration)
    let segmentDuration = CMTimeSubtract(effectiveEnd, effectiveStart)
    guard CMTimeCompare(segmentDuration, .zero) > 0 else {
      PluginLog.print(
        "⚠️ AudioReverser: invalid segment \(effectiveStart.seconds)s–\(effectiveEnd.seconds)s")
      return nil
    }

    // Load audio track.
    let audioTracks: [AVAssetTrack]
    do {
      if #available(iOS 15.0, macOS 13.0, *) {
        audioTracks = try await asset.loadTracks(withMediaType: .audio)
      } else {
        audioTracks = asset.tracks(withMediaType: .audio)
      }
    } catch {
      PluginLog.print("⚠️ AudioReverser: failed to load tracks: \(error)")
      return nil
    }
    guard let audioTrack = audioTracks.first else {
      PluginLog.print("⚠️ AudioReverser: no audio track in \(inputPath)")
      return nil
    }

    // Preserve the SOURCE audio format (sample rate + channel count) instead
    // of forcing 44.1 kHz stereo. A reversed clip is dropped back into a
    // multi-clip timeline next to untouched clips; if its audio track has a
    // different sample rate / channel layout than its neighbours, AVFoundation
    // has to reconcile mixed formats inside a single composition audio track,
    // which destabilises looped playback. The reversed audio must look exactly
    // like a normal clip's audio. We still decode to 16-bit LE PCM so the
    // in-place frame reversal stays trivial.
    let bitsPerSample: Int = 16
    var sampleRate: Double = 44100
    var channelCount: Int = 2
    let sourceFormatDescriptions: [CMFormatDescription]
    if #available(iOS 15.0, macOS 13.0, *) {
      sourceFormatDescriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
    } else {
      sourceFormatDescriptions = audioTrack.formatDescriptions as! [CMFormatDescription]
    }
    if let formatDescription = sourceFormatDescriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    {
      if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
      if asbd.mChannelsPerFrame > 0 { channelCount = Int(asbd.mChannelsPerFrame) }
    }
    let bytesPerFrame = channelCount * (bitsPerSample / 8)

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: bitsPerSample,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    // Decode PCM.
    let pcm: Data
    do {
      pcm = try await readPcm(
        from: asset,
        track: audioTrack,
        start: effectiveStart,
        duration: segmentDuration,
        outputSettings: outputSettings
      )
    } catch {
      PluginLog.print("⚠️ AudioReverser: PCM decode failed: \(error)")
      return nil
    }
    guard !pcm.isEmpty else {
      PluginLog.print("⚠️ AudioReverser: decoded PCM is empty")
      return nil
    }

    var bytes = [UInt8](pcm)
    // Reverse PCM on the frame level (swap frame 0 ↔ last, etc.).
    let frameCount = bytes.count / bytesPerFrame
    var lo = 0
    var hi = frameCount - 1
    while lo < hi {
      let loOff = lo * bytesPerFrame
      let hiOff = hi * bytesPerFrame
      for i in 0..<bytesPerFrame {
        bytes.swapAt(loOff + i, hiOff + i)
      }
      lo += 1
      hi -= 1
    }

    // Write an AVFoundation-authored CAF/PCM file. This avoids both the
    // hand-authored WAV path and AAC encoder priming in the temporary
    // reversed audio asset.
    let outputURL = makeTemporaryCAFURL()
    do {
      try writeCAF(
        pcmBytes: bytes,
        to: outputURL,
        sampleRate: Int(sampleRate),
        channelCount: channelCount,
        bitsPerSample: bitsPerSample
      )
    } catch {
      PluginLog.print("⚠️ AudioReverser: CAF write failed: \(error)")
      return nil
    }

    let outputFrameCount = bytes.count / bytesPerFrame
    let duration = CMTime(
      value: CMTimeValue(outputFrameCount),
      timescale: CMTimeScale(sampleRate)
    )

    PluginLog.print(
      "⏪ AudioReverser: reversed \(bytes.count) bytes (\(duration.seconds)s) to CAF/PCM for \(inputPath)"
    )
    return Result(outputURL: outputURL, duration: duration)
  }

  // MARK: - Private helpers

  private static func readPcm(
    from asset: AVAsset,
    track: AVAssetTrack,
    start: CMTime,
    duration: CMTime,
    outputSettings: [String: Any]
  ) async throws -> Data {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: start, duration: duration)

    let trackOutput = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: outputSettings
    )
    trackOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(trackOutput) else {
      throw NSError(
        domain: "AudioReverser",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add track output to reader"]
      )
    }
    reader.add(trackOutput)
    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "AudioReverser",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader.startReading failed"]
        )
    }

    var pcm = Data()
    while reader.status == .reading,
      let sampleBuffer = trackOutput.copyNextSampleBuffer()
    {
      if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        if length > 0 {
          var tempBytes = [UInt8](repeating: 0, count: length)
          let status = CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: length,
            destination: &tempBytes
          )
          if status == kCMBlockBufferNoErr {
            pcm.append(contentsOf: tempBytes)
          }
        }
      }
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return pcm
  }

  private static func makeTemporaryCAFURL() -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let name = "reverse_audio_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).caf"
    return tmp.appendingPathComponent(name)
  }

  private static func writeCAF(
    pcmBytes: [UInt8],
    to outputURL: URL,
    sampleRate: Int,
    channelCount: Int,
    bitsPerSample: Int
  ) throws {
    let bytesPerFrame = channelCount * (bitsPerSample / 8)
    let frameCount = pcmBytes.count / bytesPerFrame
    guard frameCount > 0 else {
      throw NSError(
        domain: "AudioReverser",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "No PCM frames to write"]
      )
    }

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: bitsPerSample,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let audioFile = try AVAudioFile(
      forWriting: outputURL,
      settings: outputSettings,
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFile.processingFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else {
      throw NSError(
        domain: "AudioReverser",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"]
      )
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard audioBuffers.count == 1, let destination = audioBuffers[0].mData else {
      throw NSError(
        domain: "AudioReverser",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Unexpected PCM buffer layout"]
      )
    }

    audioBuffers[0].mDataByteSize = UInt32(pcmBytes.count)
    pcmBytes.withUnsafeBytes { source in
      if let baseAddress = source.baseAddress {
        destination.copyMemory(from: baseAddress, byteCount: pcmBytes.count)
      }
    }

    try audioFile.write(from: buffer)
  }
}
