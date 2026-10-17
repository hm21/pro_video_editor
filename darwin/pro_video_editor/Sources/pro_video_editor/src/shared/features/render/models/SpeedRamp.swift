import Foundation

/// A speed that changes while a clip plays, as the Dart `VideoSpeedRamp` sends
/// it: back-to-back steps that each play one stretch of the clip at one speed.
///
/// Positions run from 0 at the clip's first frame to 1 at its last, in the
/// order the clip plays. Dart samples its smooth curve into these steps, so the
/// render and an editor's timeline share one mapping between source and
/// output time.
///
/// Mirrors the Android `SpeedRamp.kt`.
internal struct SpeedRamp: Equatable, Sendable {

  /// One stretch of the clip at one speed.
  struct Step: Equatable, Sendable {
    let start: Double
    let end: Double
    let speed: Double
  }

  /// Back-to-back steps from position 0 to 1.
  let steps: [Step]

  /// Parses the steps `VideoSegment.toAsyncMap` writes under `speedRamp`;
  /// `nil` when there are none or one of them is unusable.
  static func fromArguments(_ raw: Any?) -> SpeedRamp? {
    guard let list = raw as? [Any], !list.isEmpty else { return nil }
    var steps: [Step] = []
    for item in list {
      guard let map = item as? [String: Any],
        let start = (map["start"] as? NSNumber)?.doubleValue,
        let end = (map["end"] as? NSNumber)?.doubleValue,
        let speed = (map["speed"] as? NSNumber)?.doubleValue,
        speed > 0, speed.isFinite, end > start
      else { return nil }
      steps.append(Step(start: start, end: end, speed: speed))
    }
    return SpeedRamp(steps: steps)
  }

  /// How long the clip plays compared to its source.
  var durationFactor: Double { outputFraction(from: 0, to: 1) }

  /// How long the stretch from `from` to `to` plays, as a fraction of the
  /// clip's source length.
  func outputFraction(from: Double, to: Double) -> Double {
    var output = 0.0
    for step in steps {
      let start = max(step.start, from)
      let end = min(step.end, to)
      if end > start { output += (end - start) / step.speed }
    }
    return output
  }

  /// The position the clip reaches after playing `output` (a fraction of its
  /// source length) from its start.
  func position(afterOutput output: Double) -> Double {
    var remaining = max(0, output)
    for step in steps {
      let stepOutput = (step.end - step.start) / step.speed
      if remaining <= stepOutput { return step.start + remaining * step.speed }
      remaining -= stepOutput
    }
    return 1
  }

  /// The position from which the clip still plays `output` (a fraction of its
  /// source length) until its end.
  func position(beforeEndOutput output: Double) -> Double {
    var remaining = max(0, output)
    for step in steps.reversed() {
      let stepOutput = (step.end - step.start) / step.speed
      if remaining <= stepOutput { return step.end - remaining * step.speed }
      remaining -= stepOutput
    }
    return 0
  }

  /// The part of the ramp from `from` to `to`, stretched back onto 0...1:
  /// the ramp of a clip trimmed to that part of itself.
  func cropped(from: Double, to: Double) -> SpeedRamp? {
    let width = to - from
    guard width > 0 else { return nil }
    if from <= 0, to >= 1 { return self }
    var result: [Step] = []
    for step in steps {
      let start = max(step.start, from)
      let end = min(step.end, to)
      guard end > start else { continue }
      result.append(
        Step(
          start: (start - from) / width,
          end: end >= to ? 1 : (end - from) / width,
          speed: step.speed))
    }
    guard !result.isEmpty else { return nil }
    return SpeedRamp(steps: result)
  }

  /// Output duration of a clip whose source lasts `sourceDurationUs`.
  func outputDurationUs(sourceDurationUs: Int64) -> Int64 {
    Int64((Double(sourceDurationUs) * durationFactor).rounded())
  }

  /// The source microseconds at the end of a clip of `sourceDurationUs` that
  /// play in the last `outputUs` of it.
  func tailSourceUs(outputUs: Int64, sourceDurationUs: Int64) -> Int64 {
    guard sourceDurationUs > 0 else { return 0 }
    let start = position(beforeEndOutput: Double(outputUs) / Double(sourceDurationUs))
    return Int64(((1 - start) * Double(sourceDurationUs)).rounded())
  }

  /// The source microseconds at the start of a clip of `sourceDurationUs` that
  /// play in the first `outputUs` of it.
  func headSourceUs(outputUs: Int64, sourceDurationUs: Int64) -> Int64 {
    guard sourceDurationUs > 0 else { return 0 }
    let end = position(afterOutput: Double(outputUs) / Double(sourceDurationUs))
    return Int64((end * Double(sourceDurationUs)).rounded())
  }
}
