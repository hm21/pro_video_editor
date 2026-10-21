import Accelerate
import Foundation

/// Pitch-preserving WSOLA on interleaved int16 PCM. All channels share the
/// alignment search, including opposite-phase stereo that cancels in mono.
internal enum AudioTimeStretch {
  /// Stretches the source, rendering at most `maxFrames`; working memory is
  /// one overlapping frame and its search range.
  ///
  /// The first frame starts on the first source sample at full level, so the
  /// sound starts at once. With `loop` the source repeats without end and
  /// exactly `maxFrames` are rendered: each seam is stretched like the rest
  /// of the sound, while looping a stretched copy would leave a gap at every
  /// seam. The sums run in vDSP, which keeps a long looped body fast in debug
  /// builds too.
  static func stretch(
    _ pcm: Data, sampleRate: Int, channels: Int, speed: Double, maxFrames: Int,
    loop: Bool = false
  ) -> Data {
    precondition(speed.isFinite && speed > 0 && sampleRate > 0 && channels > 0)
    if speed == 1 { return pcm }
    let sourceFrames = pcm.count / (channels * 2)
    if sourceFrames == 0 { return Data() }
    let outputFrames =
      loop ? maxFrames : Int(min(ceil(Double(sourceFrames) / speed), Double(maxFrames)))
    if outputFrames <= 0 { return Data() }
    let frame = max(4, Int((Double(sampleRate) * 0.03).rounded()) & ~1)
    let hop = frame / 2
    let tolerance = min(hop - 1, Int((Double(sampleRate) * 0.008).rounded()))
    let stride = max(1, sampleRate / 16000)
    let terms = vDSP_Length((hop + stride - 1) / stride)
    let coarseStep = 4
    // Without a loop no frame reads past the end, where its silence would
    // leave a dip just before the sound stops.
    let end = loop ? Int.max : max(0, sourceFrames - frame)
    // Periodic Hann: two windows half a frame apart add up to exactly 1.
    let window = (0..<frame).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frame)) }
    // Nothing overlaps the first half of the first frame.
    let firstWindow = (0..<frame).map { $0 < hop ? 1 : window[$0] }
    var accumulator = [Double](repeating: 0, count: frame * channels)
    var candidates = [Double](repeating: 0, count: (2 * tolerance + frame) * channels)
    var target = [Double](repeating: 0, count: hop * channels)
    var output = Data(count: outputFrames * channels * 2)
    var low = Double(Int16.min)
    var high = Double(Int16.max)
    pcm.withUnsafeBytes { raw in
      let source = raw.bindMemory(to: Int16.self).baseAddress!
      /// Reads `count` frames from `start` into `buffer`: silence past the
      /// end of the source or, with `loop`, its start again.
      func read(_ start: Int, _ count: Int, into buffer: UnsafeMutablePointer<Double>) {
        var filled = 0
        while filled < count {
          let index = loop ? (start + filled) % sourceFrames : start + filled
          if index >= sourceFrames {
            vDSP_vclrD(buffer + filled * channels, 1, vDSP_Length((count - filled) * channels))
            return
          }
          let length = min(count - filled, sourceFrames - index)
          vDSP_vflt16D(
            source + index * channels, 1, buffer + filled * channels, 1,
            vDSP_Length(length * channels))
          filled += length
        }
      }
      output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: Int16.self).baseAddress!
        accumulator.withUnsafeMutableBufferPointer { accumulatorBuffer in
          candidates.withUnsafeMutableBufferPointer { candidateBuffer in
            target.withUnsafeMutableBufferPointer { targetBuffer in
              let sum = accumulatorBuffer.baseAddress!
              let found = candidateBuffer.baseAddress!
              let wanted = targetBuffer.baseAddress!
              let interleaved = vDSP_Stride(channels)
              var previous = 0
              var outStart = 0
              while outStart < outputFrames {
                var position = 0
                var lowest = 0
                if outStart == 0 {
                  read(0, frame, into: found)
                } else {
                  let nominal = min(Int((Double(outStart) * speed).rounded()), end)
                  lowest = max(0, nominal - tolerance)
                  let highest = min(nominal + tolerance, end)
                  read(lowest, highest - lowest + frame, into: found)
                  read(previous + hop, hop, into: wanted)
                  func correlation(_ candidate: Int) -> Double {
                    var total = 0.0
                    for channel in 0..<channels {
                      var part = 0.0
                      vDSP_dotprD(
                        wanted + channel, vDSP_Stride(stride * channels),
                        found + (candidate - lowest) * channels + channel,
                        vDSP_Stride(stride * channels), &part, terms)
                      total += part
                    }
                    return total
                  }
                  // Ties, e.g. in silence, keep the nominal position.
                  var best = nominal
                  var bestScore = correlation(nominal)
                  var candidate = lowest
                  while candidate <= highest {
                    let score = correlation(candidate)
                    if score > bestScore {
                      bestScore = score
                      best = candidate
                    }
                    candidate += coarseStep
                  }
                  let first = max(best - coarseStep + 1, lowest)
                  let last = min(best + coarseStep - 1, highest)
                  for candidate in first...last {
                    let score = correlation(candidate)
                    if score > bestScore {
                      bestScore = score
                      best = candidate
                    }
                  }
                  position = best
                }
                let weights = outStart == 0 ? firstWindow : window
                let frameStart = found + (position - lowest) * channels
                for channel in 0..<channels {
                  vDSP_vmaD(
                    frameStart + channel, interleaved, weights, 1, sum + channel, interleaved,
                    sum + channel, interleaved, vDSP_Length(frame))
                }
                // The first hop is complete: clip, round and emit it, then
                // move the second half of the frame forward.
                let count = vDSP_Length(min(outputFrames - outStart, hop) * channels)
                vDSP_vclipD(sum, 1, &low, &high, sum, 1, count)
                vDSP_vfixr16D(sum, 1, destination + outStart * channels, 1, count)
                memcpy(sum, sum + hop * channels, hop * channels * MemoryLayout<Double>.size)
                vDSP_vclrD(sum + hop * channels, 1, vDSP_Length(hop * channels))
                previous = position
                outStart += hop
              }
            }
          }
        }
      }
    }
    return output
  }
}
