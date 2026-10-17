package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.helpers.VideoGlobalTrimCalculator.ClipInput
import ch.waio.pro_video_editor.src.features.render.helpers.VideoGlobalTrimCalculator.ClipTrimResult
import ch.waio.pro_video_editor.src.features.render.models.SpeedRamp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class VideoGlobalTrimCalculatorTest {
    private fun trim(
        clips: List<ClipInput>,
        globalStartUs: Long? = null,
        globalEndUs: Long? = null,
        globalPlaybackSpeed: Float? = null,
    ): List<ClipTrimResult?> = VideoGlobalTrimCalculator.applyGlobalTrim(
        clips = clips,
        globalStartUs = globalStartUs,
        globalEndUs = globalEndUs,
        globalPlaybackSpeed = globalPlaybackSpeed,
    )

    /**
     * Regression for the reported bug: a single 12s clip sped up 2x produces a
     * 6s output, which fits inside a 6.3s output cap, so the FULL source must be
     * kept — it must NOT be trimmed to the first 6.3s of source.
     */
    @Test
    fun keepsFullSource_whenSpedUpClipFitsInOutputCap() {
        val result = trim(
            clips = listOf(ClipInput(0L, 12_000_000L, 2f, reverseVideo = false)),
            globalEndUs = 6_300_000L,
        )
        assertEquals(ClipTrimResult(0L, 12_000_000L), result[0])
    }

    @Test
    fun trimsSource_whenSpedUpClipExceedsOutputCap() {
        // source 20s @ 2x => output 10s, cap 6.3s => keep ~12.6s of source.
        // endTrim(output) = 10s - 6.3s = 3.7s; * 2 = 7.4s source; minus 1 frame.
        val result = trim(
            clips = listOf(ClipInput(0L, 20_000_000L, 2f, reverseVideo = false)),
            globalEndUs = 6_300_000L,
        )
        assertEquals(ClipTrimResult(0L, 12_566_667L), result[0])
    }

    @Test
    fun keepsBothClips_whenCombinedOutputFitsInCap() {
        // two 4s clips @ 2x => 2s each => 4s total output, cap 6.3s => keep both.
        val clip = ClipInput(0L, 4_000_000L, 2f, reverseVideo = false)
        val result = trim(
            clips = listOf(clip, clip),
            globalEndUs = 6_300_000L,
        )
        assertEquals(ClipTrimResult(0L, 4_000_000L), result[0])
        assertEquals(ClipTrimResult(0L, 4_000_000L), result[1])
    }

    @Test
    fun trimsSource_whenSlowedDownClipExceedsOutputCap() {
        // source 4s @ 0.5x => output 8s, cap 6.3s.
        // endTrim(output) = 8s - 6.3s = 1.7s; * 0.5 = 0.85s source; minus 1 frame.
        val result = trim(
            clips = listOf(ClipInput(0L, 4_000_000L, 0.5f, reverseVideo = false)),
            globalEndUs = 6_300_000L,
        )
        assertEquals(ClipTrimResult(0L, 3_116_667L), result[0])
    }

    @Test
    fun combinesGlobalAndPerClipSpeed_whenResolvingCap() {
        // source 12s @ clip 2x * global 2x = 4x => output 3s, cap 2s.
        // endTrim(output) = 1s; * 4 = 4s source; minus 1 frame.
        val result = trim(
            clips = listOf(ClipInput(0L, 12_000_000L, 2f, reverseVideo = false)),
            globalEndUs = 2_000_000L,
            globalPlaybackSpeed = 2f,
        )
        assertEquals(ClipTrimResult(0L, 7_966_667L), result[0])
    }

    @Test
    fun mapsEndTrimToSourceTail_forReversedClip() {
        // reversed source 20s @ 2x => output 10s, cap 6.3s. The output head maps
        // to the source tail, so the end trim raises the source start instead.
        val result = trim(
            clips = listOf(ClipInput(0L, 20_000_000L, 2f, reverseVideo = true)),
            globalEndUs = 6_300_000L,
        )
        assertEquals(ClipTrimResult(7_433_333L, 20_000_000L), result[0])
    }

    @Test
    fun dropsClipBeforeStart_andMapsStartTrimToSource() {
        // two 4s clips @ 2x => 2s each. Global start 2.5s (output) drops clip 1
        // entirely and cuts 0.5s of output (= 1s source @ 2x) off clip 2's head.
        val clip = ClipInput(0L, 4_000_000L, 2f, reverseVideo = false)
        val result = trim(
            clips = listOf(clip, clip),
            globalStartUs = 2_500_000L,
        )
        assertNull(result[0])
        assertEquals(ClipTrimResult(1_000_000L, 4_000_000L), result[1])
    }

    @Test
    fun returnsClipsUnchanged_whenNoGlobalTrimSet() {
        val result = trim(
            clips = listOf(ClipInput(1_000_000L, 5_000_000L, 2f, reverseVideo = false)),
        )
        assertEquals(ClipTrimResult(1_000_000L, 5_000_000L), result[0])
    }

    @Test
    fun capsASpeedRampedClipOnItsOutputAndCropsTheRamp() {
        // 3 s of source: 1.2 s at 2x (0.6 s), 0.6 s at 0.25x (2.4 s), 1.2 s at
        // 2x (0.6 s), so 3.6 s of output. A 3.3 s cap cuts the last 0.3 s of
        // output, 0.6 s of source at 2x.
        val ramp = SpeedRamp(
            listOf(
                SpeedRamp.Step(0.0, 0.4, 2.0),
                SpeedRamp.Step(0.4, 0.6, 0.25),
                SpeedRamp.Step(0.6, 1.0, 2.0),
            )
        )
        val result = VideoGlobalTrimCalculator.applyGlobalTrim(
            clips = listOf(ClipInput(0L, 3_000_000L, null, reverseVideo = false, speedRamp = ramp)),
            globalStartUs = null,
            globalEndUs = 3_300_000L,
            globalPlaybackSpeed = null,
            frameCompensationUs = 0L,
        )

        val trimmed = result[0]!!
        assertEquals(0L, trimmed.sourceStartUs)
        assertEquals(2_400_000L, trimmed.sourceEndUs)
        // The kept 2.4 s still play their stretch of the ramp: 0.6 + 2.4 + 0.3.
        assertEquals(3_300_000L, trimmed.speedRamp!!.outputDurationUs(2_400_000L))
    }
}
