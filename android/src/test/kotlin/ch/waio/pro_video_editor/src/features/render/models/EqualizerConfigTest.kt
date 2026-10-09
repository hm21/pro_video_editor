package ch.waio.pro_video_editor.src.features.render.models

import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pins how an equalizer is read from the map the Dart side sends. */
internal class EqualizerConfigTest {

    @Test
    fun `parses every band in order`() {
        val config = EqualizerConfig.fromMap(
            mapOf(
                "bands" to listOf(
                    mapOf("type" to "lowShelf", "frequencyHz" to 120, "gainDb" to 4.5, "q" to 0.7),
                    mapOf("type" to "peak", "frequencyHz" to 2500.0, "gainDb" to -3, "q" to 1.4),
                    mapOf("type" to "highShelf", "frequencyHz" to 8000.0, "gainDb" to 2.0),
                ),
            ),
        )

        assertEquals(
            EqualizerConfig(
                listOf(
                    EqualizerBand(EqualizerBandType.LOW_SHELF, 120.0, 4.5, 0.7),
                    EqualizerBand(EqualizerBandType.PEAK, 2500.0, -3.0, 1.4),
                    EqualizerBand(EqualizerBandType.HIGH_SHELF, 8000.0, 2.0),
                ),
            ),
            config,
        )
    }

    @Test
    fun `a band without a positive q gets 1 over the square root of 2`() {
        val config = EqualizerConfig.fromMap(
            mapOf(
                "bands" to listOf(
                    mapOf("type" to "peak", "frequencyHz" to 1000.0, "gainDb" to 3.0),
                    mapOf("type" to "peak", "frequencyHz" to 1000.0, "gainDb" to 3.0, "q" to 0),
                ),
            ),
        )!!

        assertEquals(1 / sqrt(2.0), EqualizerBand.DEFAULT_Q, 1e-15)
        assertTrue(config.bands.all { it.q == EqualizerBand.DEFAULT_Q })
    }

    @Test
    fun `skips the bands it cannot parse`() {
        val config = EqualizerConfig.fromMap(
            mapOf(
                "bands" to listOf(
                    mapOf("type" to "notch", "frequencyHz" to 1000.0, "gainDb" to 3.0),
                    mapOf("type" to "peak", "frequencyHz" to 0, "gainDb" to 3.0),
                    mapOf("type" to "peak", "frequencyHz" to -40.0, "gainDb" to 3.0),
                    mapOf("type" to "peak", "gainDb" to 3.0),
                    "not a band",
                    mapOf("type" to "highShelf", "frequencyHz" to 3000.0, "gainDb" to -6.0),
                ),
            ),
        )

        assertEquals(
            EqualizerConfig(listOf(EqualizerBand(EqualizerBandType.HIGH_SHELF, 3000.0, -6.0))),
            config,
        )
    }

    @Test
    fun `is null when absent or without bands or flat`() {
        assertNull(EqualizerConfig.fromMap(null))
        assertNull(EqualizerConfig.fromMap(mapOf("bassGainDb" to 6.0)))
        assertNull(EqualizerConfig.fromMap(mapOf("bands" to emptyList<Any>())))
        assertNull(
            EqualizerConfig.fromMap(
                mapOf(
                    "bands" to listOf(
                        mapOf("type" to "lowShelf", "frequencyHz" to 200.0, "gainDb" to 0),
                        mapOf("type" to "peak", "frequencyHz" to 1000.0),
                    ),
                ),
            ),
        )
    }

    @Test
    fun `boosts only while a band raises the audio`() {
        val cut = EqualizerBand(EqualizerBandType.LOW_SHELF, 200.0, -6.0)
        val boost = EqualizerBand(EqualizerBandType.PEAK, 1000.0, 2.0)

        assertTrue(EqualizerConfig(listOf(cut, boost)).boosts)
        assertFalse(EqualizerConfig(listOf(cut)).boosts)
        assertFalse(EqualizerConfig(listOf(cut)).isFlat)
        assertTrue(EqualizerConfig().isFlat)
    }
}
