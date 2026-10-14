package ch.waio.pro_video_editor.src.features.render.models

import kotlin.math.floor
import kotlin.math.max

/**
 * Draws bars or a wave that move with the sound in an image layer's box,
 * instead of its image; see `LayerAudioVisualizer` on the Dart side.
 *
 * @property style How the levels are drawn.
 * @property color The ARGB color every shape is filled with.
 * @property bandCount How many bands every row of [levels] holds.
 * @property levels The level of every band, row after row, from 0 to 1. Row
 *   `row` is the moment `row / framesPerSecond` seconds into the rendered video.
 * @property framesPerSecond How many rows of [levels] there are a second.
 * @property barFill How much of its share a bar fills, from above 0 to 1;
 *   `null` takes the style's own.
 */
class LayerAudioVisualizerConfig(
    val style: Style,
    val color: Int,
    val bandCount: Int,
    val levels: FloatArray,
    val framesPerSecond: Double,
    val barFill: Double? = null,
) {

    enum class Style { BARS, MIRRORED_BARS, WAVE, CIRCLE }

    /** How many rows [levels] holds. */
    val frameCount: Int get() = levels.size / bandCount

    /**
     * Writes the level of every band at [timeUs] on the rendered video into
     * [into], mixed linearly between the two rows around it; the same mix as
     * `LayerAudioVisualizer.levelsAt`. Before the first row and after the last
     * one every band is silent.
     */
    fun levelsAt(timeUs: Long, into: FloatArray) {
        val position = timeUs.toDouble() * framesPerSecond / 1_000_000.0
        val rowFloor = floor(position)
        val row = rowFloor.toLong()
        val mix = position - rowFloor
        for (band in 0 until minOf(bandCount, into.size)) {
            val from = level(row, band)
            val to = level(row + 1, band)
            into[band] = (from + (to - from) * mix).toFloat()
        }
    }

    private fun level(row: Long, band: Int): Double {
        if (row < 0 || row >= frameCount) return 0.0
        return unitLevel(levels[(row * bandCount).toInt() + band])
    }

    override fun equals(other: Any?): Boolean =
        other is LayerAudioVisualizerConfig &&
            other.style == style &&
            other.color == color &&
            other.bandCount == bandCount &&
            other.framesPerSecond == framesPerSecond &&
            other.barFill == barFill &&
            other.levels.contentEquals(levels)

    override fun hashCode(): Int {
        var result = style.hashCode()
        result = 31 * result + color
        result = 31 * result + bandCount
        result = 31 * result + framesPerSecond.hashCode()
        result = 31 * result + (barFill?.hashCode() ?: 0)
        result = 31 * result + levels.contentHashCode()
        return result
    }

    override fun toString(): String =
        "LayerAudioVisualizerConfig(style=$style, bandCount=$bandCount, " +
            "frames=$frameCount, framesPerSecond=$framesPerSecond)"

    companion object {
        /**
         * [level] held to 0–1, with NaN counted as silent, as the Dart
         * `audioVisualizerUnitLevel` reads it. `coerceIn` alone keeps a NaN,
         * which would drop a bar or the whole wave.
         */
        internal fun unitLevel(level: Float): Double =
            if (level.isNaN()) 0.0 else level.toDouble().coerceIn(0.0, 1.0)

        /**
         * Parses the `audioVisualizer` entry of an image layer, or `null` when
         * the layer has none and draws its image.
         *
         * The levels arrive as a `FloatArray` from a Dart `Float32List`; a
         * plain list of numbers is read too. A table cut short keeps its whole
         * rows, and an unknown style draws bars.
         */
        fun fromMap(map: Map<*, *>?): LayerAudioVisualizerConfig? {
            map ?: return null
            val bandCount = max(1, (map["bandCount"] as? Number)?.toInt() ?: 1)
            val raw = when (val levels = map["levels"]) {
                is FloatArray -> levels
                is DoubleArray -> FloatArray(levels.size) { levels[it].toFloat() }
                is List<*> -> FloatArray(levels.size) {
                    (levels[it] as? Number)?.toFloat() ?: 0f
                }
                else -> FloatArray(0)
            }
            val whole = raw.size - raw.size % bandCount
            val style = when (map["style"]) {
                "mirroredBars" -> Style.MIRRORED_BARS
                "wave" -> Style.WAVE
                "circle" -> Style.CIRCLE
                else -> Style.BARS
            }
            val framesPerSecond = (map["framesPerSecond"] as? Number)?.toDouble()
                ?.takeIf { it > 0 && it.isFinite() } ?: DEFAULT_FRAMES_PER_SECOND
            return LayerAudioVisualizerConfig(
                style = style,
                // An opaque ARGB color does not fit an Int on the Dart side
                // and arrives as a Long; its low 32 bits are the color.
                color = (map["color"] as? Number)?.toLong()?.toInt() ?: DEFAULT_COLOR,
                bandCount = bandCount,
                levels = if (whole == raw.size) raw else raw.copyOf(whole),
                framesPerSecond = framesPerSecond,
                barFill = (map["barFill"] as? Number)?.toDouble()
                    ?.takeIf { it > 0 && it <= 1 },
            )
        }

        /** The defaults of the Dart `LayerAudioVisualizer`. */
        private const val DEFAULT_FRAMES_PER_SECOND = 60.0
        private const val DEFAULT_COLOR = -0x1
    }
}
