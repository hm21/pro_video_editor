package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.transformer.VideoEncoderSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class VideoEncoderConfigTest {

    @Test
    fun resolveOperatingRate_capsToRoundedSourceFrameRate() {
        assertEquals(30, VideoEncoderConfig.resolveOperatingRate(30f))
        assertEquals(60, VideoEncoderConfig.resolveOperatingRate(60f))
        assertEquals(24, VideoEncoderConfig.resolveOperatingRate(23.976f))
        assertEquals(30, VideoEncoderConfig.resolveOperatingRate(29.97f))
        assertEquals(120, VideoEncoderConfig.resolveOperatingRate(120f))
    }

    @Test
    fun resolveOperatingRate_neverReturnsIntegerMaxValue() {
        val frameRates = listOf(
            null, 0f, -1f, 24f, 30f, 60f, 120f, 1000f,
            Float.NaN, Float.POSITIVE_INFINITY,
        )
        for (fps in frameRates) {
            assertFalse(
                VideoEncoderConfig.resolveOperatingRate(fps) == Int.MAX_VALUE,
                "capped operating-rate must never be Integer.MAX_VALUE for fps=$fps",
            )
        }
    }

    @Test
    fun resolveOperatingRate_unknownOrInvalidFrameRate_usesDefault() {
        val default = VideoEncoderConfig.DEFAULT_OPERATING_RATE
        assertEquals(default, VideoEncoderConfig.resolveOperatingRate(null))
        assertEquals(default, VideoEncoderConfig.resolveOperatingRate(0f))
        assertEquals(default, VideoEncoderConfig.resolveOperatingRate(-5f))
        assertEquals(default, VideoEncoderConfig.resolveOperatingRate(Float.NaN))
        assertEquals(default, VideoEncoderConfig.resolveOperatingRate(Float.POSITIVE_INFINITY))
    }

    @Test
    fun buildAttempts_firstAttemptKeepsFastDefault() {
        // A null operatingRate means "leave Media3's default (operating-rate =
        // MAX)", so working devices keep their original speed.
        val first = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f).first()
        assertEquals("hw-fast-operating-rate", first.label)
        assertNull(first.operatingRate)
        assertFalse(first.useSoftwareEncoder)
        assertEquals(EncoderProfilePreference.ENCODER_DEFAULT, first.profile)
    }

    @Test
    fun buildAttempts_includesCappedOperatingRateFallback() {
        val attempts = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f)
        assertTrue(attempts.any { it.operatingRate == 30 })
    }

    @Test
    fun buildAttempts_explicitOperatingRatesNeverUseIntegerMaxValue() {
        // Only the first (fast) attempt leaves the rate to Media3 (null); every
        // explicit value must be a safe, capped one.
        val explicit = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f)
            .mapNotNull { it.operatingRate }
        assertTrue(explicit.isNotEmpty())
        assertTrue(explicit.none { it == Int.MAX_VALUE })
    }

    @Test
    fun buildAttempts_includesExactlyOneOperatingRateUnsetRung() {
        val attempts = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f)
        val unsetRung = attempts.singleOrNull {
            it.operatingRate == VideoEncoderSettings.RATE_UNSET
        }
        assertNotNull(unsetRung, "expected exactly one operating-rate-unset attempt")
    }

    @Test
    fun buildAttempts_includesExactlyOneSoftwareEncoderRung() {
        val attempts = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f)
        assertEquals(1, attempts.count { it.useSoftwareEncoder })
    }

    @Test
    fun buildAttempts_includesMainAndBaselineProfileFallbacksForAvc() {
        val attempts = VideoEncoderConfig.buildAttempts(
            sourceFrameRate = 30f,
            includeProfileFallbacks = true,
        )
        assertTrue(attempts.any { it.profile == EncoderProfilePreference.MAIN })
        assertTrue(attempts.any { it.profile == EncoderProfilePreference.BASELINE })
    }

    @Test
    fun buildAttempts_omitsProfileFallbacksWhenDisabled() {
        val attempts = VideoEncoderConfig.buildAttempts(
            sourceFrameRate = 30f,
            includeProfileFallbacks = false,
        )
        assertTrue(attempts.all { it.profile == EncoderProfilePreference.ENCODER_DEFAULT })
    }

    @Test
    fun buildAttempts_ordersFastFirstAndSoftwareLast() {
        val labels = VideoEncoderConfig.buildAttempts(sourceFrameRate = 30f).map { it.label }
        assertEquals(
            listOf(
                "hw-fast-operating-rate",
                "hw-capped-operating-rate",
                "hw-operating-rate-unset",
                "hw-main-profile",
                "hw-baseline-profile",
                "software-encoder",
            ),
            labels,
        )
        // The slow software encoder must be the very last resort.
        assertEquals("software-encoder", labels.last())
    }

    @Test
    fun buildAttempts_softwareEncoderIsLastEvenWithoutProfileFallbacks() {
        val attempts = VideoEncoderConfig.buildAttempts(
            sourceFrameRate = 30f,
            includeProfileFallbacks = false,
        )
        assertTrue(attempts.last().useSoftwareEncoder)
    }
}
