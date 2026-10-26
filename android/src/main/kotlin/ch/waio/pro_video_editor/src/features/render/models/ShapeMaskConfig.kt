package ch.waio.pro_video_editor.src.features.render.models

import ch.waio.pro_video_editor.src.features.render.helpers.applyEasing
import kotlin.math.max

/** The shapes of the Dart `LayerShapeMaskShape`, by their wire names. */
enum class ShapeMaskShape(val wireName: String) {
    ELLIPSE("ellipse"),
    RECTANGLE("rectangle"),
    HEART("heart"),
    STAR("star"),
    TRIANGLE("triangle"),
    DIAMOND("diamond"),
    HEXAGON("hexagon"),
    SPEECH_BUBBLE("speechBubble"),
    LINEAR("linear");

    companion object {
        /** The shape named [name], or an ellipse for a name this version does not know. */
        fun from(name: Any?): ShapeMaskShape =
            entries.firstOrNull { it.wireName == name } ?: ELLIPSE
    }
}

/**
 * A shape mask at one moment, everything in fractions of the masked image,
 * mirroring a still Dart `LayerShapeMask`.
 *
 * @property centerX Centre of the shape, from the left edge
 * @property centerY Centre of the shape, from the top edge
 * @property width Width of the shape's box before it is turned
 * @property height Height of the shape's box before it is turned
 * @property rotation Clockwise turn around the centre, in radians
 * @property feather Softness of the edge, in fractions of the image's shorter
 *   side
 * @property cornerRadius Roundness of a rectangle's corners, from 0 to 1
 * @property invert Whether the image shows outside the shape
 * @property mirrored Whether the shape is mirrored across its vertical centre
 *   line before it is turned
 */
data class ShapeMaskState(
    val shape: ShapeMaskShape,
    val centerX: Double,
    val centerY: Double,
    val width: Double,
    val height: Double,
    val rotation: Double,
    val feather: Double,
    val cornerRadius: Double,
    val invert: Boolean,
    val mirrored: Boolean,
)

/**
 * The mask's centre, size, turn and softness at one point of the layer's
 * keyframe timeline, mirroring the Dart `LayerShapeMaskKeyframe`.
 *
 * @property curve Easing toward the next keyframe (see [applyEasing])
 */
data class ShapeMaskKeyframeConfig(
    val timeUs: Long,
    val centerX: Double = 0.5,
    val centerY: Double = 0.5,
    val width: Double = 0.5,
    val height: Double = 0.5,
    val rotation: Double = 0.0,
    val feather: Double = 0.0,
    val curve: String = "linear",
) {
    companion object {
        fun fromMap(map: Map<*, *>): ShapeMaskKeyframeConfig = ShapeMaskKeyframeConfig(
            timeUs = (map["timeUs"] as? Number)?.toLong() ?: 0L,
            centerX = (map["x"] as? Number)?.toDouble() ?: 0.5,
            centerY = (map["y"] as? Number)?.toDouble() ?: 0.5,
            width = max(0.0, (map["width"] as? Number)?.toDouble() ?: 0.5),
            height = max(0.0, (map["height"] as? Number)?.toDouble() ?: 0.5),
            rotation = (map["rotation"] as? Number)?.toDouble() ?: 0.0,
            feather = max(0.0, (map["feather"] as? Number)?.toDouble() ?: 0.0),
            curve = map["curve"] as? String ?: "linear",
        )
    }
}

/**
 * A shape a layer shows through, drawn on every frame, mirroring the Dart
 * `LayerShapeMask`.
 *
 * [keyframes] are sorted by time and measured on the layer's keyframe
 * timeline; see [stateAt].
 */
data class ShapeMaskConfig(
    val shape: ShapeMaskShape,
    val centerX: Double = 0.5,
    val centerY: Double = 0.5,
    val width: Double = 0.5,
    val height: Double = 0.5,
    val rotation: Double = 0.0,
    val feather: Double = 0.0,
    val cornerRadius: Double = 0.0,
    val invert: Boolean = false,
    val mirrored: Boolean = false,
    val keyframes: List<ShapeMaskKeyframeConfig> = emptyList(),
) {
    /**
     * The mask at [keyframeTimeUs] on the layer's keyframe timeline: its own
     * values without keyframes; with them, the first keyframe's before the
     * first one, the last keyframe's after the last one, and in between a mix
     * of the two around it along the earlier one's curve. Only the size and the
     * softness are kept at 0 or more, so an elastic or bounce curve may
     * overshoot.
     *
     * Mirrors `layerMaskKeyframeAt` in pro_image_editor, which the editor
     * preview reads.
     */
    fun stateAt(keyframeTimeUs: Long): ShapeMaskState {
        if (keyframes.isEmpty()) return state(centerX, centerY, width, height, rotation, feather)
        val first = keyframes.first()
        if (keyframeTimeUs <= first.timeUs) return state(first)
        val last = keyframes.last()
        if (keyframeTimeUs >= last.timeUs) return state(last)

        // The last keyframe at or before the time; both ends are ruled out
        // above, so a later one always exists.
        var index = 0
        for (i in 1 until keyframes.size) {
            if (keyframes[i].timeUs > keyframeTimeUs) break
            index = i
        }
        val from = keyframes[index]
        val to = keyframes[index + 1]
        val spanUs = to.timeUs - from.timeUs
        if (spanUs <= 0L) return state(to)

        val eased = applyEasing((keyframeTimeUs - from.timeUs).toDouble() / spanUs, from.curve)
        fun mix(a: Double, b: Double) = a + (b - a) * eased
        return state(
            mix(from.centerX, to.centerX),
            mix(from.centerY, to.centerY),
            max(0.0, mix(from.width, to.width)),
            max(0.0, mix(from.height, to.height)),
            mix(from.rotation, to.rotation),
            max(0.0, mix(from.feather, to.feather)),
        )
    }

    private fun state(keyframe: ShapeMaskKeyframeConfig) = state(
        keyframe.centerX, keyframe.centerY, keyframe.width, keyframe.height,
        keyframe.rotation, keyframe.feather
    )

    private fun state(
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        rotation: Double,
        feather: Double,
    ) = ShapeMaskState(
        shape, centerX, centerY, width, height, rotation, feather, cornerRadius, invert, mirrored
    )

    companion object {
        /** The mask in [raw], a map written by the Dart `LayerShapeMask.toMap`. */
        fun from(raw: Any?): ShapeMaskConfig? {
            val map = raw as? Map<*, *> ?: return null
            return ShapeMaskConfig(
                shape = ShapeMaskShape.from(map["shape"]),
                centerX = (map["x"] as? Number)?.toDouble() ?: 0.5,
                centerY = (map["y"] as? Number)?.toDouble() ?: 0.5,
                width = max(0.0, (map["width"] as? Number)?.toDouble() ?: 0.5),
                height = max(0.0, (map["height"] as? Number)?.toDouble() ?: 0.5),
                rotation = (map["rotation"] as? Number)?.toDouble() ?: 0.0,
                feather = max(0.0, (map["feather"] as? Number)?.toDouble() ?: 0.0),
                cornerRadius = ((map["cornerRadius"] as? Number)?.toDouble() ?: 0.0)
                    .coerceIn(0.0, 1.0),
                invert = map["invert"] == true,
                mirrored = map["mirrored"] == true,
                keyframes = (map["keyframes"] as? List<*>)
                    ?.mapNotNull { (it as? Map<*, *>)?.let(ShapeMaskKeyframeConfig::fromMap) }
                    ?.sortedBy { it.timeUs }
                    ?: emptyList(),
            )
        }
    }
}
