package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class BitrateCapPolicyTest {

    private val cap = 8_000_000

    @Test
    fun noCapRequested_neverForcesEncoding() {
        assertFalse(BitrateCapPolicy.shouldForceEncode(null, listOf(20_000_000L)))
        assertFalse(BitrateCapPolicy.shouldForceEncode(null, listOf(null)))
        assertFalse(BitrateCapPolicy.shouldForceEncode(null, emptyList()))
    }

    @Test
    fun sourceOverCap_forcesEncoding() {
        // 20 Mbit/s camera source against an 8 Mbit/s cap — the reported bug.
        assertTrue(BitrateCapPolicy.shouldForceEncode(cap, listOf(20_000_000L)))
    }

    @Test
    fun sourceWithinCap_keepsFastPath() {
        assertFalse(BitrateCapPolicy.shouldForceEncode(cap, listOf(7_500_000L)))
        assertFalse(BitrateCapPolicy.shouldForceEncode(cap, listOf(8_000_000L)))
    }

    @Test
    fun toleranceGivesHeadroomAboveCap() {
        // 9.6 Mbit/s = 8 Mbit/s × 1.2 is still compliant; just above is not.
        assertFalse(BitrateCapPolicy.shouldForceEncode(cap, listOf(9_600_000L)))
        assertTrue(BitrateCapPolicy.shouldForceEncode(cap, listOf(9_600_001L)))
    }

    @Test
    fun multiClip_oneOverBudgetClipForcesEncoding() {
        assertTrue(
            BitrateCapPolicy.shouldForceEncode(cap, listOf(5_000_000L, 18_000_000L))
        )
        assertFalse(
            BitrateCapPolicy.shouldForceEncode(cap, listOf(5_000_000L, 6_000_000L))
        )
    }

    @Test
    fun unknownSourceBitrate_forcesEncoding() {
        // The cap is a guarantee: when a source cannot be probed the cap
        // cannot be proven, so the clip must go through the encoder.
        assertTrue(BitrateCapPolicy.shouldForceEncode(cap, listOf(null)))
        assertTrue(BitrateCapPolicy.shouldForceEncode(cap, listOf(5_000_000L, null)))
    }

    @Test
    fun noClips_doesNotForceEncoding() {
        assertFalse(BitrateCapPolicy.shouldForceEncode(cap, emptyList()))
    }

    @Test
    fun customToleranceIsRespected() {
        assertFalse(
            BitrateCapPolicy.shouldForceEncode(cap, listOf(11_900_000L), tolerance = 1.5)
        )
        assertTrue(
            BitrateCapPolicy.shouldForceEncode(cap, listOf(12_100_000L), tolerance = 1.5)
        )
    }
}
