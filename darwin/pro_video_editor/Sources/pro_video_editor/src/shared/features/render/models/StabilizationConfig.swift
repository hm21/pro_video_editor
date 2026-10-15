import Foundation

/// Per-frame transforms that steady a clip, keyed by source timestamp.
///
/// Mirrors the Dart `VideoStabilization`: for each keyframe, the frame is
/// scaled by `scale` and turned clockwise by `rotation` (radians) around its
/// center, then shifted by `dx`/`dy` (fractions of its width/height), in the
/// upright frame with the origin top left.
struct StabilizationConfig: Sendable {
  /// One interpolated keyframe.
  struct Transform: Equatable {
    let dx: Double
    let dy: Double
    let rotation: Double
    let scale: Double
  }

  let timesUs: [Int64]
  let values: [Double]

  /// Added to a frame's time in the file the clip reads to get the time the
  /// keyframes refer to. Non-zero once the clip reads a pre-transcode of only
  /// part of its source, whose timeline starts later.
  let sourceOffsetUs: Int64

  /// Parses the map written by the Dart `VideoStabilization.toMap`.
  static func fromArguments(_ map: [String: Any]?) -> StabilizationConfig? {
    guard let map,
      let times = (map["timesUs"] as? [NSNumber])?.map({ $0.int64Value }),
      let values = (map["values"] as? [NSNumber])?.map({ $0.doubleValue }),
      !times.isEmpty, values.count >= times.count * 4
    else { return nil }
    return StabilizationConfig(timesUs: times, values: values, sourceOffsetUs: 0)
  }

  /// This config for a clip whose frames now sit `deltaUs` earlier in the
  /// file it reads than in the source the keyframes were measured on.
  func shifted(by deltaUs: Int64) -> StabilizationConfig {
    StabilizationConfig(
      timesUs: timesUs, values: values, sourceOffsetUs: sourceOffsetUs + deltaUs)
  }

  /// The transform for the picture on screen at `fileUs` in the file the clip
  /// reads, whose frames are `frameUs` apart.
  ///
  /// That picture is the last frame that started at or before `fileUs`.
  /// Where two keyframes are no more than a frame apart, it is the earlier
  /// keyframe's own frame, so that keyframe applies unchanged — a render whose
  /// frame times fall between two source frames must not blend their
  /// corrections. Where they are further apart, the analysis skipped the
  /// frames between them (a `maxFrameRate` cap): the frame on screen is placed
  /// on the source's frame grid and its transform interpolated. Before the
  /// first and after the last keyframe the nearest one holds.
  func transform(atFileUs fileUs: Int64, frameUs: Int64) -> Transform {
    // A millisecond of slack absorbs rounding in the composition clock.
    let probe = fileUs + sourceOffsetUs + 1_000
    var lo = 0
    var hi = timesUs.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if timesUs[mid] <= probe { lo = mid + 1 } else { hi = mid }
    }
    let index = lo - 1
    if index < 0 { return keyframe(0) }
    if index >= timesUs.count - 1 { return keyframe(timesUs.count - 1) }
    let t0 = timesUs[index]
    let t1 = timesUs[index + 1]
    if frameUs <= 0 || 2 * (t1 - t0) <= 3 * frameUs { return keyframe(index) }
    let frameStartUs = t0 + (probe - t0) / frameUs * frameUs
    let k = min(1, max(0, Double(frameStartUs - t0) / Double(t1 - t0)))
    let a = keyframe(index)
    let b = keyframe(index + 1)
    return Transform(
      dx: a.dx + k * (b.dx - a.dx),
      dy: a.dy + k * (b.dy - a.dy),
      rotation: a.rotation + k * (b.rotation - a.rotation),
      scale: a.scale + k * (b.scale - a.scale))
  }

  private func keyframe(_ i: Int) -> Transform {
    Transform(
      dx: values[4 * i], dy: values[4 * i + 1],
      rotation: values[4 * i + 2], scale: values[4 * i + 3])
  }
}
