import AVFoundation
import Foundation

/// Pre-renders a custom audio track into a single, gap-less PCM WAV file
/// that is ready to be inserted into an AVMutableComposition with ONE
/// `insertTimeRange` call.
///
/// This avoids audible clicks at every loop restart when the source audio
/// is a compressed format (AAC, MP3) and `AVMutableComposition.insertTimeRange`
/// is called multiple times on the source — each call respects encoder
/// priming/padding samples and aligns to compressed-frame boundaries
/// (~1024 samples for AAC, ~1152 for MP3), producing audible artifacts.
///
/// By decoding to PCM once and looping/trimming on raw samples, every
/// loop boundary is sample-exact and silent transitions are perfectly
/// continuous.
internal enum AudioPreRenderer {

  /// Result of a successful pre-render operation.
  struct Result {
    /// The pre-rendered PCM WAV file URL. The caller is responsible
    /// for deleting this file when no longer needed.
    let outputURL: URL
    /// Total duration of the pre-rendered audio.
    let duration: CMTime
  }

  /// Pre-renders the audio described by the parameters.
  ///
  /// The output file contains exactly `targetBodyDuration` of audio:
  /// the trimmed source `[audioStartTime, audioEndTime)` looped (or
  /// played once) to fill the duration, with sample-exact tail trim.
  ///
  /// No silence padding is added — leading/trailing silence on the
  /// composition timeline is handled implicitly by inserting this file
  /// at the correct `compositionInsertTime`.
  ///
  /// An optional linear fade in and out is baked into the samples, so the
  /// audio mix needs no volume ramp of its own.
  ///
  /// - Parameters:
  ///   - audioPath: Absolute path to the source audio file.
  ///   - audioStartTime: Trim start within the source.
  ///   - audioEndTime: Trim end within the source (nil = use full
  ///     source duration).
  ///   - loop: If true, the trimmed window repeats to fill
  ///     `targetBodyDuration`. If false, the source plays once and the
  ///     remaining time is filled with silence.
  ///   - targetBodyDuration: How long the output audio should sound.
  ///   - fadeIn: How long the audio rises from silence to full level
  ///     after it starts.
  ///   - fadeOut: How long the audio falls to silence before it ends —
  ///     the end of the body, or earlier when a non-looping source runs
  ///     out first.
  /// - Returns: A [Result] on success, nil on failure.
  static func render(
    audioPath: String,
    audioStartTime: CMTime,
    audioEndTime: CMTime?,
    loop: Bool,
    targetBodyDuration: CMTime,
    fadeIn: CMTime = .zero,
    fadeOut: CMTime = .zero
  ) async -> Result? {
    let sourceURL = URL(fileURLWithPath: audioPath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      PluginLog.print("⚠️ AudioPreRenderer: source file not found: \(audioPath)")
      return nil
    }

    if CMTimeCompare(targetBodyDuration, .zero) <= 0 {
      PluginLog.print("⚠️ AudioPreRenderer: targetBodyDuration <= 0, skipping")
      return nil
    }

    // Step 1: decode the trimmed range to PCM bytes.
    let asset = AVURLAsset(url: sourceURL)

    // Load the audio track first — its time range gives us the real
    // audio length even when asset-level duration resolution fails.
    let audioTracks: [AVAssetTrack]
    do {
      if #available(macOS 12.0, iOS 15.0, *) {
        audioTracks = try await asset.loadTracks(withMediaType: .audio)
      } else {
        audioTracks = asset.tracks(withMediaType: .audio)
      }
    } catch {
      PluginLog.print("⚠️ AudioPreRenderer: failed to load tracks: \(error)")
      return nil
    }

    guard let audioTrack = audioTracks.first else {
      PluginLog.print("⚠️ AudioPreRenderer: no audio tracks in source")
      return nil
    }

    // Resolve the source duration. Prefer the asset duration, but fall
    // back to the audio track's own time range when the asset-level
    // duration fails to load or resolves to zero — otherwise a perfectly
    // valid file would be dropped with a misleading "invalid trim range".
    var sourceDuration: CMTime
    if #available(macOS 12.0, iOS 15.0, *) {
      sourceDuration = (try? await asset.load(.duration)) ?? .zero
    } else {
      sourceDuration = asset.duration
    }
    if CMTimeCompare(sourceDuration, .zero) <= 0 {
      let trackDuration: CMTime
      if #available(macOS 12.0, iOS 15.0, *) {
        trackDuration = (try? await audioTrack.load(.timeRange))?.duration ?? .zero
      } else {
        trackDuration = audioTrack.timeRange.duration
      }
      if CMTimeCompare(trackDuration, .zero) > 0 {
        PluginLog.print(
          "ℹ️ AudioPreRenderer: asset duration unavailable, using audio track duration \(trackDuration.seconds)s"
        )
        sourceDuration = trackDuration
      } else {
        PluginLog.print("⚠️ AudioPreRenderer: could not resolve source duration")
        return nil
      }
    }

    let effectiveStart = CMTimeMaximum(audioStartTime, .zero)
    let effectiveEnd = CMTimeMinimum(audioEndTime ?? sourceDuration, sourceDuration)
    let trimDuration = CMTimeSubtract(effectiveEnd, effectiveStart)
    if CMTimeCompare(trimDuration, .zero) <= 0 {
      PluginLog.print(
        "⚠️ AudioPreRenderer: invalid trim range start=\(effectiveStart.seconds)s end=\(effectiveEnd.seconds)s"
      )
      return nil
    }

    // Output PCM format: 44.1kHz stereo 16-bit signed little-endian
    // (matches typical AAC/MP3 source rate; AVAssetWriter will
    // resample internally during the final video export if needed).
    // Using a fixed format keeps the pre-render simple and
    // predictable for the AVMutableComposition consumer.
    let sampleRate: Double = 44100
    let channelCount: Int = 2
    let bitsPerSample: Int = 16
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

    let trimmedPcm: Data
    do {
      trimmedPcm = try await readPcm(
        from: asset,
        track: audioTrack,
        start: effectiveStart,
        duration: trimDuration,
        outputSettings: outputSettings
      )
    } catch {
      PluginLog.print("⚠️ AudioPreRenderer: PCM read failed: \(error)")
      return nil
    }

    if trimmedPcm.isEmpty {
      PluginLog.print("⚠️ AudioPreRenderer: decoded PCM is empty")
      return nil
    }

    // Step 2: build the output PCM data (loop / trim / pad).
    let targetBytes = bytesForDuration(
      targetBodyDuration,
      sampleRate: sampleRate,
      bytesPerFrame: bytesPerFrame
    )

    var outputBytes = Data(capacity: targetBytes)

    if loop {
      // Repeat trimmedPcm until we have exactly targetBytes.
      while outputBytes.count < targetBytes {
        let remaining = targetBytes - outputBytes.count
        if remaining >= trimmedPcm.count {
          outputBytes.append(trimmedPcm)
        } else {
          outputBytes.append(trimmedPcm.subdata(in: 0..<remaining))
        }
      }
    } else {
      // Play once, then pad with silence to targetBytes.
      let writeLen = min(trimmedPcm.count, targetBytes)
      outputBytes.append(trimmedPcm.subdata(in: 0..<writeLen))
      if outputBytes.count < targetBytes {
        let silenceBytes = targetBytes - outputBytes.count
        outputBytes.append(Data(count: silenceBytes))
      }
    }

    // A non-looping source stops sounding where it runs out, so that is
    // where its fade out has to end, not at the end of the silence after it.
    let audibleBytes = loop ? targetBytes : min(trimmedPcm.count, targetBytes)
    applyFade(
      to: &outputBytes,
      audibleBytes: audibleBytes,
      bytesPerFrame: bytesPerFrame,
      fadeInFrames: framesForDuration(fadeIn, sampleRate: sampleRate),
      fadeOutFrames: framesForDuration(fadeOut, sampleRate: sampleRate)
    )

    // Step 3: write the WAV file.
    let outputURL = makeTemporaryWavURL()
    do {
      let wavData = makeWav(
        pcmBytes: outputBytes,
        sampleRate: Int(sampleRate),
        channelCount: channelCount,
        bitsPerSample: bitsPerSample
      )
      try wavData.write(to: outputURL, options: .atomic)
    } catch {
      PluginLog.print("⚠️ AudioPreRenderer: write failed: \(error)")
      return nil
    }

    let frameCount = outputBytes.count / bytesPerFrame
    let outputDuration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate))

    PluginLog.print(
      "🎼 AudioPreRenderer: rendered \(outputBytes.count) bytes (\(outputDuration.seconds)s), loop=\(loop), fadeIn=\(fadeIn.seconds)s, fadeOut=\(fadeOut.seconds)s"
    )

    return Result(outputURL: outputURL, duration: outputDuration)
  }

  // MARK: - Fade

  /// Ramps the gain of the first `fadeInFrames` and the last `fadeOutFrames`
  /// of the first `audibleBytes` of 16-bit little-endian PCM in `pcm`.
  ///
  /// Both ramps are linear, reaching silence at the audible edge, and where
  /// they overlap the quieter one wins, so a fade longer than the audio is
  /// cut short rather than rejected. Frames outside the ramps are untouched.
  static func applyFade(
    to pcm: inout Data,
    audibleBytes: Int,
    bytesPerFrame: Int,
    fadeInFrames: Int,
    fadeOutFrames: Int
  ) {
    let audibleFrames = min(audibleBytes, pcm.count) / bytesPerFrame
    if audibleFrames <= 0 { return }
    let inEnd = min(max(fadeInFrames, 0), audibleFrames)
    let outStart = max(audibleFrames - max(fadeOutFrames, 0), 0)
    if inEnd <= 0 && outStart >= audibleFrames { return }

    // One pass when the ramps meet, so no frame is scaled twice.
    let ranges: [Range<Int>] =
      inEnd >= outStart ? [0..<audibleFrames] : [0..<inEnd, outStart..<audibleFrames]
    let samplesPerFrame = bytesPerFrame / 2

    pcm.withUnsafeMutableBytes { raw in
      raw.withMemoryRebound(to: Int16.self) { samples in
        for range in ranges {
          for frame in range {
            let gain = fadeGain(
              frame: frame,
              audibleFrames: audibleFrames,
              fadeInFrames: fadeInFrames,
              fadeOutFrames: fadeOutFrames
            )
            if gain >= 1 { continue }
            let first = frame * samplesPerFrame
            for index in first..<(first + samplesPerFrame) {
              let sample = Double(Int16(littleEndian: samples[index]))
              samples[index] = Int16((sample * gain).rounded()).littleEndian
            }
          }
        }
      }
    }
  }

  /// The gain of `frame` out of `audibleFrames`: rising from 0 over the first
  /// `fadeInFrames`, falling to 0 over the last `fadeOutFrames`, and the lower
  /// of the two where they overlap.
  static func fadeGain(
    frame: Int,
    audibleFrames: Int,
    fadeInFrames: Int,
    fadeOutFrames: Int
  ) -> Double {
    let inGain = fadeInFrames > 0 ? Double(frame) / Double(fadeInFrames) : 1
    let outGain =
      fadeOutFrames > 0 ? Double(audibleFrames - frame) / Double(fadeOutFrames) : 1
    return max(min(inGain, outGain, 1), 0)
  }

  // MARK: - Private helpers

  /// How many frames `duration` spans at `sampleRate`.
  private static func framesForDuration(_ duration: CMTime, sampleRate: Double) -> Int {
    let seconds = duration.seconds
    if !seconds.isFinite || seconds <= 0 { return 0 }
    return Int(seconds * sampleRate)
  }

  /// Reads PCM data from the source asset for a specific time range.
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
        domain: "AudioPreRenderer",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add track output to reader"]
      )
    }
    reader.add(trackOutput)

    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "AudioPreRenderer",
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

    if reader.status == .failed, let error = reader.error {
      throw error
    }

    return pcm
  }

  /// Computes the number of PCM bytes that represent `duration` at the
  /// given sample rate and bytes-per-frame, aligned to a frame
  /// boundary.
  private static func bytesForDuration(
    _ duration: CMTime,
    sampleRate: Double,
    bytesPerFrame: Int
  ) -> Int {
    return framesForDuration(duration, sampleRate: sampleRate) * bytesPerFrame
  }

  /// Creates a unique temporary WAV file URL in the cache directory.
  private static func makeTemporaryWavURL() -> URL {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    let name =
      "prerender_audio_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).wav"
    return tmpDir.appendingPathComponent(name)
  }

  /// Builds a complete WAV file (RIFF header + PCM data) as `Data`.
  private static func makeWav(
    pcmBytes: Data,
    sampleRate: Int,
    channelCount: Int,
    bitsPerSample: Int
  ) -> Data {
    let byteRate = sampleRate * channelCount * bitsPerSample / 8
    let blockAlign = channelCount * bitsPerSample / 8
    let dataSize = UInt32(pcmBytes.count)
    let chunkSize = UInt32(36) + dataSize

    var header = Data(capacity: 44)
    header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
    header.appendLittleEndian(UInt32(chunkSize))
    header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"
    header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
    header.appendLittleEndian(UInt32(16))  // PCM fmt chunk size
    header.appendLittleEndian(UInt16(1))  // PCM format
    header.appendLittleEndian(UInt16(channelCount))
    header.appendLittleEndian(UInt32(sampleRate))
    header.appendLittleEndian(UInt32(byteRate))
    header.appendLittleEndian(UInt16(blockAlign))
    header.appendLittleEndian(UInt16(bitsPerSample))
    header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
    header.appendLittleEndian(dataSize)

    var output = Data(capacity: header.count + pcmBytes.count)
    output.append(header)
    output.append(pcmBytes)
    return output
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian(_ value: UInt32) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { buffer in
      append(contentsOf: buffer)
    }
  }
  fileprivate mutating func appendLittleEndian(_ value: UInt16) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { buffer in
      append(contentsOf: buffer)
    }
  }
}
