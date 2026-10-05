package ch.waio.pro_video_editor.src.features.render.models

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Turns an image layer into an area that blurs or pixelates the picture beneath
 * it instead of drawing its image; see `LayerCensor` on the Dart side.
 *
 * @property type How the area is hidden.
 * @property strength The blur's standard deviation, or the edge length of a
 *   pixelate block, in pixels of the frame the layer is laid out in.
 */
data class LayerCensorConfig(val type: Type, val strength: Double) {

    enum class Type { BLUR, PIXELATE }

    /**
     * The edge length of a pixelate block in whole pixels, at least two: one
     * pixel per block would leave the picture as it is.
     */
    val blockSize: Int get() = max(2, strength.roundToInt())

    /** This censor for a layer whose frame is [scale] times as large. */
    fun scaled(scale: Double): LayerCensorConfig =
        if (scale == 1.0) this else copy(strength = strength * scale)

    companion object {
        /**
         * The strengths used when the channel sends none, those of the Dart
         * `LayerCensor.blur()` and `LayerCensor.pixelate()`.
         */
        private const val DEFAULT_SIGMA = 24.0
        private const val DEFAULT_BLOCK_SIZE = 32.0

        /**
         * Parses the `censor` entry of an image layer, or `null` when the layer
         * has none and is drawn as an image.
         *
         * Any censor map yields a censor, so a layer that was meant to hide
         * something never shows its mask image instead.
         */
        fun fromMap(map: Map<*, *>?): LayerCensorConfig? {
            map ?: return null
            val type = if (map["type"] == "pixelate") Type.PIXELATE else Type.BLUR
            val strength = (map["strength"] as? Number)?.toDouble()
                ?.takeIf { it > 0 && it.isFinite() }
                ?: if (type == Type.PIXELATE) DEFAULT_BLOCK_SIZE else DEFAULT_SIGMA
            return LayerCensorConfig(type, strength)
        }
    }
}
