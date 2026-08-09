import Foundation

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Configuration for a single stop-motion frame.
struct StopMotionFrameConfig {
  /// Where this frame's encoded image lives. A frame the caller has on disk
  /// arrives as a path and is read while it is encoded, so a long sequence
  /// never has to be held in memory all at once; only an in-memory source
  /// travels as bytes.
  let image: EncodedImage

  /// How long this frame is held on screen, in microseconds.
  /// When `nil`, the default frame duration (`1 / frameRate`) is used.
  let durationUs: Int64?

  static func fromArguments(_ args: [String: Any]?) -> StopMotionFrameConfig? {
    guard let args = args,
      let image = EncodedImage.from(args, pathKey: "imagePath", dataKey: "imageData")
    else { return nil }

    return StopMotionFrameConfig(
      image: image,
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

    // A frame that carries no usable image fails the whole config. Dropping it
    // would return a video one shot short and a frame duration too brief, with
    // nothing to say so — for a sequence of stills that is a corrupt result,
    // not a degraded one. Android's `StopMotionConfig` rejects it the same way.
    var frames: [StopMotionFrameConfig] = []
    for raw in args["frames"] as? [[String: Any]] ?? [] {
      guard let frame = StopMotionFrameConfig.fromArguments(raw) else { return nil }
      frames.append(frame)
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
