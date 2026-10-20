import Foundation

/// Pitch-preserving WSOLA on interleaved int16 PCM. All channels share the
/// alignment search, including opposite-phase stereo that cancels in mono.
internal enum AudioTimeStretch {
  /// Stretches the source before looping/fades. Only renders as far as the
  /// requested output slot; working memory is one overlapping frame.
  static func stretch(
    _ pcm: Data, sampleRate: Int, channels: Int, speed: Double, maxFrames: Int
  ) -> Data {
    precondition(speed.isFinite && speed > 0 && sampleRate > 0 && channels > 0)
    precondition(pcm.count % (channels * 2) == 0)
    if speed == 1 { return pcm }
    let sourceFrames = pcm.count / (channels * 2)
    let outputFrames = Int(min(ceil(Double(sourceFrames) / speed), Double(maxFrames)))
    if outputFrames <= 0 { return Data() }
    let frame = max(4, Int((Double(sampleRate) * 0.03).rounded()) & ~1)
    let hop = frame / 2
    let tolerance = min(hop - 1, Int((Double(sampleRate) * 0.008).rounded()))
    let stride = max(1, sampleRate / 16000)
    let coarseStep = 4
    let cropStart = Int((Double(frame) / speed).rounded())
    let cropEnd = cropStart + outputFrames
    let window = (0..<frame).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frame - 1)) }
    var accumulator = [Double](repeating: 0, count: frame * channels)
    var output = Data(count: outputFrames * channels * 2)
    pcm.withUnsafeBytes { raw in
      let source = raw.bindMemory(to: Int16.self)
      func sample(_ paddedFrame: Int, _ channel: Int) -> Double {
        let index = paddedFrame - frame
        return index >= 0 && index < sourceFrames
          ? Double(Int16(littleEndian: source[index * channels + channel])) : 0
      }
      output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: Int16.self)
        var previous = 0
        var outStart = 0
        while outStart < cropEnd {
          let nominal = Int((Double(outStart) * speed).rounded())
          var position = 0
          if outStart > 0 {
            func correlation(_ candidate: Int) -> Double {
              var sum = 0.0
              var index = 0
              while index < hop {
                for channel in 0..<channels {
                  sum +=
                    sample(previous + hop + index, channel) * sample(candidate + index, channel)
                }
                index += stride
              }
              return sum
            }
            var best = nominal
            var bestScore = -Double.infinity
            var delta = -tolerance
            while delta <= tolerance {
              let score = correlation(nominal + delta)
              if score > bestScore {
                bestScore = score
                best = nominal + delta
              }
              delta += coarseStep
            }
            let first = max(best - coarseStep + 1, nominal - tolerance)
            let last = min(best + coarseStep - 1, nominal + tolerance)
            for candidate in first...last {
              let score = correlation(candidate)
              if score > bestScore {
                bestScore = score
                best = candidate
              }
            }
            position = max(0, best)
          }
          for index in 0..<frame {
            for channel in 0..<channels {
              accumulator[index * channels + channel] +=
                window[index] * sample(position + index, channel)
            }
          }
          let first = max(cropStart, outStart)
          let last = min(cropEnd, outStart + hop)
          if first < last {
            for index in first..<last {
              for channel in 0..<channels {
                let value = accumulator[(index - outStart) * channels + channel].rounded()
                destination[(index - cropStart) * channels + channel] =
                  Int16(clamping: Int(value)).littleEndian
              }
            }
          }
          for index in 0..<(hop * channels) {
            accumulator[index] = accumulator[index + hop * channels]
            accumulator[index + hop * channels] = 0
          }
          previous = position
          outStart += hop
        }
      }
    }
    return output
  }
}
