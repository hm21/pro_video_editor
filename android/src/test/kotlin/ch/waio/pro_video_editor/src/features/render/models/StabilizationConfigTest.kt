package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class StabilizationConfigTest {

    /** Keyframes at 30 fps, each with its own dx so they can be told apart. */
    private fun everyFrame() = StabilizationConfig.fromMap(
        mapOf(
            "timesUs" to listOf(0, 33_333, 66_667, 100_000),
            "values" to listOf(
                0.0, 0.0, 0.0, 1.1,
                0.1, 0.0, 0.0, 1.1,
                0.2, 0.0, 0.0, 1.1,
                0.3, 0.0, 0.0, 1.1,
            ),
        )
    )!!

    @Test
    fun transformAt_usesTheKeyframeOfTheFrameOnScreen() {
        val config = everyFrame()
        // Exactly on a frame, a hair before it, and between two frames.
        assertEquals(0.1, config.transformAt(33_333).dx, 1e-9)
        assertEquals(0.1, config.transformAt(33_000).dx, 1e-9)
        assertEquals(0.1, config.transformAt(50_000).dx, 1e-9)
    }

    @Test
    fun transformAt_holdsTheEndsOutsideTheRange() {
        val config = everyFrame()
        assertEquals(0.0, config.transformAt(-50_000).dx, 1e-9)
        assertEquals(0.3, config.transformAt(400_000).dx, 1e-9)
    }

    @Test
    fun transformAt_interpolatesAcrossFramesTheAnalysisSkipped() {
        // Analyzed at 30 fps; the gap from 66 667 to 200 000 skipped frames.
        val config = StabilizationConfig.fromMap(
            mapOf(
                "timesUs" to listOf(0, 33_333, 66_667, 200_000),
                "values" to listOf(
                    0.0, 0.0, 0.0, 1.0,
                    0.0, 0.0, 0.0, 1.0,
                    0.0, 0.0, 0.0, 1.0,
                    0.4, 0.0, 0.2, 1.2,
                ),
            )
        )!!
        val halfway = config.transformAt(133_333)
        assertEquals(0.2, halfway.dx, 1e-3)
        assertEquals(0.1, halfway.rotation, 1e-3)
        assertEquals(1.1, halfway.scale, 1e-3)
    }

    @Test
    fun fromMap_rejectsIncompleteData() {
        assertNull(StabilizationConfig.fromMap(null))
        assertNull(
            StabilizationConfig.fromMap(mapOf("timesUs" to listOf(0, 1), "values" to listOf(0.0)))
        )
    }
}
