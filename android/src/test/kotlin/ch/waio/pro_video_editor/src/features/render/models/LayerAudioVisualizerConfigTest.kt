package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

internal class LayerAudioVisualizerConfigTest {

    /** Two bands, ten rows a second: [0, 1] at 0 s, [1, 0] at 0.1 s. */
    private val visualizer = LayerAudioVisualizerConfig(
        style = LayerAudioVisualizerConfig.Style.BARS,
        color = -1,
        bandCount = 2,
        levels = floatArrayOf(0f, 1f, 1f, 0f),
        framesPerSecond = 10.0,
    )

    private fun levelsAt(timeUs: Long): FloatArray =
        FloatArray(2).also { visualizer.levelsAt(timeUs, it) }

    @Test
    fun aLayerWithoutVisualizerDrawsItsImage() {
        assertNull(LayerAudioVisualizerConfig.fromMap(null))
    }

    @Test
    fun parsesTheChannelMap() {
        val parsed = assertNotNull(
            LayerAudioVisualizerConfig.fromMap(
                mapOf(
                    "style" to "mirroredBars",
                    // An opaque color does not fit a 32-bit int in Dart.
                    "color" to 0xFF27C58BL,
                    "bandCount" to 2,
                    "levels" to floatArrayOf(0.25f, 0.5f),
                    "framesPerSecond" to 30.0,
                    "barFill" to 0.4,
                )
            )
        )
        assertEquals(0.4, parsed.barFill)

        assertEquals(LayerAudioVisualizerConfig.Style.MIRRORED_BARS, parsed.style)
        assertEquals(0xFF27C58B.toInt(), parsed.color)
        assertEquals(2, parsed.bandCount)
        assertContentEquals(floatArrayOf(0.25f, 0.5f), parsed.levels)
        assertEquals(30.0, parsed.framesPerSecond)
    }

    @Test
    fun readsEveryStyle() {
        for ((name, style) in listOf(
            "bars" to LayerAudioVisualizerConfig.Style.BARS,
            "mirroredBars" to LayerAudioVisualizerConfig.Style.MIRRORED_BARS,
            "wave" to LayerAudioVisualizerConfig.Style.WAVE,
            "circle" to LayerAudioVisualizerConfig.Style.CIRCLE,
        )) {
            assertEquals(
                style,
                LayerAudioVisualizerConfig.fromMap(mapOf("style" to name))?.style,
            )
        }
    }

    @Test
    fun fallsBackToTheDartDefaultsAndKeepsWholeRows() {
        val parsed = assertNotNull(
            LayerAudioVisualizerConfig.fromMap(
                mapOf(
                    "style" to "spiral",
                    "bandCount" to 2,
                    "levels" to listOf(0.5, 0.5, 1.0),
                    "framesPerSecond" to 0,
                    "barFill" to 1.5,
                )
            )
        )

        assertEquals(LayerAudioVisualizerConfig.Style.BARS, parsed.style)
        assertEquals(null, parsed.barFill)
        assertEquals(-1, parsed.color)
        assertContentEquals(floatArrayOf(0.5f, 0.5f), parsed.levels)
        assertEquals(60.0, parsed.framesPerSecond)
    }

    @Test
    fun readsARowAtItsOwnTime() {
        assertContentEquals(floatArrayOf(0f, 1f), levelsAt(0))
        assertContentEquals(floatArrayOf(1f, 0f), levelsAt(100_000))
    }

    @Test
    fun mixesTheRowsAroundATimeBetweenThem() {
        val levels = levelsAt(25_000)
        assertEquals(0.25f, levels[0], 1e-6f)
        assertEquals(0.75f, levels[1], 1e-6f)
    }

    @Test
    fun fadesToSilenceAfterTheLastRowAndBeforeTheFirst() {
        assertContentEquals(floatArrayOf(0.5f, 0f), levelsAt(150_000))
        assertContentEquals(floatArrayOf(0f, 0f), levelsAt(200_000))
        assertContentEquals(floatArrayOf(0f, 0.5f), levelsAt(-50_000))
    }

    @Test
    fun clampsLevelsOutsideZeroToOne() {
        val loud = LayerAudioVisualizerConfig(
            style = LayerAudioVisualizerConfig.Style.WAVE,
            color = -1,
            bandCount = 1,
            levels = floatArrayOf(4f, -2f),
            framesPerSecond = 1.0,
        )
        val levels = FloatArray(1)

        loud.levelsAt(0, levels)
        assertEquals(1f, levels[0])
        loud.levelsAt(1_000_000, levels)
        assertEquals(0f, levels[0])
    }

    @Test
    fun countsANaNLevelAsSilent() {
        val broken = LayerAudioVisualizerConfig(
            style = LayerAudioVisualizerConfig.Style.BARS,
            color = -1,
            bandCount = 1,
            levels = floatArrayOf(Float.NaN, 1f),
            framesPerSecond = 1.0,
        )
        val levels = FloatArray(1)

        broken.levelsAt(0, levels)
        assertEquals(0f, levels[0])
        broken.levelsAt(500_000, levels)
        assertEquals(0.5f, levels[0])
    }
}
