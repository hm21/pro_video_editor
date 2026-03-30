import Foundation
import FlutterMacOS

struct ImageLayerConfig {
    let imageData: Data
    let startUs: Int64
    /// endUs of -1 indicates the image should be displayed until the end of the video.
    let endUs: Int64
    let x: Int64
    let y: Int64

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

        // Use -1 as sentinel value for "from start" when startUs is null
        // Use -1 for endUs to signify "until the end of the video"
        return ImageLayerConfig(
            imageData: imageData,
            startUs: (args["startUs"] as? NSNumber)?.int64Value ?? -1,
            endUs: (args["endUs"] as? NSNumber)?.int64Value ?? -1,
            x: (args["x"] as? NSNumber)?.int64Value ?? 0,
            y: (args["y"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

/// Configuration model for video rendering operations.
///
/// This struct encapsulates all parameters required for rendering a video with
/// effects, transformations, and audio mixing. It supports both single-video
/// and multi-video rendering with comprehensive effect options.
struct RenderConfig {
    /// List of video clips to render (concatenated in order)
    let videoClips: [VideoClip]

    /// Optional image data for image-to-video conversion
    let imageData: Data?

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
    
    /// List of 4x4 color transformation matrices
    let colorMatrixList: [[Double]]
    
    /// Blur radius (nil = no blur, experimental feature)
    let blur: Double?
    
    /// Absolute path to custom audio file to mix in (nil = no custom audio)
    let customAudioPath: String?
    
    /// Start time offset in microseconds for the custom audio track
    let customAudioStartTimeUs: Int64?
    
    /// Volume for original video audio (0.0-1.0, nil = 1.0)
    let originalAudioVolume: Float?
    
    /// Volume for custom audio track (0.0-1.0, nil = 1.0)
    let customAudioVolume: Float?
    
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
    
    /// Whether to loop the custom audio if it is shorter than the video.
    /// When true (default), audio is repeated to match video duration.
    /// When false, audio plays once and silence fills the rest.
    let loopCustomAudio: Bool

    /// Returns a copy of this config with the specified fields replaced.
    /// Fields not provided retain their current values.
    func copyWith(
        videoClips: [VideoClip]? = nil
    ) -> RenderConfig {
        return RenderConfig(
            videoClips: videoClips ?? self.videoClips,
            imageData: self.imageData,
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
            colorMatrixList: self.colorMatrixList,
            blur: self.blur,
            customAudioPath: self.customAudioPath,
            customAudioStartTimeUs: self.customAudioStartTimeUs,
            originalAudioVolume: self.originalAudioVolume,
            customAudioVolume: self.customAudioVolume,
            startUs: self.startUs,
            endUs: self.endUs,
            shouldOptimizeForNetworkUse: self.shouldOptimizeForNetworkUse,
            imageBytesWithCropping: self.imageBytesWithCropping,
            loopCustomAudio: self.loopCustomAudio
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
                    endUs: (clipMap["endUs"] as? NSNumber)?.int64Value
                )
            }
        }

        // Parse color matrix list
        var colorMatrixList: [[Double]] = []
        if let matricesRaw = args["colorMatrixList"] as? [[NSNumber]] {
            colorMatrixList = matricesRaw.map { matrix in
                matrix.map { $0.doubleValue }
            }
        }
        
        // Convert imageBytes from Flutter (FlutterStandardTypedData) to Data
        let imageData: Data?
        if let flutterData = args["imageBytes"] as? FlutterStandardTypedData {
            imageData = flutterData.data
        } else {
            imageData = args["imageBytes"] as? Data
        }

        // Parse image layers
        // compactMap filters out nil values returned by fromArguments for invalid layers
        var imageLayers: [ImageLayerConfig] = []
        if let layersRaw = args["imageLayers"] as? [[String: Any]] {
            imageLayers = layersRaw.compactMap { layerMap in ImageLayerConfig.fromArguments(layerMap) }
        }

        return RenderConfig(
            videoClips: videoClips,
            imageData: imageData,
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
            colorMatrixList: colorMatrixList,
            blur: (args["blur"] as? NSNumber)?.doubleValue,
            customAudioPath: args["customAudioPath"] as? String,
            customAudioStartTimeUs: (args["customAudioStartTimeUs"] as? NSNumber)?.int64Value,
            originalAudioVolume: (args["originalAudioVolume"] as? NSNumber)?.floatValue,
            customAudioVolume: (args["customAudioVolume"] as? NSNumber)?.floatValue,
            startUs: (args["startUs"] as? NSNumber)?.int64Value,
            endUs: (args["endUs"] as? NSNumber)?.int64Value,
            shouldOptimizeForNetworkUse: args["shouldOptimizeForNetworkUse"] as? Bool ?? true,
            imageBytesWithCropping: args["imageBytesWithCropping"] as? Bool ?? false,
            loopCustomAudio: args["loopCustomAudio"] as? Bool ?? true
        )
    }
}
