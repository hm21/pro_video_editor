import Foundation

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Configuration for a single animation on an image layer.
struct LayerAnimationConfig {
  /// The kind of animation: "fade", "slide", or "scale".
  let type: String
  /// When the animation plays: "animateIn", "animateOut", or "animateInOut".
  let phase: String
  /// Duration in microseconds.
  let durationUs: Int64
  /// Easing curve: "linear", "easeIn", "easeOut", or "easeInOut".
  let curve: String
  /// Slide direction: "left", "right", "top", or "bottom". Only for slide animations.
  let slideDirection: String?
  /// Starting scale factor for scale animations (e.g. 0.0 = invisible, 0.5 = half size).
  let scaleFrom: Double?

  static func fromArguments(_ args: [String: Any]?) -> LayerAnimationConfig? {
    guard let args = args,
      let type = args["type"] as? String,
      let phase = args["phase"] as? String,
      let durationUs = (args["durationUs"] as? NSNumber)?.int64Value
    else { return nil }

    return LayerAnimationConfig(
      type: type,
      phase: phase,
      durationUs: durationUs,
      curve: args["curve"] as? String ?? "linear",
      slideDirection: args["slideDirection"] as? String,
      scaleFrom: (args["scaleFrom"] as? NSNumber)?.doubleValue
    )
  }
}

public struct ImageLayerConfig: Sendable {
  let imageData: Data
  let startUs: Int64
  /// endUs of -1 indicates the image should be displayed until the end of the video.
  let endUs: Int64
  /// x position in pixels. When nil, the image is stretched to fill the video frame.
  let x: Int64?
  /// y position in pixels. When nil, the image is stretched to fill the video frame.
  let y: Int64?
  /// Target width in pixels. When nil, the image is used at its original width.
  let width: Double?
  /// Target height in pixels. When nil, the image is used at its original height.
  let height: Double?
  /// Animations to apply to this layer.
  let animations: [LayerAnimationConfig]

  static func fromArguments(_ args: [String: Any]?) -> ImageLayerConfig? {
    guard let args = args else { return nil }

    // Convert imageBytes from Flutter (FlutterStandardTypedData) to Data
    let imageData: Data?
    if let flutterData = args["imageData"] as? FlutterStandardTypedData {
      imageData = flutterData.data
    } else {
      imageData = args["imageData"] as? Data
    }

    // Return nil if imageData is missing or empty
    guard let imageData = imageData, !imageData.isEmpty else {
      return nil
    }

    // Parse animations array
    var animations: [LayerAnimationConfig] = []
    if let animsRaw = args["animations"] as? [[String: Any]] {
      animations = animsRaw.compactMap { LayerAnimationConfig.fromArguments($0) }
    }

    // Parse optional size
    let width = (args["width"] as? NSNumber)?.doubleValue
    let height = (args["height"] as? NSNumber)?.doubleValue

    // Use -1 as sentinel value for "from start" when startUs is null
    // Use -1 for endUs to signify "until the end of the video"
    return ImageLayerConfig(
      imageData: imageData,
      startUs: (args["startUs"] as? NSNumber)?.int64Value ?? -1,
      endUs: (args["endUs"] as? NSNumber)?.int64Value ?? -1,
      x: (args["x"] as? NSNumber)?.int64Value,
      y: (args["y"] as? NSNumber)?.int64Value,
      width: width,
      height: height,
      animations: animations
    )
  }
}

/// Configuration for a color filter with an optional time range.
public struct ColorFilterConfig: Sendable {
  let matrix: [Double]
  /// startUs of -1 means the filter applies from the start of the video.
  let startUs: Int64
  /// endUs of -1 means the filter applies until the end of the video.
  let endUs: Int64

  static func fromArguments(_ args: [String: Any]?) -> ColorFilterConfig? {
    guard let args = args,
      let matrixRaw = args["matrix"] as? [NSNumber]
    else { return nil }
    let matrix = matrixRaw.map { $0.doubleValue }
    guard !matrix.isEmpty else { return nil }
    return ColorFilterConfig(
      matrix: matrix,
      startUs: (args["startUs"] as? NSNumber)?.int64Value ?? -1,
      endUs: (args["endUs"] as? NSNumber)?.int64Value ?? -1
    )
  }
}

/// Configuration for a custom audio track with timing and volume.
struct AudioTrackConfig {
  let path: String
  let volume: Float
  let loop: Bool
  /// Start offset within the audio file in microseconds.
  let audioStartUs: Int64?
  /// End offset within the audio file in microseconds.
  let audioEndUs: Int64?
  /// When to start playing in the composition timeline. -1 means from the start.
  let startUs: Int64
  /// When to stop playing in the composition timeline. -1 means until the end.
  let endUs: Int64
  /// Equal-power crossfade length (ms) applied at the loop seam so the
  /// rendered file loops seamlessly. 0 disables it.
  let crossfadeMillis: Double

  static func fromArguments(_ args: [String: Any]?) -> AudioTrackConfig? {
    guard let args = args,
      let path = args["path"] as? String, !path.isEmpty
    else { return nil }
    return AudioTrackConfig(
      path: path,
      volume: (args["volume"] as? NSNumber)?.floatValue ?? 1.0,
      loop: args["loop"] as? Bool ?? true,
      audioStartUs: (args["audioStartUs"] as? NSNumber)?.int64Value,
      audioEndUs: (args["audioEndUs"] as? NSNumber)?.int64Value,
      startUs: (args["startUs"] as? NSNumber)?.int64Value ?? -1,
      endUs: (args["endUs"] as? NSNumber)?.int64Value ?? -1,
      crossfadeMillis: (args["crossfadeMillis"] as? NSNumber)?.doubleValue ?? 0
    )
  }
}

/// Configuration model for video rendering operations.
///
/// This struct encapsulates all parameters required for rendering a video with
/// effects, transformations, and audio mixing. It supports both single-video
/// and multi-video rendering with comprehensive effect options.
struct RenderConfig: Sendable {
  /// List of video clips to render (concatenated in order)
  let videoClips: [VideoClip]

  /// Optional list of image layers to overlay at specified time intervals.
  let imageLayers: [ImageLayerConfig]

  /// Output format for the rendered video (e.g., "mp4", "mov")
  let outputFormat: String

  /// Optional absolute path where output should be saved (nil = return bytes)
  let outputPath: String?

  /// Number of 90-degree clockwise rotations to apply (0-3)
  let rotateTurns: Int?

  /// Whether to flip video horizontally
  let flipX: Bool

  /// Whether to flip video vertically
  let flipY: Bool

  /// Crop width in pixels (nil = no crop)
  let cropWidth: Int?

  /// Crop height in pixels (nil = no crop)
  let cropHeight: Int?

  /// Crop X offset in pixels (nil = centered)
  let cropX: Int?

  /// Crop Y offset in pixels (nil = centered)
  let cropY: Int?

  /// Horizontal scale factor (nil = no scaling)
  let scaleX: Float?

  /// Vertical scale factor (nil = no scaling)
  let scaleY: Float?

  /// Target bitrate in bits per second (nil = auto)
  let bitrate: Int?

  /// Whether to include audio in output
  let enableAudio: Bool

  /// Playback speed multiplier (e.g., 2.0 = 2x speed)
  let playbackSpeed: Float?

  /// List of color filters with optional time ranges
  let colorFilters: [ColorFilterConfig]

  /// List of audio tracks with timing, volume and looping configuration
  let audioTracks: [AudioTrackConfig]

  /// Blur radius (nil = no blur, experimental feature)
  let blur: Double?

  /// Global start time in microseconds for trimming the final composition
  let startUs: Int64?

  /// Global end time in microseconds for trimming the final composition
  let endUs: Int64?

  /// Whether to optimize the video for network streaming (fast start).
  /// When true, moves the moov atom to the beginning of the file.
  let shouldOptimizeForNetworkUse: Bool

  /// Whether to apply cropping to the image overlay along with the video.
  /// When true, the image overlay is cropped together with the video.
  /// When false (default), the overlay is scaled to the final cropped size.
  let imageBytesWithCropping: Bool

  /// Returns a copy of this config with the specified fields replaced.
  /// Fields not provided retain their current values.
  func copyWith(
    videoClips: [VideoClip]? = nil
  ) -> RenderConfig {
    return RenderConfig(
      videoClips: videoClips ?? self.videoClips,
      imageLayers: self.imageLayers,
      outputFormat: self.outputFormat,
      outputPath: self.outputPath,
      rotateTurns: self.rotateTurns,
      flipX: self.flipX,
      flipY: self.flipY,
      cropWidth: self.cropWidth,
      cropHeight: self.cropHeight,
      cropX: self.cropX,
      cropY: self.cropY,
      scaleX: self.scaleX,
      scaleY: self.scaleY,
      bitrate: self.bitrate,
      enableAudio: self.enableAudio,
      playbackSpeed: self.playbackSpeed,
      colorFilters: self.colorFilters,
      audioTracks: self.audioTracks,
      blur: self.blur,
      startUs: self.startUs,
      endUs: self.endUs,
      shouldOptimizeForNetworkUse: self.shouldOptimizeForNetworkUse,
      imageBytesWithCropping: self.imageBytesWithCropping
    )
  }

  static func fromArguments(_ arguments: [String: Any]?) -> RenderConfig? {
    guard let args = arguments else {
      return nil
    }

    // Parse video clips (required for video rendering)
    var videoClips: [VideoClip] = []
    if let videoClipsRaw = args["videoClips"] as? [[String: Any]] {
      videoClips = videoClipsRaw.compactMap { clipMap in
        guard let inputPath = clipMap["inputPath"] as? String else {
          return nil
        }
        return VideoClip(
          inputPath: inputPath,
          startUs: (clipMap["startUs"] as? NSNumber)?.int64Value,
          endUs: (clipMap["endUs"] as? NSNumber)?.int64Value,
          volume: (clipMap["volume"] as? NSNumber)?.floatValue,
          playbackSpeed: (clipMap["playbackSpeed"] as? NSNumber)?.floatValue,
          reverseVideo: clipMap["reverseVideo"] as? Bool ?? false
        )
      }
    }

    // Parse color filters
    var colorFilters: [ColorFilterConfig] = []
    if let filtersRaw = args["colorFilters"] as? [[String: Any]] {
      colorFilters = filtersRaw.compactMap { filterMap in
        ColorFilterConfig.fromArguments(filterMap)
      }
    }

    // Parse audio tracks
    var audioTracks: [AudioTrackConfig] = []
    if let tracksRaw = args["audioTracks"] as? [[String: Any]] {
      audioTracks = tracksRaw.compactMap { trackMap in
        AudioTrackConfig.fromArguments(trackMap)
      }
    }

    // Parse image layers
    var imageLayers: [ImageLayerConfig] = []
    if let layersRaw = args["imageLayers"] as? [[String: Any]] {
      imageLayers = layersRaw.compactMap { layerMap in
        ImageLayerConfig.fromArguments(layerMap)
      }
    }

    return RenderConfig(
      videoClips: videoClips,
      imageLayers: imageLayers,
      outputFormat: args["outputFormat"] as? String ?? "mp4",
      outputPath: args["outputPath"] as? String,
      rotateTurns: args["rotateTurns"] as? Int,
      flipX: args["flipX"] as? Bool ?? false,
      flipY: args["flipY"] as? Bool ?? false,
      cropWidth: args["cropWidth"] as? Int,
      cropHeight: args["cropHeight"] as? Int,
      cropX: args["cropX"] as? Int,
      cropY: args["cropY"] as? Int,
      scaleX: (args["scaleX"] as? NSNumber)?.floatValue,
      scaleY: (args["scaleY"] as? NSNumber)?.floatValue,
      bitrate: args["bitrate"] as? Int,
      enableAudio: args["enableAudio"] as? Bool ?? true,
      playbackSpeed: (args["playbackSpeed"] as? NSNumber)?.floatValue,
      colorFilters: colorFilters,
      audioTracks: audioTracks,
      blur: (args["blur"] as? NSNumber)?.doubleValue,
      startUs: (args["startUs"] as? NSNumber)?.int64Value,
      endUs: (args["endUs"] as? NSNumber)?.int64Value,
      shouldOptimizeForNetworkUse: args["shouldOptimizeForNetworkUse"] as? Bool ?? true,
      imageBytesWithCropping: args["imageBytesWithCropping"] as? Bool ?? false
    )
  }
}
