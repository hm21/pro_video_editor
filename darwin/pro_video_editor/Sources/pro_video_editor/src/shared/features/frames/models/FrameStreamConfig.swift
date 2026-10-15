import Foundation

/// Configuration for streaming decoded frames as raw luma.
struct FrameStreamConfig {
  /// Unique identifier of the task.
  let id: String

  /// The absolute file path to the video file.
  let inputPath: String

  /// First source timestamp to deliver, in microseconds; nil for the start.
  let startUs: Int64?

  /// Source timestamp to stop before, in microseconds; nil for the end.
  let endUs: Int64?

  /// Bounding box the upright frames are scaled into, keeping their aspect
  /// ratio.
  let outputWidth: Int

  /// Bounding box the upright frames are scaled into, keeping their aspect
  /// ratio.
  let outputHeight: Int

  /// Frames closer together than `1 / maxFrameRate` are skipped; nil keeps
  /// every frame.
  let maxFrameRate: Double?

  /// Creates a config from Flutter method call arguments, or nil when a
  /// required value is missing.
  static func fromArguments(_ arguments: [String: Any]?) -> FrameStreamConfig? {
    guard let args = arguments,
      let id = args["id"] as? String,
      let inputPath = args["inputPath"] as? String,
      let outputWidth = args["outputWidth"] as? Int,
      let outputHeight = args["outputHeight"] as? Int,
      outputWidth > 0, outputHeight > 0
    else {
      return nil
    }
    let maxFrameRate = (args["maxFrameRate"] as? NSNumber)?.doubleValue
    return FrameStreamConfig(
      id: id,
      inputPath: inputPath,
      startUs: (args["startUs"] as? NSNumber)?.int64Value,
      endUs: (args["endUs"] as? NSNumber)?.int64Value,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      maxFrameRate: (maxFrameRate ?? 0) > 0 ? maxFrameRate : nil
    )
  }
}
