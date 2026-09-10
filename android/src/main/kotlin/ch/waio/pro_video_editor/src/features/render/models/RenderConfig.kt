package ch.waio.pro_video_editor.src.features.render.models

import PACKAGE_TAG
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import io.flutter.plugin.common.MethodCall

/**
 * Represents the transition played between a clip and the next one.
 *
 * @property type Transition kind: "dissolve", "fadeToBlack", "fadeToWhite",
 *  "slide", "push" or "wipe"
 * @property durationUs Transition duration in microseconds
 * @property curve Easing curve name (e.g. "linear", "easeInOut")
 * @property direction Direction for directional transitions: "left", "right",
 *  "up" or "down"
 */
data class TransitionConfig(
    val type: String,
    val durationUs: Long,
    val curve: String = "linear",
    val direction: String = "left"
) {
    /** True when this transition overlaps and blends the two clips. */
    val isOverlap: Boolean
        get() = type == "dissolve" || type == "slide" || type == "push" ||
                type == "wipe"

    companion object {
        fun fromMap(map: Map<String, Any?>): TransitionConfig {
            return TransitionConfig(
                type = map["type"] as String,
                durationUs = (map["durationUs"] as Number).toLong(),
                curve = map["curve"] as? String ?: "linear",
                direction = map["direction"] as? String ?: "left"
            )
        }
    }
}

/**
 * Represents a video clip segment with optional trimming.
 *
 * @property inputPath Absolute path to video file
 * @property startUs Start time in microseconds (null = from beginning)
 * @property endUs End time in microseconds (null = until end)
 * @property volume Volume multiplier for this clip (null = unchanged, 0.0=mute, 1.0=original)
 * @property playbackSpeed Speed multiplier for this clip (null = unchanged, 0.5=half, 2.0=double)
 * @property reverseVideo Whether to render this clip backwards
 * @property transition Transition into the next clip (null = hard cut). On the
 *  **last** clip it wraps into the first clip, making the track loop seamlessly
 *  (see the wrap handling in RenderVideo/VideoSequenceBuilder).
 */
data class VideoClip(
    val inputPath: String,
    val startUs: Long?,
    val endUs: Long?,
    val volume: Float? = null,
    val playbackSpeed: Float? = null,
    val reverseVideo: Boolean = false,
    val transition: TransitionConfig? = null,
    /** Start position on the layer timeline in microseconds (composition only). */
    val timelineStartUs: Long? = null,
    /** Placement within the composition canvas (composition only). */
    val transform: SegmentTransformConfig? = null,
    /**
     * Removes a solid-colored background from this clip. Overrides the layer's
     * and the global key; null falls back to those.
     */
    val chromaKey: ChromaKeyConfig? = null,
    /**
     * Opts this clip out of the layer/global key entirely.
     *
     * Internal, never parsed from the platform channel. `chromaKey = null`
     * means "inherit", so it cannot express "deliberately unkeyed" — which is
     * exactly what a pre-rendered overlap blend needs when the two clips it was
     * composed from carry different keys. See `RenderVideo.blendChromaKey`.
     */
    val suppressChromaKey: Boolean = false
) {
    companion object {
        /** Parses a clip from a platform-channel map. */
        fun fromMap(clipMap: Map<String, Any?>): VideoClip {
            @Suppress("UNCHECKED_CAST")
            val transitionRaw = clipMap["transition"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val transformRaw = clipMap["transform"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val chromaKeyRaw = clipMap["chromaKey"] as? Map<String, Any?>
            return VideoClip(
                inputPath = clipMap["inputPath"] as String,
                startUs = (clipMap["startUs"] as? Number)?.toLong(),
                endUs = (clipMap["endUs"] as? Number)?.toLong(),
                volume = (clipMap["volume"] as? Number)?.toFloat(),
                playbackSpeed = (clipMap["playbackSpeed"] as? Number)?.toFloat(),
                reverseVideo = clipMap["reverseVideo"] as? Boolean ?: false,
                transition = transitionRaw?.let { TransitionConfig.fromMap(it) },
                timelineStartUs = (clipMap["timelineStartUs"] as? Number)?.toLong(),
                transform = transformRaw?.let { SegmentTransformConfig.fromMap(it) },
                chromaKey = ChromaKeyConfig.fromMap(chromaKeyRaw)
            )
        }
    }
}

/**
 * Placement and scaling of a video segment within the composition canvas.
 *
 * @property offsetX Top-left x position in canvas pixels (null = 0)
 * @property offsetY Top-left y position in canvas pixels (null = 0)
 * @property width Target width in canvas pixels (null = source width)
 * @property height Target height in canvas pixels (null = source height)
 * @property fit Scale mode: "fill", "contain" or "cover"
 */
data class SegmentTransformConfig(
    val offsetX: Double?,
    val offsetY: Double?,
    val width: Double?,
    val height: Double?,
    val fit: String
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): SegmentTransformConfig {
            @Suppress("UNCHECKED_CAST")
            val offset = map["offset"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val size = map["size"] as? Map<String, Any?>
            return SegmentTransformConfig(
                offsetX = (offset?.get("dx") as? Number)?.toDouble(),
                offsetY = (offset?.get("dy") as? Number)?.toDouble(),
                width = (size?.get("width") as? Number)?.toDouble(),
                height = (size?.get("height") as? Number)?.toDouble(),
                fit = map["fit"] as? String ?: "cover"
            )
        }
    }
}

/**
 * A single layer (track) of a multi-layer composition.
 *
 * @property clips Time-ordered clips on this layer
 * @property opacity Opacity of the whole layer (0..1)
 * @property transform Default placement for clips without their own transform
 */
data class LayerConfig(
    val clips: List<VideoClip>,
    val opacity: Float,
    val transform: SegmentTransformConfig?,
    /**
     * Default chroma key for the clips on this layer. A clip's own key wins;
     * null falls back to the global key.
     */
    val chromaKey: ChromaKeyConfig? = null
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): LayerConfig? {
            @Suppress("UNCHECKED_CAST")
            val clipsRaw = map["clips"] as? List<Map<String, Any?>> ?: return null
            val clips = clipsRaw.map { VideoClip.fromMap(it) }
            if (clips.isEmpty()) return null
            @Suppress("UNCHECKED_CAST")
            val transformRaw = map["transform"] as? Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val chromaKeyRaw = map["chromaKey"] as? Map<String, Any?>
            return LayerConfig(
                clips = clips,
                opacity = (map["opacity"] as? Number)?.toFloat() ?: 1.0f,
                transform = transformRaw?.let { SegmentTransformConfig.fromMap(it) },
                chromaKey = ChromaKeyConfig.fromMap(chromaKeyRaw)
            )
        }
    }
}

/**
 * A multi-layer composition stacking several tracks on a fixed canvas.
 *
 * @property layers Layers ordered bottom-to-top (last layer drawn on top)
 * @property canvasWidth Output canvas width (null = derive from first clip)
 * @property canvasHeight Output canvas height (null = derive from first clip)
 * @property backgroundColor Background ARGB color filling uncovered areas
 */
data class CompositionConfig(
    val layers: List<LayerConfig>,
    val canvasWidth: Double?,
    val canvasHeight: Double?,
    val backgroundColor: Long
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): CompositionConfig? {
            @Suppress("UNCHECKED_CAST")
            val layersRaw = map["layers"] as? List<Map<String, Any?>> ?: return null
            val layers = layersRaw.mapNotNull { LayerConfig.fromMap(it) }
            if (layers.isEmpty()) return null
            return CompositionConfig(
                layers = layers,
                canvasWidth = (map["canvasWidth"] as? Number)?.toDouble(),
                canvasHeight = (map["canvasHeight"] as? Number)?.toDouble(),
                backgroundColor = (map["backgroundColor"] as? Number)?.toLong()
                    ?: 0xFF000000L
            )
        }
    }
}

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
 * Removes a solid-colored background ("green screen").
 *
 * Mirrors the Dart `ChromaKey` model and the Swift `ChromaKeyConfig`. The
 * keying math lives in `ChromaKeyMath` and is the same formula Apple bakes into
 * its color cube; the GPU runs it in `ChromaKeyEffect`'s fragment shader.
 *
 * @property keyR/keyG/keyB The screen color to remove, gamma-encoded, 0..1
 * @property similarity Chroma-plane radius within which a pixel is fully removed
 * @property smoothness Width of the soft ramp just beyond [similarity]
 * @property spill How strongly the key's color cast is pulled out of the rest
 * @property backgroundColor Solid background ARGB, or null when none
 * @property backgroundImage Background image source, or null when none
 */
data class ChromaKeyConfig(
    val keyR: Double,
    val keyG: Double,
    val keyB: Double,
    val similarity: Double = 0.20,
    val smoothness: Double = 0.08,
    val spill: Double = 0.5,
    val backgroundColor: Int? = null,
    val backgroundImage: EncodedImage? = null,
) {
    /** The key color projected onto the Cb/Cr chroma plane. */
    val keyCb: Double = -0.168736 * keyR - 0.331264 * keyG + 0.5 * keyB
    val keyCr: Double = 0.5 * keyR - 0.418688 * keyG - 0.081312 * keyB

    /**
     * Unit vector pointing from neutral toward the key hue, used to pull the
     * key's cast back out during spill suppression. Zero for a neutral (gray)
     * key color, which disables despill rather than dividing by zero.
     */
    val keyDirCb: Double
    val keyDirCr: Double

    init {
        val length = kotlin.math.sqrt(keyCb * keyCb + keyCr * keyCr)
        if (length > 1e-5) {
            keyDirCb = keyCb / length
            keyDirCr = keyCr / length
        } else {
            keyDirCb = 0.0
            keyDirCr = 0.0
        }
    }

    /** Whether the keyed area is left transparent rather than filled. */
    val isTransparent: Boolean
        get() = backgroundColor == null && backgroundImage == null

    companion object {
        fun fromMap(map: Map<String, Any?>?): ChromaKeyConfig? {
            if (map == null) return null
            val keyColor = (map["keyColor"] as? Number)?.toInt() ?: return null
            val bgImage = EncodedImage.fromMap(map, "bgImagePath", "bgImageData")

            return ChromaKeyConfig(
                keyR = ((keyColor shr 16) and 0xFF) / 255.0,
                keyG = ((keyColor shr 8) and 0xFF) / 255.0,
                keyB = (keyColor and 0xFF) / 255.0,
                similarity = (map["similarity"] as? Number)?.toDouble() ?: 0.20,
                smoothness = (map["smoothness"] as? Number)?.toDouble() ?: 0.08,
                spill = (map["spill"] as? Number)?.toDouble() ?: 0.5,
                backgroundColor = (map["bgColor"] as? Number)?.toInt(),
                backgroundImage = bgImage,
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
 * @property slideFromX Custom slide start point, X in pixels from the frame's
 *   left edge (the layer's top-left corner, like the layer's own position).
 *   Overrides [slideDirection] when set.
 * @property slideFromY Y counterpart of [slideFromX], from the frame's top edge
 * @property scaleFrom Starting scale factor for scale animations
 */
data class LayerAnimationConfig(
    val type: String,
    val phase: String,
    val durationUs: Long,
    val curve: String = "linear",
    val slideDirection: String? = null,
    val slideFromX: Double? = null,
    val slideFromY: Double? = null,
    val scaleFrom: Double? = null
) {
    companion object {
        fun fromMap(map: Map<String, Any?>): LayerAnimationConfig {
            val slideFrom = map["slideFrom"] as? Map<*, *>
            return LayerAnimationConfig(
                type = map["type"] as String,
                phase = map["phase"] as String,
                durationUs = (map["durationUs"] as Number).toLong(),
                curve = map["curve"] as? String ?: "linear",
                slideDirection = map["slideDirection"] as? String,
                slideFromX = (slideFrom?.get("dx") as? Number)?.toDouble(),
                slideFromY = (slideFrom?.get("dy") as? Number)?.toDouble(),
                scaleFrom = (map["scaleFrom"] as? Number)?.toDouble()
            )
        }
    }
}

/**
 * Represents an image overlay layer with timing information.
 *
 * @property image The image source — a path when the caller had it on disk
 * @property startUs Start time in microseconds when the layer should appear
 * @property endUs End time in microseconds when the layer should disappear (-1 = until end of video)
 * @property x Horizontal offset in pixels (null = stretch to fill)
 * @property y Vertical offset in pixels (null = stretch to fill)
 * @property width Target width in pixels (null = original width)
 * @property height Target height in pixels (null = original height)
 * @property rotation Clockwise rotation around the layer center, in radians
 * @property loop Whether an animated image (GIF) repeats while visible
 * @property animations List of animations to apply to this layer
 */
data class ImageLayer(
    val image: EncodedImage,
    val startUs: Long,
    val endUs: Long,
    val x: Int? = null,
    val y: Int? = null,
    val width: Double? = null,
    val height: Double? = null,
    val rotation: Double = 0.0,
    val loop: Boolean = true,
    val animations: List<LayerAnimationConfig> = emptyList()
)

data class RenderConfig(
    val videoClips: List<VideoClip>,
    /** Optional multi-layer composition (layered render path). */
    val composition: CompositionConfig? = null,
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
    /**
     * Exact output canvas size. When set, the video is scaled to fit inside it
     * (preserving aspect ratio), centered, and padded with black. Null = derive
     * the size from the source/scale.
     */
    val outputWidth: Int? = null,
    val outputHeight: Int? = null,
    val bitrate: Int? = null,
    /** Upper limit for the output frame rate (fps). Null = keep source fps. */
    val maxFrameRate: Int? = null,
    val enableAudio: Boolean = true,
    val playbackSpeed: Float? = null,
    val colorFilters: List<ColorFilterConfig> = emptyList(),
    val audioTracks: List<AudioTrackConfig> = emptyList(),
    val blur: Double? = null,
    /**
     * Removes a solid-colored background ("green screen") from every clip that
     * does not carry its own key. A [VideoClip.chromaKey] overrides this, and
     * in the layered path a [LayerConfig.chromaKey] sits between the two.
     */
    val chromaKey: ChromaKeyConfig? = null,
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
            // Parse multi-layer composition (layered path).
            @Suppress("UNCHECKED_CAST")
            val compositionRaw = call.argument<Map<String, Any?>>("composition")
            val composition = compositionRaw?.let { CompositionConfig.fromMap(it) }

            // Parse video clips (single-track path).
            val videoClipsRaw = call.argument<List<Map<String, Any>>>("videoClips")

            Log.d(PACKAGE_TAG, "Received videoClipsRaw: ${videoClipsRaw?.size ?: 0} clips")

            if (videoClipsRaw.isNullOrEmpty() && composition == null) {
                throw IllegalArgumentException(
                    "Either videoClips or composition is required"
                )
            }

            val videoClips: List<VideoClip> =
                videoClipsRaw?.map { VideoClip.fromMap(it) } ?: emptyList()

            // Parse image layers
            val imageLayersRaw = call.argument<List<Map<String, Any>>>("imageLayers")
            val imageLayers: List<ImageLayer> = imageLayersRaw?.mapNotNull { layerMap ->
                val image = EncodedImage.fromMap(layerMap, "imagePath", "imageData")
                val startUs = (layerMap["startUs"] as? Number)?.toLong() ?: -1L
                val endUs = (layerMap["endUs"] as? Number)?.toLong() ?: -1L
                val x = (layerMap["x"] as? Number)?.toInt()
                val y = (layerMap["y"] as? Number)?.toInt()
                val width = (layerMap["width"] as? Number)?.toDouble()
                val height = (layerMap["height"] as? Number)?.toDouble()
                val rotation = (layerMap["rotation"] as? Number)?.toDouble() ?: 0.0
                val loop = layerMap["loop"] as? Boolean ?: true

                // Parse animations
                @Suppress("UNCHECKED_CAST")
                val animationsRaw = layerMap["animations"] as? List<Map<String, Any?>>
                val animations = animationsRaw?.map { LayerAnimationConfig.fromMap(it) } ?: emptyList()

                if (image == null) {
                    null
                } else {
                    ImageLayer(
                        image, startUs, endUs, x, y, width, height,
                        rotation, loop, animations
                    )
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
                composition = composition,
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
                outputWidth = call.argument<Number>("outputWidth")?.toInt(),
                outputHeight = call.argument<Number>("outputHeight")?.toInt(),
                bitrate = call.argument<Number>("bitrate")?.toInt(),
                maxFrameRate = call.argument<Number>("maxFrameRate")?.toInt(),
                enableAudio = call.argument<Boolean>("enableAudio") ?: true,
                playbackSpeed = call.argument<Number>("playbackSpeed")?.toFloat(),
                colorFilters = colorFilters,
                audioTracks = audioTracks,
                blur = call.argument<Number>("blur")?.toDouble(),
                chromaKey = ChromaKeyConfig.fromMap(
                    call.argument<Map<String, Any?>>("chromaKey")
                ),
                startUs = call.argument<Number?>("startUs")?.toLong(),
                endUs = call.argument<Number?>("endUs")?.toLong(),
                shouldOptimizeForNetworkUse = call.argument<Boolean>("shouldOptimizeForNetworkUse")
                    ?: true,
                imageBytesWithCropping = call.argument<Boolean>("imageBytesWithCropping") ?: false
            )
        }
    }
}
