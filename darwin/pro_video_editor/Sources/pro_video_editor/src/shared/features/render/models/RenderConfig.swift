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

/// Configuration for a transition played between a clip and the next one.
struct ClipTransitionConfig {
  /// Transition kind: "dissolve", "fadeToBlack", "fadeToWhite", "slide",
  /// "push" or "wipe".
  let type: String
  /// Transition duration in microseconds.
  let durationUs: Int64
  /// Easing curve: "linear", "easeIn", "easeOut", "easeInOut", …
  let curve: String
  /// Direction for directional transitions: "left", "right", "up", "down".
  let direction: String

  /// True when this transition overlaps and blends the two clips.
  var isOverlap: Bool {
    type == "dissolve" || type == "slide" || type == "push" || type == "wipe"
  }

  /// True when this transition dips through a solid color (no overlap).
  var isDip: Bool {
    type == "fadeToBlack" || type == "fadeToWhite"
  }

  static func fromArguments(_ args: [String: Any]?) -> ClipTransitionConfig? {
    guard let args = args,
      let type = args["type"] as? String,
      let durationUs = (args["durationUs"] as? NSNumber)?.int64Value
    else { return nil }
    return ClipTransitionConfig(
      type: type,
      durationUs: durationUs,
      curve: args["curve"] as? String ?? "linear",
      direction: args["direction"] as? String ?? "left"
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
  /// Clockwise rotation around the layer center, in radians.
  let rotation: Double
  /// Whether an animated image (GIF) repeats while the layer is visible.
  let loop: Bool
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
    let rotation = (args["rotation"] as? NSNumber)?.doubleValue ?? 0.0
    let loop = (args["loop"] as? Bool) ?? true

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
      rotation: rotation,
      loop: loop,
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

/// Configuration for removing a solid-colored background ("green screen").
///
/// Mirrors the Dart `ChromaKey` model and the Kotlin `ChromaKeyConfig`. The
/// keying math itself lives in `ApplyChromaKey.swift` and is byte-for-byte the
/// same formula the Android fragment shader runs.
public struct ChromaKeyConfig: Sendable, Equatable {
  /// The screen color to remove, as gamma-encoded RGB in 0...1.
  let keyR: Double
  let keyG: Double
  let keyB: Double
  /// Chroma-plane radius within which a pixel is removed completely.
  let similarity: Double
  /// Width of the soft ramp just beyond `similarity`.
  let smoothness: Double
  /// How strongly the key's color cast is pulled out of the remaining pixels.
  let spill: Double
  /// Solid background ARGB, or -1 when none (the sentinel convention used by
  /// `ColorFilterConfig.startUs`/`endUs`).
  let backgroundColor: Int64
  /// Background image bytes, or nil when none.
  let backgroundImageData: Data?

  /// Whether the keyed area is left transparent rather than filled.
  var isTransparent: Bool { backgroundColor == -1 && backgroundImageData == nil }

  /// The same key, but filling the removed area with opaque black.
  ///
  /// Used on the single-track path, where nothing sits underneath and the codec
  /// carries no alpha, so "transparent" has no meaning. Android does the same
  /// substitution in `applyChromaKey(flattenTransparency:)`.
  func withOpaqueBlackBackground() -> ChromaKeyConfig {
    ChromaKeyConfig(
      keyR: keyR, keyG: keyG, keyB: keyB,
      similarity: similarity, smoothness: smoothness, spill: spill,
      backgroundColor: Int64(0xFF00_0000), backgroundImageData: nil)
  }

  /// The key color projected onto the Cb/Cr chroma plane.
  var keyChroma: (cb: Double, cr: Double) {
    chromaOf(r: keyR, g: keyG, b: keyB)
  }

  /// The unit vector pointing from neutral toward the key hue, used to pull
  /// the key's cast back out during spill suppression. Zero for a neutral
  /// (gray) key color, which disables despill rather than dividing by zero.
  var keyDirection: (cb: Double, cr: Double) {
    let c = keyChroma
    let length = (c.cb * c.cb + c.cr * c.cr).squareRoot()
    guard length > 1e-5 else { return (0, 0) }
    return (c.cb / length, c.cr / length)
  }

  /// Stable identity for the compositor's color-cube cache.
  ///
  /// Deliberately not `hashValue`: Swift seeds its hashing per process, so a
  /// hash is not a safe cache key across the lifetime of a render, and the
  /// background image data is far too large to hash per frame.
  var cacheKey: String {
    return "\(keyR),\(keyG),\(keyB),\(similarity),\(smoothness),\(spill),"
      + "\(backgroundColor),\(backgroundImageFingerprint)"
  }

  /// Cheap content fingerprint of the background image.
  ///
  /// The byte count alone is not an identity — two different backgrounds that
  /// happen to be the same size would share a cache entry, and the second clip
  /// would render the first one's image. Mixing in the head and tail bytes
  /// separates them while staying O(1), which matters because `cacheKey` is
  /// evaluated per frame.
  private var backgroundImageFingerprint: String {
    guard let data = backgroundImageData, !data.isEmpty else { return "0" }
    let sampleSize = min(32, data.count)
    let head = data.prefix(sampleSize).reduce(into: UInt64(1_469_598_103_934_665_603)) {
      accumulator, byte in
      accumulator = (accumulator ^ UInt64(byte)) &* 1_099_511_628_211
    }
    let tail = data.suffix(sampleSize).reduce(into: UInt64(1_469_598_103_934_665_603)) {
      accumulator, byte in
      accumulator = (accumulator ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return "\(data.count)-\(head)-\(tail)"
  }

  static func fromArguments(_ args: [String: Any]?) -> ChromaKeyConfig? {
    guard let args = args,
      let keyColor = (args["keyColor"] as? NSNumber)?.int64Value
    else { return nil }

    let backgroundImageData: Data?
    if let flutterData = args["bgImageData"] as? FlutterStandardTypedData {
      backgroundImageData = flutterData.data.isEmpty ? nil : flutterData.data
    } else if let data = args["bgImageData"] as? Data, !data.isEmpty {
      backgroundImageData = data
    } else {
      backgroundImageData = nil
    }

    return ChromaKeyConfig(
      keyR: Double((keyColor >> 16) & 0xFF) / 255.0,
      keyG: Double((keyColor >> 8) & 0xFF) / 255.0,
      keyB: Double(keyColor & 0xFF) / 255.0,
      similarity: (args["similarity"] as? NSNumber)?.doubleValue ?? 0.20,
      smoothness: (args["smoothness"] as? NSNumber)?.doubleValue ?? 0.08,
      spill: (args["spill"] as? NSNumber)?.doubleValue ?? 0.5,
      backgroundColor: (args["bgColor"] as? NSNumber)?.int64Value ?? -1,
      backgroundImageData: backgroundImageData
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
      endUs: (args["endUs"] as? NSNumber)?.int64Value ?? -1
    )
  }
}

/// Placement and scaling of a video segment within the composition canvas.
struct SegmentTransformConfig: Sendable {
  /// Top-left x position in canvas pixels. `nil` = 0.
  let offsetX: Double?
  /// Top-left y position in canvas pixels. `nil` = 0.
  let offsetY: Double?
  /// Target width in canvas pixels. `nil` = source width.
  let width: Double?
  /// Target height in canvas pixels. `nil` = source height.
  let height: Double?
  /// How the source is scaled into the target size: "fill", "contain", "cover".
  let fit: String

  static func fromArguments(_ args: [String: Any]?) -> SegmentTransformConfig? {
    guard let args = args else { return nil }
    let offset = args["offset"] as? [String: Any]
    let size = args["size"] as? [String: Any]
    return SegmentTransformConfig(
      offsetX: (offset?["dx"] as? NSNumber)?.doubleValue,
      offsetY: (offset?["dy"] as? NSNumber)?.doubleValue,
      width: (size?["width"] as? NSNumber)?.doubleValue,
      height: (size?["height"] as? NSNumber)?.doubleValue,
      fit: args["fit"] as? String ?? "cover"
    )
  }
}

/// A single layer (track) of a multi-layer composition.
struct LayerConfig: Sendable {
  /// Time-ordered clips on this layer.
  let clips: [VideoClip]
  /// Opacity of the whole layer (0...1).
  let opacity: Float
  /// Default placement for clips without their own transform.
  let transform: SegmentTransformConfig?
  /// Default chroma key for the clips on this layer. A clip's own key wins;
  /// `nil` falls back to the global key.
  let chromaKey: ChromaKeyConfig?

  static func fromArguments(_ args: [String: Any]?) -> LayerConfig? {
    guard let args = args,
      let clipsRaw = args["clips"] as? [[String: Any]]
    else { return nil }
    let clips = clipsRaw.compactMap { VideoClip.fromMap($0) }
    guard !clips.isEmpty else { return nil }
    return LayerConfig(
      clips: clips,
      opacity: (args["opacity"] as? NSNumber)?.floatValue ?? 1.0,
      transform: SegmentTransformConfig.fromArguments(args["transform"] as? [String: Any]),
      chromaKey: ChromaKeyConfig.fromArguments(args["chromaKey"] as? [String: Any])
    )
  }
}

/// A multi-layer composition that stacks several tracks on a fixed canvas.
struct CompositionConfig: Sendable {
  /// Layers ordered bottom-to-top (last layer drawn on top).
  let layers: [LayerConfig]
  /// Output canvas width in pixels. `nil` = derive from the first clip.
  let canvasWidth: Double?
  /// Output canvas height in pixels. `nil` = derive from the first clip.
  let canvasHeight: Double?
  /// Background ARGB color filling areas not covered by any layer.
  let backgroundColor: Int64

  static func fromArguments(_ args: [String: Any]?) -> CompositionConfig? {
    guard let args = args,
      let layersRaw = args["layers"] as? [[String: Any]]
    else { return nil }
    let layers = layersRaw.compactMap { LayerConfig.fromArguments($0) }
    guard !layers.isEmpty else { return nil }
    return CompositionConfig(
      layers: layers,
      canvasWidth: (args["canvasWidth"] as? NSNumber)?.doubleValue,
      canvasHeight: (args["canvasHeight"] as? NSNumber)?.doubleValue,
      backgroundColor: (args["backgroundColor"] as? NSNumber)?.int64Value ?? Int64(0xFF00_0000)
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

  /// Optional multi-layer composition. When set, [videoClips] is empty and the
  /// layered render path is used instead of the single-track concatenation.
  let composition: CompositionConfig?

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

  /// Exact output canvas width in pixels (nil = derive from source/scale).
  /// When set, the video is scaled to fit inside the canvas (preserving aspect
  /// ratio), centered, and padded with black.
  let outputWidth: Int?

  /// Exact output canvas height in pixels (nil = derive from source/scale).
  let outputHeight: Int?

  /// The exact output canvas size, when both dimensions are provided.
  var outputResolution: CGSize? {
    guard let width = outputWidth, let height = outputHeight else { return nil }
    return CGSize(width: width, height: height)
  }

  /// Target bitrate in bits per second (nil = auto)
  let bitrate: Int?

  /// Upper limit for the output frame rate in fps (nil = keep source fps)
  let maxFrameRate: Int?

  /// Whether to include audio in output
  let enableAudio: Bool

  /// Whether to end each clip where both of its tracks still have content
  ///
  /// A source asset's audio and video tracks routinely end tens of
  /// milliseconds apart. Spanning the longer one leaves a tail of missing
  /// audio or a frozen frame, which a looping player replays as a seam.
  let trimToCommonTrackEnd: Bool

  /// Playback speed multiplier (e.g., 2.0 = 2x speed)
  let playbackSpeed: Float?

  /// List of color filters with optional time ranges
  let colorFilters: [ColorFilterConfig]

  /// List of audio tracks with timing, volume and looping configuration
  let audioTracks: [AudioTrackConfig]

  /// Blur radius (nil = no blur, experimental feature)
  let blur: Double?

  /// Removes a solid-colored background ("green screen") from every clip that
  /// does not carry its own key. A `VideoClip.chromaKey` overrides this, and in
  /// the layered path a `LayerConfig.chromaKey` sits between the two.
  let chromaKey: ChromaKeyConfig?

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
      composition: self.composition,
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
      outputWidth: self.outputWidth,
      outputHeight: self.outputHeight,
      bitrate: self.bitrate,
      maxFrameRate: self.maxFrameRate,
      enableAudio: self.enableAudio,
      trimToCommonTrackEnd: self.trimToCommonTrackEnd,
      playbackSpeed: self.playbackSpeed,
      colorFilters: self.colorFilters,
      audioTracks: self.audioTracks,
      blur: self.blur,
      chromaKey: self.chromaKey,
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

    // Parse video clips (single-track path)
    var videoClips: [VideoClip] = []
    if let videoClipsRaw = args["videoClips"] as? [[String: Any]] {
      videoClips = videoClipsRaw.compactMap { VideoClip.fromMap($0) }
    }

    // Parse multi-layer composition (layered path)
    let composition = CompositionConfig.fromArguments(args["composition"] as? [String: Any])

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
      composition: composition,
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
      outputWidth: (args["outputWidth"] as? NSNumber)?.intValue,
      outputHeight: (args["outputHeight"] as? NSNumber)?.intValue,
      bitrate: args["bitrate"] as? Int,
      maxFrameRate: (args["maxFrameRate"] as? NSNumber)?.intValue,
      enableAudio: args["enableAudio"] as? Bool ?? true,
      trimToCommonTrackEnd: args["trimToCommonTrackEnd"] as? Bool ?? false,
      playbackSpeed: (args["playbackSpeed"] as? NSNumber)?.floatValue,
      colorFilters: colorFilters,
      audioTracks: audioTracks,
      blur: (args["blur"] as? NSNumber)?.doubleValue,
      chromaKey: ChromaKeyConfig.fromArguments(args["chromaKey"] as? [String: Any]),
      startUs: (args["startUs"] as? NSNumber)?.int64Value,
      endUs: (args["endUs"] as? NSNumber)?.int64Value,
      shouldOptimizeForNetworkUse: args["shouldOptimizeForNetworkUse"] as? Bool ?? true,
      imageBytesWithCropping: args["imageBytesWithCropping"] as? Bool ?? false
    )
  }
}
