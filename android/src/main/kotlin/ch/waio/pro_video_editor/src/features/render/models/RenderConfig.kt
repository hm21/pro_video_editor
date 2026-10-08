package ch.waio.pro_video_editor.src.features.render.models

import PACKAGE_TAG
import ch.waio.pro_video_editor.src.features.render.helpers.ChromaKeyMath
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
 * @property rotation Clockwise rotation of the placed box in radians, around
 *   its own centre. Offset/size describe the unrotated box.
 */
data class SegmentTransformConfig(
    val offsetX: Double?,
    val offsetY: Double?,
    val width: Double?,
    val height: Double?,
    val fit: String,
    val rotation: Double = 0.0
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
                fit = map["fit"] as? String ?: "cover",
                rotation = (map["rotation"] as? Number)?.toDouble() ?: 0.0
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
 * @property keyframes The layer's placement over time, sorted by time and on
 *   the composition timeline; see [KeyframeConfig]. Empty = every clip stays
 *   where its transform puts it
 */
data class LayerConfig(
    val clips: List<VideoClip>,
    val opacity: Float,
    val transform: SegmentTransformConfig?,
    /**
     * Default chroma key for the clips on this layer. A clip's own key wins;
     * null falls back to the global key.
     */
    val chromaKey: ChromaKeyConfig? = null,
    val keyframes: List<KeyframeConfig> = emptyList(),
    /** The clock [keyframes] are timed on; see [KeyframeClock]. */
    val keyframeClock: KeyframeClock = KeyframeClock.OUTPUT
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
                chromaKey = ChromaKeyConfig.fromMap(chromaKeyRaw),
                keyframes = KeyframeConfig.listFrom(map["keyframes"]),
                keyframeClock = KeyframeClock.from(map["keyframeClock"])
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
 * @property similarity Radius around the key within which a pixel is fully
 *  removed: in the chroma plane, plus brightness for a neutral key
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

    /** BT.601 luma of the key color. */
    val keyLuma: Double = ChromaKeyMath.luma(keyR, keyG, keyB)

    /**
     * How much brightness counts toward the matte distance: `0` for a saturated
     * key, `1` for a neutral one. See [ChromaKeyMath.lumaWeight].
     */
    val lumaWeight: Double = ChromaKeyMath.lumaWeight(keyCb, keyCr)

    /**
     * [spill] as actually applied, faded out by [lumaWeight]. A neutral key has
     * no hue to pull out, and the faint tint a camera records on a white wall
     * would otherwise pick an arbitrary direction and desaturate the subject
     * along it.
     */
    val effectiveSpill: Double = spill * (1.0 - lumaWeight)

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
 * @property fadeInUs How long the track rises from silence to [volume] after it starts, in microseconds
 * @property fadeOutUs How long the track falls to silence before its audio ends, in microseconds
 */
data class AudioTrackConfig(
    val path: String,
    val volume: Float = 1.0f,
    val loop: Boolean = false,
    val audioStartUs: Long? = null,
    val audioEndUs: Long? = null,
    val startUs: Long? = null,
    val endUs: Long? = null,
    val fadeInUs: Long = 0L,
    val fadeOutUs: Long = 0L
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
                endUs = (map["endUs"] as? Number)?.toLong(),
                fadeInUs = (map["fadeInUs"] as? Number)?.toLong() ?: 0L,
                fadeOutUs = (map["fadeOutUs"] as? Number)?.toLong() ?: 0L
            )
        }
    }
}

/**
 * Represents a single animation configuration for an image layer.
 *
 * @property type The kind of animation: "fade", "slide", "scale", "wiggle",
 *   "bounce", or "typewriter" / "wordByWord", which the renderer skips because a
 *   layer is one fixed image
 * @property phase When the animation plays: "animateIn", "animateOut",
 *   "animateInOut", or "loop" for as long as the layer is visible
 * @property durationUs Duration of the animation in microseconds, or of one
 *   cycle of a loop
 * @property curve Easing curve name (e.g. "linear", "easeIn", "bounceOut")
 * @property slideDirection Slide direction: "left", "right", "top", or "bottom"
 * @property slideFromX Custom slide start point, X in pixels from the frame's
 *   left edge (the layer's top-left corner, like the layer's own position).
 *   Overrides [slideDirection] when set.
 * @property slideFromY Y counterpart of [slideFromX], from the frame's top edge
 * @property scaleFrom Starting scale factor for scale animations
 * @property wiggleAngle How far a wiggle tilts the layer, in radians, clockwise
 *   first (null = [DEFAULT_WIGGLE_ANGLE])
 * @property bounceHeight How high a bounce lifts the layer, as a multiple of its
 *   own height (null = [DEFAULT_BOUNCE_HEIGHT])
 */
data class LayerAnimationConfig(
    val type: String,
    val phase: String,
    val durationUs: Long,
    val curve: String = "linear",
    val slideDirection: String? = null,
    val slideFromX: Double? = null,
    val slideFromY: Double? = null,
    val scaleFrom: Double? = null,
    val wiggleAngle: Double? = null,
    val bounceHeight: Double? = null,
    /** Where a `loop` starts repeating, on the output timeline; `-1` = the layer's start. */
    val loopStartUs: Long = -1L,
    /** Where a `loop` stops, on the output timeline; `-1` = the layer's end. */
    val loopEndUs: Long = -1L,
    /** How far into its cycle a `loop` already is where it starts, in µs. */
    val loopPhaseUs: Long = 0L
) {
    companion object {
        /** 10°, the tilt of a wiggle without its own [wiggleAngle]. */
        const val DEFAULT_WIGGLE_ANGLE = 0.17453292519943295

        /** Half the layer's height, the lift of a bounce without its own [bounceHeight]. */
        const val DEFAULT_BOUNCE_HEIGHT = 0.5

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
                scaleFrom = (map["scaleFrom"] as? Number)?.toDouble(),
                wiggleAngle = (map["wiggleAngle"] as? Number)?.toDouble(),
                bounceHeight = (map["bounceHeight"] as? Number)?.toDouble(),
                loopStartUs = (map["loopStartUs"] as? Number)?.toLong() ?: -1L,
                loopEndUs = (map["loopEndUs"] as? Number)?.toLong() ?: -1L,
                loopPhaseUs = (map["loopPhaseUs"] as? Number)?.toLong() ?: 0L
            )
        }
    }
}

/**
 * The clock a layer's keyframes are timed on, mirroring the Dart
 * `KeyframeClockPoint`s: a time on the output timeline maps to the time the
 * keyframes are measured in, piecewise linear through [points] (output µs to
 * keyframe µs, sorted by output time). Before the first point and after the
 * last one it runs as fast as the output; without points it is the output
 * timeline itself.
 *
 * Lets keyframes keep the timing they were made on, such as an editor that
 * shows a clip transition at a different pace than the video plays it: every
 * frame is placed by its time on that clock, so an eased motion follows its
 * own curve exactly, however the two timelines differ.
 */
data class KeyframeClock(val points: List<Pair<Long, Long>> = emptyList()) {
    /**
     * The keyframe time at [outputUs] on the output timeline. Where two points
     * share an output time, the clock jumps: the earlier one holds at that
     * time and the later one counts on from just after it.
     */
    fun keyframeTimeUs(outputUs: Long): Long {
        if (points.isEmpty()) return outputUs
        val first = points.first()
        if (outputUs <= first.first) return first.second + (outputUs - first.first)
        for (i in 1 until points.size) {
            val (outputTo, keyframeTo) = points[i]
            if (outputUs > outputTo) continue
            // outputFrom < outputUs <= outputTo, so the span is never empty.
            val (outputFrom, keyframeFrom) = points[i - 1]
            val share = (outputUs - outputFrom).toDouble() / (outputTo - outputFrom)
            // Ties to even, as `rounded(.toNearestOrEven)` on iOS and macOS.
            return keyframeFrom + kotlin.math.round(share * (keyframeTo - keyframeFrom)).toLong()
        }
        val last = points.last()
        return last.second + (outputUs - last.first)
    }

    companion object {
        val OUTPUT = KeyframeClock()

        /** The clock in [raw], a list of `{outputUs, keyframeUs}` maps. */
        fun from(raw: Any?): KeyframeClock = KeyframeClock(
            (raw as? List<*>)
                ?.mapNotNull { point ->
                    val map = point as? Map<*, *> ?: return@mapNotNull null
                    val output = (map["outputUs"] as? Number)?.toLong()
                    val keyframe = (map["keyframeUs"] as? Number)?.toLong()
                    if (output == null || keyframe == null) null else Pair(output, keyframe)
                }
                ?.sortedBy { it.first }
                ?: emptyList()
        )
    }
}

/**
 * A layer's placement at one point of the timeline, mirroring the Dart
 * `TimelineKeyframe`.
 *
 * @property timeUs When the placement applies, on the layer's own timeline
 * @property x Top-left x of the layer's unscaled box, in frame pixels
 * @property y Top-left y of the layer's unscaled box, in frame pixels
 * @property scale How much the box is grown around its center
 * @property rotation Clockwise rotation around the box center, in radians
 * @property opacity Opacity from 0 to 1
 * @property curve Easing toward the next keyframe (see [applyEasing])
 */
data class KeyframeConfig(
    val timeUs: Long,
    val x: Double,
    val y: Double,
    val scale: Double = 1.0,
    val rotation: Double = 0.0,
    val opacity: Double = 1.0,
    val curve: String = "linear"
) {
    companion object {
        fun fromMap(map: Map<*, *>): KeyframeConfig = KeyframeConfig(
            timeUs = (map["timeUs"] as? Number)?.toLong() ?: 0L,
            x = (map["x"] as? Number)?.toDouble() ?: 0.0,
            y = (map["y"] as? Number)?.toDouble() ?: 0.0,
            scale = (map["scale"] as? Number)?.toDouble() ?: 1.0,
            rotation = (map["rotation"] as? Number)?.toDouble() ?: 0.0,
            opacity = (map["opacity"] as? Number)?.toDouble() ?: 1.0,
            curve = map["curve"] as? String ?: "linear"
        )

        /** The keyframes in [raw], a list of maps, sorted by time. */
        fun listFrom(raw: Any?): List<KeyframeConfig> =
            (raw as? List<*>)
                ?.mapNotNull { (it as? Map<*, *>)?.let(::fromMap) }
                ?.sortedBy { it.timeUs }
                ?: emptyList()
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
 * @property animationOffsetUs How far into an animated image (GIF) playback
 *   begins when the layer appears, in microseconds
 * @property animations List of animations to apply to this layer
 * @property animationStartUs Where the animations count from, when that is not
 *   [startUs] (-1 = [startUs])
 * @property animationEndUs Where the animations end, when that is not [endUs]
 *   (-1 = [endUs])
 * @property censor Blurs or pixelates the picture beneath the layer instead of
 *   drawing [image], which then only marks the area (null = draw the image)
 * @property keyframes The layer's placement over time, sorted by time; they
 *   replace [x], [y] and [rotation], scale the size around its center and set
 *   the opacity (empty = the layer stays where [x] and [y] put it)
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
    val animationOffsetUs: Long = 0L,
    val animations: List<LayerAnimationConfig> = emptyList(),
    val animationStartUs: Long = -1L,
    val animationEndUs: Long = -1L,
    val censor: LayerCensorConfig? = null,
    val keyframes: List<KeyframeConfig> = emptyList(),
    /** The clock [keyframes] are timed on; see [KeyframeClock]. */
    val keyframeClock: KeyframeClock = KeyframeClock.OUTPUT
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
    /** Glitch, VHS, pixelate and other pixel effects, applied before [colorFilters]. */
    val effects: List<VideoEffectConfig> = emptyList(),
    /**
     * Effects the app registered with `CustomVideoEffects`, applied before
     * [effects], in list order.
     */
    val customEffects: List<CustomVideoEffectConfig> = emptyList(),
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
                val animationOffsetUs =
                    (layerMap["animationOffsetUs"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L

                // Parse animations
                @Suppress("UNCHECKED_CAST")
                val animationsRaw = layerMap["animations"] as? List<Map<String, Any?>>
                val animations = animationsRaw?.map { LayerAnimationConfig.fromMap(it) } ?: emptyList()
                val censor = LayerCensorConfig.fromMap(layerMap["censor"] as? Map<*, *>)
                val animationStartUs = (layerMap["animationStartUs"] as? Number)?.toLong() ?: -1L
                val animationEndUs = (layerMap["animationEndUs"] as? Number)?.toLong() ?: -1L

                if (image == null) {
                    null
                } else {
                    ImageLayer(
                        image, startUs, endUs, x, y, width, height,
                        rotation, loop, animationOffsetUs, animations,
                        animationStartUs, animationEndUs, censor,
                        KeyframeConfig.listFrom(layerMap["keyframes"]),
                        KeyframeClock.from(layerMap["keyframeClock"])
                    )
                }
            } ?: emptyList()

            Log.d(PACKAGE_TAG, "Parsed ${imageLayers.size} image layer(s)")

            // Parse color filters
            @Suppress("UNCHECKED_CAST")
            val colorFiltersRaw = call.argument<List<Map<String, Any?>>>("colorFilters")
            val colorFilters = colorFiltersRaw?.map { ColorFilterConfig.fromMap(it) } ?: emptyList()
            Log.d(PACKAGE_TAG, "Parsed ${colorFilters.size} color filter(s)")

            // Parse video effects
            @Suppress("UNCHECKED_CAST")
            val effectsRaw = call.argument<List<Map<String, Any?>>>("effects")
            val effects = effectsRaw?.mapNotNull { VideoEffectConfig.fromMap(it) } ?: emptyList()
            if (effects.size != (effectsRaw?.size ?: 0)) {
                Log.w(PACKAGE_TAG, "Skipped ${(effectsRaw?.size ?: 0) - effects.size} unreadable video effect(s)")
            }

            // Parse custom video effects
            @Suppress("UNCHECKED_CAST")
            val customEffectsRaw = call.argument<List<Map<String, Any?>>>("customEffects")
            val customEffects = customEffectsRaw?.mapNotNull { CustomVideoEffectConfig.fromMap(it) }
                ?: emptyList()
            if (customEffects.size != (customEffectsRaw?.size ?: 0)) {
                Log.w(PACKAGE_TAG, "Skipped ${(customEffectsRaw?.size ?: 0) - customEffects.size} custom video effect(s) without an id")
            }

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
                effects = effects,
                customEffects = customEffects,
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
