import Foundation

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Configuration for a single stop-motion frame.
struct StopMotionFrameConfig {
  /// The encoded image bytes (PNG/JPEG/etc.) for this frame.
  let imageData: Data

  /// How long this frame is held on screen, in microseconds.
  /// When `nil`, the default frame duration (`1 / frameRate`) is used.
  let durationUs: Int64?

  static func fromArguments(_ args: [String: Any]?) -> StopMotionFrameConfig? {
    guard let args = args else { return nil }

    let imageData: Data?
    if let flutterData = args["imageData"] as? FlutterStandardTypedData {
      imageData = flutterData.data
    } else {
      imageData = args["imageData"] as? Data
    }

    guard let imageData = imageData, !imageData.isEmpty else { return nil }

    return StopMotionFrameConfig(
      imageData: imageData,
      durationUs: (args["durationUs"] as? NSNumber)?.int64Value
    )
  }
}

/// Configuration for rendering a stop-motion video from a sequence of images.
struct StopMotionConfig {
  /// Unique task id, used for progress and cancellation.
  let id: String

  /// Ordered list of frames to encode.
  let frames: [StopMotionFrameConfig]

  /// Default number of frames shown per second.
  let frameRate: Double

  /// Target output width in pixels. When `nil`, the first frame's width is used.
  let width: Int?

  /// Target output height in pixels. When `nil`, the first frame's height is used.
  let height: Int?

  /// How each frame maps onto the output size: "contain", "cover", or "stretch".
  let fit: String

  /// Output format for the rendered video (e.g., "mp4", "mov").
  let outputFormat: String

  /// Optional absolute path where output should be saved (nil = return bytes).
  let outputPath: String?

  /// Target bitrate in bits per second (nil = auto).
  let bitrate: Int?

  static func fromArguments(_ arguments: [String: Any]?) -> StopMotionConfig? {
    guard let args = arguments,
      let id = args["id"] as? String, !id.isEmpty
    else { return nil }

    var frames: [StopMotionFrameConfig] = []
    if let framesRaw = args["frames"] as? [[String: Any]] {
      frames = framesRaw.compactMap { StopMotionFrameConfig.fromArguments($0) }
    }

    guard !frames.isEmpty else { return nil }

    return StopMotionConfig(
      id: id,
      frames: frames,
      frameRate: (args["frameRate"] as? NSNumber)?.doubleValue ?? 12.0,
      width: (args["width"] as? NSNumber)?.intValue,
      height: (args["height"] as? NSNumber)?.intValue,
      fit: args["fit"] as? String ?? "contain",
      outputFormat: args["outputFormat"] as? String ?? "mp4",
      outputPath: args["outputPath"] as? String,
      bitrate: (args["bitrate"] as? NSNumber)?.intValue
    )
  }
}
