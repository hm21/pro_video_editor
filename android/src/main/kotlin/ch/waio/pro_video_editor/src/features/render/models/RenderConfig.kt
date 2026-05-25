package ch.waio.pro_video_editor.src.features.render.models

import PACKAGE_TAG
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import io.flutter.plugin.common.MethodCall

/**
 * Represents a video clip segment with optional trimming.
 * 
 * @property inputPath Absolute path to video file
 * @property startUs Start time in microseconds (null = from beginning)
 * @property endUs End time in microseconds (null = until end)
 * @property volume Volume multiplier for this clip (null = unchanged, 0.0=mute, 1.0=original)
 * @property playbackSpeed Speed multiplier for this clip (null = unchanged, 0.5=half, 2.0=double)
 * @property reverseVideo Whether to render this clip backwards
 */
data class VideoClip(
    val inputPath: String,
    val startUs: Long?,
    val endUs: Long?,
    val volume: Float? = null,
    val playbackSpeed: Float? = null,
    val reverseVideo: Boolean = false
)

/**
 * Represents a color filter with optional time range.
 *
 * @property matrix 4x5 color transformation matrix (20 elements)
 * @property startUs Start time in microseconds when the filter should be active (null = from start)
 * @property endUs End time in microseconds when the filter should stop (null = until end)
 */
data class ColorFilterConfig(
    val matrix: List<Double>,
    val startUs: Long?,
    val endUs: Long?
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): ColorFilterConfig {
            @Suppress("UNCHECKED_CAST")
            val matrix = (map["matrix"] as? List<*>)?.map {
                (it as Number).toDouble()
            } ?: emptyList()
            return ColorFilterConfig(
                matrix = matrix,
                startUs = (map["startUs"] as? Number)?.toLong(),
                endUs = (map["endUs"] as? Number)?.toLong()
            )
        }
    }
}

/**
 * Represents a custom audio track with timing and volume configuration.
 *
 * @property path Absolute path to the audio file
 * @property volume Volume multiplier (0.0=silent, 1.0=unchanged, >1.0=amplified)
 * @property loop Whether to loop the audio if shorter than the video
 * @property audioStartUs Start offset within the audio file in microseconds
 * @property audioEndUs End offset within the audio file in microseconds (null = until end)
 * @property startUs Composition start time in microseconds (when in the video timeline this track starts)
 * @property endUs Composition end time in microseconds (when in the video timeline this track ends)
 */
data class AudioTrackConfig(
    val path: String,
    val volume: Float = 1.0f,
    val loop: Boolean = false,
    val audioStartUs: Long? = null,
    val audioEndUs: Long? = null,
    val startUs: Long? = null,
    val endUs: Long? = null
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): AudioTrackConfig {
            return AudioTrackConfig(
                path = map["path"] as String,
                volume = (map["volume"] as? Number)?.toFloat() ?: 1.0f,
                loop = map["loop"] as? Boolean ?: false,
                audioStartUs = (map["audioStartUs"] as? Number)?.toLong(),
                audioEndUs = (map["audioEndUs"] as? Number)?.toLong(),
                startUs = (map["startUs"] as? Number)?.toLong(),
                endUs = (map["endUs"] as? Number)?.toLong()
            )
        }
    }
}

/**
 * Represents a single animation configuration for an image layer.
 *
 * @property type The kind of animation: "fade", "slide", or "scale"
 * @property phase When the animation plays: "animateIn", "animateOut", or "animateInOut"
 * @property durationUs Duration of the animation in microseconds
 * @property curve Easing curve name (e.g. "linear", "easeIn", "bounceOut")
 * @property slideDirection Slide direction: "left", "right", "top", or "bottom"
 * @property scaleFrom Starting scale factor for scale animations
 */
data class LayerAnimationConfig(
    val type: String,
    val phase: String,
    val durationUs: Long,
    val curve: String = "linear",
    val slideDirection: String? = null,
    val scaleFrom: Double? = null
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): LayerAnimationConfig {
            return LayerAnimationConfig(
                type = map["type"] as String,
                phase = map["phase"] as String,
                durationUs = (map["durationUs"] as Number).toLong(),
                curve = map["curve"] as? String ?: "linear",
                slideDirection = map["slideDirection"] as? String,
                scaleFrom = (map["scaleFrom"] as? Number)?.toDouble()
            )
        }
    }
}

/**
 * Represents an image overlay layer with timing information.
 *
 * @property imageData The image data as a byte array
 * @property startUs Start time in microseconds when the layer should appear
 * @property endUs End time in microseconds when the layer should disappear (-1 = until end of video)
 * @property x Horizontal offset in pixels (null = stretch to fill)
 * @property y Vertical offset in pixels (null = stretch to fill)
 * @property width Target width in pixels (null = original width)
 * @property height Target height in pixels (null = original height)
 * @property animations List of animations to apply to this layer
 */
data class ImageLayer(
    val imageData: ByteArray,
    val startUs: Long,
    val endUs: Long,
    val x: Int? = null,
    val y: Int? = null,
    val width: Double? = null,
    val height: Double? = null,
    val animations: List<LayerAnimationConfig> = emptyList()
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as ImageLayer
        return imageData.contentEquals(other.imageData) &&
                startUs == other.startUs &&
                endUs == other.endUs &&
                x == other.x &&
                y == other.y &&
                width == other.width &&
                height == other.height &&
                animations == other.animations
    }

    override fun hashCode(): Int {
        var result = imageData.contentHashCode()
        result = 31 * result + startUs.hashCode()
        result = 31 * result + endUs.hashCode()
        result = 31 * result + (x?.hashCode() ?: 0)
        result = 31 * result + (y?.hashCode() ?: 0)
        result = 31 * result + (width?.hashCode() ?: 0)
        result = 31 * result + (height?.hashCode() ?: 0)
        result = 31 * result + animations.hashCode()
        return result
    }
}

data class RenderConfig(
    val videoClips: List<VideoClip>,
    val imageLayers: List<ImageLayer> = emptyList(),
    val outputFormat: String,
    val outputPath: String? = null,
    val rotateTurns: Int? = null,
    val flipX: Boolean = false,
    val flipY: Boolean = false,
    val cropWidth: Int? = null,
    val cropHeight: Int? = null,
    val cropX: Int? = null,
    val cropY: Int? = null,
    val scaleX: Float? = null,
    val scaleY: Float? = null,
    val bitrate: Int? = null,
    val enableAudio: Boolean = true,
    val playbackSpeed: Float? = null,
    val colorFilters: List<ColorFilterConfig> = emptyList(),
    val audioTracks: List<AudioTrackConfig> = emptyList(),
    val blur: Double? = null,
    /** Global start time in microseconds for trimming the final composition */
    val startUs: Long? = null,
    /** Global end time in microseconds for trimming the final composition */
    val endUs: Long? = null,
    /** Whether to optimize the video for network streaming (fast start). */
    val shouldOptimizeForNetworkUse: Boolean = true,
    /** Whether to apply cropping to the image overlay along with the video. */
    val imageBytesWithCropping: Boolean = false
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as RenderConfig
        return videoClips == other.videoClips &&
                imageLayers == other.imageLayers &&
                outputFormat == other.outputFormat &&
                outputPath == other.outputPath
    }

    override fun hashCode(): Int {
        var result = videoClips.hashCode()
        result = 31 * result + imageLayers.hashCode()
        result = 31 * result + outputFormat.hashCode()
        result = 31 * result + (outputPath?.hashCode() ?: 0)
        return result
    }

    companion object {
        /**
         * Creates a RenderConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing all render parameters
         * @throws IllegalArgumentException if required videoClips are missing or invalid
         */
        fun fromMethodCall(call: MethodCall): RenderConfig {
            // Parse video clips (required)
            val videoClipsRaw = call.argument<List<Map<String, Any>>>("videoClips")

            Log.d(PACKAGE_TAG, "Received videoClipsRaw: ${videoClipsRaw?.size ?: 0} clips")

            if (videoClipsRaw.isNullOrEmpty()) {
                throw IllegalArgumentException("videoClips is required and cannot be empty")
            }

            val videoClips: List<VideoClip> = videoClipsRaw.mapIndexed { index, clipMap ->
                val clip = VideoClip(
                    inputPath = clipMap["inputPath"] as String,
                    startUs = (clipMap["startUs"] as? Number)?.toLong(),
                    endUs = (clipMap["endUs"] as? Number)?.toLong(),
                    volume = (clipMap["volume"] as? Number)?.toFloat(),
                    playbackSpeed = (clipMap["playbackSpeed"] as? Number)?.toFloat(),
                    reverseVideo = clipMap["reverseVideo"] as? Boolean ?: false
                )
                Log.d(
                    PACKAGE_TAG,
                    "Clip $index: path=${clip.inputPath}, start=${clip.startUs}, end=${clip.endUs}, volume=${clip.volume}, speed=${clip.playbackSpeed}, reverse=${clip.reverseVideo}"
                )
                clip
            }

            // Parse image layers
            val imageLayersRaw = call.argument<List<Map<String, Any>>>("imageLayers")
            val imageLayers: List<ImageLayer> = imageLayersRaw?.mapNotNull { layerMap ->
                val imageData = layerMap["imageData"] as? ByteArray
                val startUs = (layerMap["startUs"] as? Number)?.toLong() ?: -1L
                val endUs = (layerMap["endUs"] as? Number)?.toLong() ?: -1L
                val x = (layerMap["x"] as? Number)?.toInt()
                val y = (layerMap["y"] as? Number)?.toInt()
                val width = (layerMap["width"] as? Number)?.toDouble()
                val height = (layerMap["height"] as? Number)?.toDouble()

                // Parse animations
                @Suppress("UNCHECKED_CAST")
                val animationsRaw = layerMap["animations"] as? List<Map<String, Any?>>
                val animations = animationsRaw?.map { LayerAnimationConfig.fromMap(it) } ?: emptyList()

                if (imageData == null || imageData.isEmpty()) {
                    null
                } else {
                    ImageLayer(imageData, startUs, endUs, x, y, width, height, animations)
                }
            } ?: emptyList()

            Log.d(PACKAGE_TAG, "Parsed ${imageLayers.size} image layer(s)")

            // Parse color filters
            @Suppress("UNCHECKED_CAST")
            val colorFiltersRaw = call.argument<List<Map<String, Any?>>>("colorFilters")
            val colorFilters = colorFiltersRaw?.map { ColorFilterConfig.fromMap(it) } ?: emptyList()
            Log.d(PACKAGE_TAG, "Parsed ${colorFilters.size} color filter(s)")

            // Parse audio tracks
            @Suppress("UNCHECKED_CAST")
            val audioTracksRaw = call.argument<List<Map<String, Any?>>>("audioTracks")
            val audioTracks = audioTracksRaw?.map { AudioTrackConfig.fromMap(it) } ?: emptyList()
            Log.d(PACKAGE_TAG, "Parsed ${audioTracks.size} audio track(s)")

            // Parse all other parameters
            return RenderConfig(
                videoClips = videoClips,
                imageLayers = imageLayers,
                outputFormat = call.argument<String>("outputFormat") ?: "mp4",
                outputPath = call.argument<String>("outputPath"),
                rotateTurns = call.argument<Number>("rotateTurns")?.toInt(),
                flipX = call.argument<Boolean>("flipX") ?: false,
                flipY = call.argument<Boolean>("flipY") ?: false,
                cropWidth = call.argument<Number>("cropWidth")?.toInt(),
                cropHeight = call.argument<Number>("cropHeight")?.toInt(),
                cropX = call.argument<Number>("cropX")?.toInt(),
                cropY = call.argument<Number>("cropY")?.toInt(),
                scaleX = call.argument<Number>("scaleX")?.toFloat(),
                scaleY = call.argument<Number>("scaleY")?.toFloat(),
                bitrate = call.argument<Number>("bitrate")?.toInt(),
                enableAudio = call.argument<Boolean>("enableAudio") ?: true,
                playbackSpeed = call.argument<Number>("playbackSpeed")?.toFloat(),
                colorFilters = colorFilters,
                audioTracks = audioTracks,
                blur = call.argument<Number>("blur")?.toDouble(),
                startUs = call.argument<Number?>("startUs")?.toLong(),
                endUs = call.argument<Number?>("endUs")?.toLong(),
                shouldOptimizeForNetworkUse = call.argument<Boolean>("shouldOptimizeForNetworkUse")
                    ?: true,
                imageBytesWithCropping = call.argument<Boolean>("imageBytesWithCropping") ?: false
            )
        }
    }
}
