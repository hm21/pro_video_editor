package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.LayerAudioVisualizerConfig.Style
import kotlin.math.PI
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The numbers here are those of the Dart `audio_visualizer_shapes_test.dart`,
 * so the export draws what the editor previews. Change them together.
 */
internal class AudioVisualizerShapesTest {

    private fun assertBars(expected: List<AudioVisualizerBar>, actual: List<AudioVisualizerBar>) {
        assertEquals(expected.size, actual.size)
        for ((e, a) in expected.zip(actual)) {
            assertEquals(e.left, a.left, 1e-9)
            assertEquals(e.top, a.top, 1e-9)
            assertEquals(e.right, a.right, 1e-9)
            assertEquals(e.bottom, a.bottom, 1e-9)
            assertEquals(e.radius, a.radius, 1e-9)
            assertEquals(e.pivotX, a.pivotX, 1e-9)
            assertEquals(e.pivotY, a.pivotY, 1e-9)
            assertEquals(e.rotation, a.rotation, 1e-9)
        }
    }

    @Test
    fun barsStandOnTheBottomASilentOneAsADot() {
        val shapes = audioVisualizerShapes(
            Style.BARS, 100.0, 50.0, floatArrayOf(0f, 0.5f, 1f, 0.2f)
        )

        assertNull(shapes.wave)
        assertBars(
            listOf(
                AudioVisualizerBar(3.75, 32.5, 21.25, 50.0, 8.75),
                AudioVisualizerBar(28.75, 25.0, 46.25, 50.0, 8.75),
                AudioVisualizerBar(53.75, 0.0, 71.25, 50.0, 8.75),
                AudioVisualizerBar(78.75, 32.5, 96.25, 50.0, 8.75),
            ),
            shapes.bars,
        )
    }

    @Test
    fun mirroredBarsGrowFromTheMiddle() {
        val shapes = audioVisualizerShapes(
            Style.MIRRORED_BARS, 100.0, 50.0, floatArrayOf(0f, 0.5f, 1f, 0.2f)
        )

        assertBars(
            listOf(
                AudioVisualizerBar(3.75, 16.25, 21.25, 33.75, 8.75),
                AudioVisualizerBar(28.75, 12.5, 46.25, 37.5, 8.75),
                AudioVisualizerBar(53.75, 0.0, 71.25, 50.0, 8.75),
                AudioVisualizerBar(78.75, 16.25, 96.25, 33.75, 8.75),
            ),
            shapes.bars,
        )
    }

    @Test
    fun aCircleMirrorsTheBandsDownBothSidesOfItsRing() {
        val shapes = audioVisualizerShapes(Style.CIRCLE, 200.0, 100.0, floatArrayOf(1f, 0f))

        fun bar(top: Double, rotation: Double) =
            AudioVisualizerBar(-6.25, top, 6.25, -25.0, 6.25, 100.0, 50.0, rotation)
        assertBars(
            listOf(
                bar(-50.0, PI / 4),
                bar(-37.5, 3 * PI / 4),
                bar(-37.5, 5 * PI / 4),
                bar(-50.0, 7 * PI / 4),
            ),
            shapes.bars,
        )
    }

    @Test
    fun aBarFillsTheShareOfItsSlotItIsGiven() {
        val shapes = audioVisualizerShapes(Style.BARS, 100.0, 50.0, floatArrayOf(1f, 0f), 0.5)

        assertBars(
            listOf(
                AudioVisualizerBar(12.5, 0.0, 37.5, 50.0, 12.5),
                AudioVisualizerBar(62.5, 25.0, 87.5, 50.0, 12.5),
            ),
            shapes.bars,
        )
    }

    @Test
    fun aRingOfBarsFillsTheShareOfTheRingItIsGiven() {
        val shapes = audioVisualizerShapes(Style.CIRCLE, 200.0, 100.0, floatArrayOf(1f, 0f), 0.2)
        // 2 pi 25 / 4 * 0.2 wide, leaving 25 - that for the loudest bar.
        val w = 7.853981633974483

        fun bar(top: Double, rotation: Double) =
            AudioVisualizerBar(-w / 2, top, w / 2, -25.0, w / 2, 100.0, 50.0, rotation)
        assertBars(
            listOf(
                bar(-50.0, PI / 4),
                bar(-(25 + w), 3 * PI / 4),
                bar(-(25 + w), 5 * PI / 4),
                bar(-50.0, 7 * PI / 4),
            ),
            shapes.bars,
        )
    }

    @Test
    fun aWaveTapersAtTheEdgesAndStaysInsideTheBox() {
        val shapes = audioVisualizerShapes(Style.WAVE, 40.0, 20.0, floatArrayOf(0.5f, 1f))
        val expected = doubleArrayOf(
            0.0, 10.0,
            1.6666666667, 9.1666666667, 5.0, 6.6666666667, 10.0, 5.0,
            15.0, 3.3333333333, 25.0, 0.0, 30.0, 0.0,
            35.0, 0.8333333333, 38.3333333333, 8.3333333333, 40.0, 10.0,
            38.3333333333, 11.6666666667, 35.0, 19.1666666667, 30.0, 20.0,
            25.0, 20.0, 15.0, 16.6666666667, 10.0, 15.0,
            5.0, 13.3333333333, 1.6666666667, 10.8333333333, 0.0, 10.0,
        )

        assertTrue(shapes.bars.isEmpty())
        val wave = shapes.wave!!
        assertEquals(expected.size, wave.size)
        for (i in expected.indices) assertEquals(expected[i], wave[i], 1e-9, "value $i")
    }

    @Test
    fun aSilentWaveKeepsAThinLine() {
        val wave = audioVisualizerShapes(Style.WAVE, 10.0, 100.0, floatArrayOf(0f)).wave!!

        assertEquals(5.0, wave[6], 1e-9)
        assertEquals(48.0, wave[7], 1e-9)
        assertEquals(52.0, wave[19], 1e-9)
    }

    @Test
    fun aNaNLevelCountsAsSilent() {
        for (style in Style.values()) {
            val silent = audioVisualizerShapes(style, 100.0, 50.0, floatArrayOf(0f, 1f))
            val broken = audioVisualizerShapes(style, 100.0, 50.0, floatArrayOf(Float.NaN, 1f))
            assertBars(silent.bars, broken.bars)
            assertContentEquals(silent.wave, broken.wave, "$style")
        }
    }

    @Test
    fun drawsNothingWithoutBandsOrWithoutABox() {
        for (style in Style.values()) {
            val empty = audioVisualizerShapes(style, 0.0, 10.0, floatArrayOf(1f))
            assertTrue(empty.bars.isEmpty())
            assertNull(empty.wave)
            assertTrue(audioVisualizerShapes(style, 10.0, 10.0, FloatArray(0)).bars.isEmpty())
        }
    }

    @Test
    fun aTurnedRasterGrowsToItsBoundingBox() {
        assertEquals(Pair(40, 20), rotatedBoxSize(40, 20, 0f))
        assertEquals(Pair(40, 20), rotatedBoxSize(40, 20, 360f))
        assertEquals(Pair(20, 40), rotatedBoxSize(40, 20, 90f))
        // 40 cos 45° + 20 sin 45° = 42.4
        assertEquals(Pair(42, 42), rotatedBoxSize(40, 20, 45f))
    }
}
