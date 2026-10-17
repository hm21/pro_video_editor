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

    let source: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let sourceFrames = source.count / channelCount
    guard sourceFrames > 1 else { return nil }

    let output = resample(
      source,
      channelCount: channelCount,
      ramp: ramp,
      sourceSeconds: segmentDuration.seconds,
      sampleRate: sampleRate,
      outputFrames: Int((outputDuration.seconds * sampleRate).rounded()))

    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "ramp_audio_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString).caf")
    do {
      let bytes = output.withUnsafeBytes { [UInt8]($0) }
      try AudioReverser.writeCAF(
        pcmBytes: bytes,
        to: outputURL,
        sampleRate: Int(sampleRate),
        channelCount: channelCount,
        bitsPerSample: 16)
    } catch {
      PluginLog.print("⚠️ RampAudioRenderer: CAF write failed: \(error)")
      return nil
    }

    let duration = CMTime(
      value: CMTimeValue(output.count / channelCount), timescale: CMTimeScale(sampleRate))
    PluginLog.print(
      "⏩ RampAudioRenderer: \(segmentDuration.seconds)s of sound along \(ramp.steps.count) step(s) → \(duration.seconds)s"
    )
    return Result(outputURL: outputURL, duration: duration)
  }

  /// [source] (interleaved frames of [channelCount] samples) resampled along
  /// [ramp] into [outputFrames] frames.
  ///
  /// Each output frame reads the source at the moment the ramp plays then,
  /// between two source frames by linear interpolation. Where the ramp speeds
  /// up it averages the source across the stretch one output frame covers,
  /// which keeps the frequencies a faster play would fold back from turning
  /// into audible noise.
  static func resample(
    _ source: [Int16],
    channelCount: Int,
    ramp: SpeedRamp,
    sourceSeconds: Double,
    sampleRate: Double,
    outputFrames: Int
  ) -> [Int16] {
    let sourceFrames = source.count / channelCount
    guard sourceFrames > 0, outputFrames > 0, channelCount > 0 else { return [] }
    var output = [Int16](repeating: 0, count: outputFrames * channelCount)

    func sample(_ frame: Double, _ channel: Int) -> Double {
      let clamped = min(max(frame, 0), Double(sourceFrames - 1))
      let low = Int(clamped)
      let high = min(low + 1, sourceFrames - 1)
      let mix = clamped - Double(low)
      return Double(source[low * channelCount + channel]) * (1 - mix)
        + Double(source[high * channelCount + channel]) * mix
    }

    var stepIndex = 0
    var stepOutputStart = 0.0
    let steps = ramp.steps
    for frame in 0..<outputFrames {
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
      for channel in 0..<channelCount {
        var sum = 0.0
        for tap in 0..<taps {
          let offset =
            taps == 1 ? 0 : (Double(tap) / Double(taps - 1) - 0.5) * step.speed
          sum += sample(center + offset, channel)
        }
        let value = (sum / Double(taps)).rounded()
        output[frame * channelCount + channel] = Int16(clamping: Int(value))
      }
    }
    return output
  }
}
