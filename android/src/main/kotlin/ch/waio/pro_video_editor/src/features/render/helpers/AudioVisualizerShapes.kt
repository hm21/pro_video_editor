package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.LayerAudioVisualizerConfig
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min

/*
 * The shapes of an audio visualizer, computed exactly as the Dart
 * `audioVisualizerShapes` computes them, so the editor's preview and the
 * export draw the same thing. Change both together.
 */

/** How much of its slot a bar fills; Dart `audioVisualizerBarFill`. */
internal const val AUDIO_VISUALIZER_BAR_FILL = 0.7

/** The level a wave band never drops below; Dart `audioVisualizerWaveMinLevel`. */
internal const val AUDIO_VISUALIZER_WAVE_MIN_LEVEL = 0.04

/** The ring's radius against the box's circle; Dart `audioVisualizerCircleInnerRadius`. */
internal const val AUDIO_VISUALIZER_CIRCLE_INNER_RADIUS = 0.5

/** How much of its share of the ring a bar fills; Dart `audioVisualizerCircleBarFill`. */
internal const val AUDIO_VISUALIZER_CIRCLE_BAR_FILL = 0.6

/**
 * A rounded bar: a box with fully rounded corners of [radius], turned
 * [rotation] radians clockwise about ([pivotX], [pivotY]) of the layer's box,
 * its own coordinates measured from that point.
 */
internal data class AudioVisualizerBar(
    val left: Double,
    val top: Double,
    val right: Double,
    val bottom: Double,
    val radius: Double,
    val pivotX: Double = 0.0,
    val pivotY: Double = 0.0,
    val rotation: Double = 0.0,
)

/**
 * The shapes one set of levels fills: [bars], or the closed outline [wave] —
 * a start point followed by cubic Bézier curves of six values each.
 */
internal class AudioVisualizerShapes(
    val bars: List<AudioVisualizerBar> = emptyList(),
    val wave: DoubleArray? = null,
)

/**
 * The shapes [style] draws for [levels], one per band from 0 to 1, in a box
 * of [width] by [height] whose top-left corner is the origin. [barFill] is how
 * much of its share a bar fills, `null` for the style's own.
 */
internal fun audioVisualizerShapes(
    style: LayerAudioVisualizerConfig.Style,
    width: Double,
    height: Double,
    levels: FloatArray,
    barFill: Double? = null,
): AudioVisualizerShapes {
    val count = levels.size
    if (count == 0 || width <= 0 || height <= 0) return AudioVisualizerShapes()
    fun level(band: Int): Double = LayerAudioVisualizerConfig.unitLevel(levels[band])

    return when (style) {
        LayerAudioVisualizerConfig.Style.BARS,
        LayerAudioVisualizerConfig.Style.MIRRORED_BARS -> {
            val slot = width / count
            val barWidth = slot * (barFill ?: AUDIO_VISUALIZER_BAR_FILL)
            // A silent bar is a dot as wide as the bar.
            val minHeight = min(barWidth, height)
            val mirrored = style == LayerAudioVisualizerConfig.Style.MIRRORED_BARS
            AudioVisualizerShapes(
                bars = List(count) { band ->
                    val barHeight = min(height, max(minHeight, level(band) * height))
                    val left = band * slot + (slot - barWidth) / 2
                    val top = if (mirrored) (height - barHeight) / 2 else height - barHeight
                    AudioVisualizerBar(
                        left = left,
                        top = top,
                        right = left + barWidth,
                        bottom = top + barHeight,
                        radius = min(barWidth, barHeight) / 2,
                    )
                }
            )
        }

        LayerAudioVisualizerConfig.Style.CIRCLE -> {
            val radius = min(width, height) / 2
            val bars = count * 2
            val ring = radius * AUDIO_VISUALIZER_CIRCLE_INNER_RADIUS
            val barWidth = min(
                2 * PI * ring / bars * (barFill ?: AUDIO_VISUALIZER_CIRCLE_BAR_FILL),
                (radius - ring) / 2,
            )
            val maxLength = max(0.0, radius - ring - barWidth)
            AudioVisualizerShapes(
                bars = List(bars) { bar ->
                    // The bands run from the top down both sides of the ring.
                    val band = if (bar < count) bar else bars - 1 - bar
                    AudioVisualizerBar(
                        left = -barWidth / 2,
                        top = -(ring + barWidth + level(band) * maxLength),
                        right = barWidth / 2,
                        bottom = -ring,
                        radius = barWidth / 2,
                        pivotX = width / 2,
                        pivotY = height / 2,
                        rotation = 2 * PI * (bar + 0.5) / bars,
                    )
                }
            )
        }

        LayerAudioVisualizerConfig.Style.WAVE ->
            AudioVisualizerShapes(wave = waveOutline(width, height, levels))
    }
}

/**
 * The outline of a wave: a Catmull-Rom curve through one point per band along
 * the top, mirrored along the bottom.
 */
private fun waveOutline(width: Double, height: Double, levels: FloatArray): DoubleArray {
    val count = levels.size
    val middle = height / 2
    // Each point's x and its distance from the middle line, with a point of no
    // height at either edge so the wave tapers there.
    val xs = DoubleArray(count + 2)
    val amplitudes = DoubleArray(count + 2)
    xs[count + 1] = width
    for (band in 0 until count) {
        xs[band + 1] = (band + 0.5) * width / count
        amplitudes[band + 1] = max(
            AUDIO_VISUALIZER_WAVE_MIN_LEVEL,
            LayerAudioVisualizerConfig.unitLevel(levels[band]),
        ) * middle
    }

    val last = count + 1
    // The control points of the curve from point i to point i + 1, kept
    // between the middle line and the edge of the box, so the curve can
    // neither cross the middle line nor leave the box.
    fun controls(i: Int): DoubleArray {
        val before = max(0, i - 1)
        val after = min(last, i + 2)
        return doubleArrayOf(
            xs[i] + (xs[i + 1] - xs[before]) / 6,
            (amplitudes[i] + (amplitudes[i + 1] - amplitudes[before]) / 6).coerceIn(0.0, middle),
            xs[i + 1] - (xs[after] - xs[i]) / 6,
            (amplitudes[i + 1] - (amplitudes[after] - amplitudes[i]) / 6).coerceIn(0.0, middle),
        )
    }

    val outline = DoubleArray(2 + last * 12)
    outline[0] = 0.0
    outline[1] = middle
    var at = 2
    // Along the top, left to right.
    for (i in 0 until last) {
        val c = controls(i)
        for (value in doubleArrayOf(
            c[0], middle - c[1], c[2], middle - c[3], xs[i + 1], middle - amplitudes[i + 1],
        )) outline[at++] = value
    }
    // Back along the bottom, right to left, through the same control points.
    for (i in last - 1 downTo 0) {
        val c = controls(i)
        for (value in doubleArrayOf(
            c[2], middle + c[3], c[0], middle + c[1], xs[i], middle + amplitudes[i],
        )) outline[at++] = value
    }
    return outline
}
