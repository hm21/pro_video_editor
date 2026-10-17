import AVFoundation
import Foundation

/// Renders a clip's sound along its speed ramp into a CAF/PCM temp file that
/// the composition inserts as it plays, with no time scaling.
///
/// AVFoundation drops tens of milliseconds of sound around time-scaled audio
/// edits: measured on iOS and macOS, a constant-speed clip loses about 40–80
/// ms shortly after its start and a ramp's hundred-odd scaled steps lose
/// several such stretches. A ramp's sound follows the speed like a tape, so
/// it is a resample at a varying rate, and this one is exact: output frame
/// `i` plays the source moment the picture's steps put at `i / sampleRate`.
///
/// Mirrors what Android's `SpeedChangingAudioProcessor` plays.
internal enum RampAudioRenderer {

  /// A rendered ramp sound. The caller MUST delete [outputURL] once the
  /// render has finished.
  struct Result {
    let outputURL: URL
    let duration: CMTime
  }

  /// Decodes `[startTime, endTime)` of `inputPath`, resamples it along
  /// [ramp] so it lasts [outputDuration], and writes it to a temporary
  /// CAF/PCM file in the source's own sample rate and channel layout.
  ///
  /// Returns `nil` when the source has no usable audio or a step fails, so
  /// the caller can fall back to scaling the source instead.
  static func render(
    inputPath: String,
    startTime: CMTime,
    endTime: CMTime,
    ramp: SpeedRamp,
    outputDuration: CMTime
  ) async -> Result? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
    let audioTracks: [AVAssetTrack]
    if #available(iOS 15.0, macOS 13.0, *) {
      audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    } else {
      audioTracks = asset.tracks(withMediaType: .audio)
    }
    guard let audioTrack = audioTracks.first else { return nil }

    var sampleRate: Double = 44100
    var channelCount = 2
    let formatDescriptions: [CMFormatDescription]
    if #available(iOS 15.0, macOS 13.0, *) {
      formatDescriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
    } else {
      formatDescriptions = audioTrack.formatDescriptions as! [CMFormatDescription]
    }
    if let description = formatDescriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    {
      if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
      if asbd.mChannelsPerFrame > 0 { channelCount = Int(asbd.mChannelsPerFrame) }
    }

    let segmentDuration = CMTimeSubtract(endTime, startTime)
    guard segmentDuration > .zero, outputDuration > .zero else { return nil }

    let pcm: Data
    do {
      pcm = try await AudioReverser.readPcm(
        from: asset,
        track: audioTrack,
        start: startTime,
        duration: segmentDuration,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: channelCount,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
    } catch {
      PluginLog.print("⚠️ RampAudioRenderer: PCM decode failed: \(error)")
      return nil
    }

    let outputFrames = Int((outputDuration.seconds * sampleRate).rounded())
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "ramp_audio_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).caf")
    do {
      // Read in place: a slowed clip's sound is several times its source, so
      // only one slice of it is held next to the source at a time.
      let written = try pcm.withUnsafeBytes { raw -> Bool in
        let source = raw.bindMemory(to: Int16.self)
        guard source.count / channelCount > 1, outputFrames > 0 else { return false }
        try write(
          source,
          channelCount: channelCount,
          ramp: ramp,
          sourceSeconds: segmentDuration.seconds,
          sampleRate: sampleRate,
          outputFrames: outputFrames,
          to: outputURL)
        return true
      }
      guard written else { return nil }
    } catch {
      PluginLog.print("⚠️ RampAudioRenderer: CAF write failed: \(error)")
      try? FileManager.default.removeItem(at: outputURL)
      return nil
    }

    let duration = CMTime(value: CMTimeValue(outputFrames), timescale: CMTimeScale(sampleRate))
    PluginLog.print(
      "⏩ RampAudioRenderer: \(segmentDuration.seconds)s of sound along \(ramp.steps.count) step(s) → \(duration.seconds)s"
    )
    return Result(outputURL: outputURL, duration: duration)
  }

  /// Output frames the renderer resamples and writes at a time.
  private static let sliceFrames = 1 << 16

  /// Writes [source] resampled along [ramp] into [outputFrames] frames of
  /// 16-bit CAF/PCM at [url], one slice at a time.
  private static func write(
    _ source: UnsafeBufferPointer<Int16>,
    channelCount: Int,
    ramp: SpeedRamp,
    sourceSeconds: Double,
    sampleRate: Double,
    outputFrames: Int,
    to url: URL
  ) throws {
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Int(sampleRate),
        AVNumberOfChannelsKey: channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ],
      commonFormat: .pcmFormatInt16,
      interleaved: true)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sliceFrames))
    else {
      throw NSError(
        domain: "RampAudioRenderer", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
    }
    let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard buffers.count == 1, let destination = buffers[0].mData else {
      throw NSError(
        domain: "RampAudioRenderer", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Unexpected PCM buffer layout"])
    }

    var frame = 0
    while frame < outputFrames {
      let count = min(sliceFrames, outputFrames - frame)
      let samples = resample(
        source,
        channelCount: channelCount,
        ramp: ramp,
        sourceSeconds: sourceSeconds,
        sampleRate: sampleRate,
        frames: frame..<(frame + count))
      buffer.frameLength = AVAudioFrameCount(count)
      samples.withUnsafeBytes { bytes in
        buffers[0].mDataByteSize = UInt32(bytes.count)
        if let base = bytes.baseAddress {
          destination.copyMemory(from: base, byteCount: bytes.count)
        }
      }
      try file.write(from: buffer)
      frame += count
    }
  }

  /// Output [frames] of [source] (interleaved frames of [channelCount]
  /// samples) resampled along [ramp].
  ///
  /// Each output frame reads the source at the moment the ramp plays then,
  /// between two source frames by linear interpolation. Where the ramp speeds
  /// up it averages the source across the stretch one output frame covers,
  /// which keeps the frequencies a faster play would fold back from turning
  /// into audible noise. Past the end of [source], as when the audio track
  /// ends a little before the picture, it is silent.
  static func resample(
    _ source: UnsafeBufferPointer<Int16>,
    channelCount: Int,
    ramp: SpeedRamp,
    sourceSeconds: Double,
    sampleRate: Double,
    frames: Range<Int>
  ) -> [Int16] {
    guard channelCount > 0, !frames.isEmpty, !ramp.steps.isEmpty else { return [] }
    let sourceFrames = source.count / channelCount
    var output = [Int16](repeating: 0, count: frames.count * channelCount)
    guard sourceFrames > 0 else { return output }
    let lastFrame = Double(sourceFrames - 1)

    func sample(_ frame: Double, _ channel: Int) -> Double {
      guard frame <= lastFrame else { return 0 }
      let clamped = max(frame, 0)
      let low = Int(clamped)
      let high = min(low + 1, sourceFrames - 1)
      let mix = clamped - Double(low)
      return Double(source[low * channelCount + channel]) * (1 - mix)
        + Double(source[high * channelCount + channel]) * mix
    }

    var stepIndex = 0
    var stepOutputStart = 0.0
    let steps = ramp.steps
    for frame in frames {
      let time = Double(frame) / sampleRate
      // The step playing at [time], walking forward as time advances.
      while stepIndex < steps.count - 1 {
        let step = steps[stepIndex]
        let stepOutput = (step.end - step.start) * sourceSeconds / step.speed
        if time < stepOutputStart + stepOutput { break }
        stepOutputStart += stepOutput
        stepIndex += 1
      }
      let step = steps[stepIndex]
      let sourceTime = step.start * sourceSeconds + (time - stepOutputStart) * step.speed
      let center = sourceTime * sampleRate
      let taps = step.speed > 1 ? Int(step.speed.rounded(.up)) + 1 : 1
      let base = (frame - frames.lowerBound) * channelCount
      for channel in 0..<channelCount {
        var sum = 0.0
        for tap in 0..<taps {
          let offset =
            taps == 1 ? 0 : (Double(tap) / Double(taps - 1) - 0.5) * step.speed
          sum += sample(center + offset, channel)
        }
        let value = (sum / Double(taps)).rounded()
        output[base + channel] = Int16(clamping: Int(value))
      }
    }
    return output
  }
}
