import Foundation

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// A volume that changes over time on the exported video, moving in a
/// straight line from one point to the next — the Dart `AudioVolumeCurve`.
///
/// Before the first point the volume stays at the first point's, and after
/// the last one at the last point's.
struct VolumeCurve: Equatable {
  /// When each point sits on the exported video, in microseconds, sorted.
  let timesUs: [Int64]
  /// The volume of each point, from 0 to 1.
  let volumes: [Double]

  /// The volume at `timeUs`, exactly as the Dart `volumeAt` computes it.
  func volume(atUs timeUs: Double) -> Double {
    guard let firstTime = timesUs.first, let lastTime = timesUs.last else { return 1 }
    if timeUs <= Double(firstTime) { return volumes[0] }
    if timeUs >= Double(lastTime) { return volumes[volumes.count - 1] }
    var low = 0
    var high = timesUs.count - 1
    while high - low > 1 {
      let middle = (low + high) / 2
      if Double(timesUs[middle]) <= timeUs { low = middle } else { high = middle }
    }
    let span = Double(timesUs[high] - timesUs[low])
    if span <= 0 { return volumes[high] }
    let t = (timeUs - Double(timesUs[low])) / span
    return volumes[low] + (volumes[high] - volumes[low]) * t
  }

  /// The stretches of time, in microseconds, where the volume is below 1,
  /// merged and sorted; unbounded ends are `Int64.min` and `Int64.max`.
  /// Everything outside them is left as it is.
  func loweredRangesUs() -> [ClosedRange<Int64>] {
    var ranges: [ClosedRange<Int64>] = []
    func add(_ from: Int64, _ to: Int64) {
      // Dart sorts the points; this only keeps others from trapping.
      guard from <= to else { return }
      if let last = ranges.last, from <= last.upperBound {
        ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, to)
      } else {
        ranges.append(from...to)
      }
    }
    if volumes[0] < 1 { add(.min, timesUs[0]) }
    for i in 0..<(timesUs.count - 1) where volumes[i] < 1 || volumes[i + 1] < 1 {
      add(timesUs[i], timesUs[i + 1])
    }
    if volumes[volumes.count - 1] < 1 { add(timesUs[timesUs.count - 1], .max) }
    return ranges
  }

  /// Parses the `volumeCurve` entry of an audio track: interleaved
  /// `[time in µs, volume, …]` from a Dart `Float64List`, or a plain list of
  /// numbers. Nil when there is no curve or no complete point. A point whose
  /// time does not fit in microseconds is dropped, and a volume that is not a
  /// number leaves the audio unchanged.
  static func from(_ value: Any?) -> VolumeCurve? {
    let raw: [Double]
    if let typed = value as? FlutterStandardTypedData {
      raw = typed.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    } else if let list = value as? [NSNumber] {
      raw = list.map { $0.doubleValue }
    } else {
      return nil
    }
    var timesUs: [Int64] = []
    var volumes: [Double] = []
    for point in 0..<(raw.count / 2) {
      guard let time = Int64(exactly: raw[point * 2].rounded()) else { continue }
      let volume = raw[point * 2 + 1]
      timesUs.append(time)
      volumes.append(volume.isNaN ? 1 : min(max(volume, 0), 1))
    }
    if timesUs.isEmpty { return nil }
    return VolumeCurve(timesUs: timesUs, volumes: volumes)
  }
}
