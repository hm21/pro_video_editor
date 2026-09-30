package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class VideoEffectConfigTest {

    /** A table whose frame `i` has a pixel size of `i / 100`. */
    private fun table(count: Int): DoubleArray {
        val values = DoubleArray(count * VideoEffectFrame.STRIDE)
        for (i in 0 until count) values[i * VideoEffectFrame.STRIDE] = i / 100.0
        return values
    }

    private fun effect(count: Int, startUs: Long? = null, endUs: Long? = null) =
        VideoEffectConfig.fromMap(
            mapOf(
                "startUs" to startUs,
                "endUs" to endUs,
                "frameRate" to 24,
                "stride" to VideoEffectFrame.STRIDE,
                "frames" to table(count),
            )
        )!!

    @Test
    fun frameAt_countsBucketsFromTheEffectsStartAndLoops() {
        val effect = effect(count = 3, startUs = 1_000_000)
        // 24 buckets per second: 1 s + 1/24 s is bucket 1.
        assertEquals(0.0, effect.frameAt(1_000_000)!!.pixelSize)
        assertEquals(0.01, effect.frameAt(1_041_667)!!.pixelSize)
        // Bucket 3 wraps back to frame 0.
        assertEquals(0.0, effect.frameAt(1_125_000)!!.pixelSize)
    }

    @Test
    fun frameAt_isNullOutsideTheHalfOpenRange() {
        val effect = effect(count = 1, startUs = 500_000, endUs = 900_000)
        assertNull(effect.frameAt(499_999))
        assertEquals(0.0, effect.frameAt(500_000)!!.pixelSize)
        assertNull(effect.frameAt(900_000))
    }

    @Test
    fun fromMap_readsBandsAndRejectsAForeignLayout() {
        val values = DoubleArray(VideoEffectFrame.STRIDE)
        values[8] = 2.0
        values[9] = 0.1; values[10] = 0.2; values[11] = 0.3
        values[12] = 0.4; values[13] = 0.5; values[14] = -0.6
        val parsed = VideoEffectConfig.fromMap(
            mapOf("stride" to VideoEffectFrame.STRIDE, "frames" to values.toList())
        )!!
        assertEquals(
            listOf(VideoEffectBand(0.1, 0.2, 0.3), VideoEffectBand(0.4, 0.5, -0.6)),
            parsed.frameAt(0)!!.bands,
        )
        assertNull(VideoEffectConfig.fromMap(mapOf("stride" to 3, "frames" to DoubleArray(3))))
    }

    @Test
    fun resolve_mergesOverlappingEffectsLikeDart() {
        val pixelate = VideoEffectFrame(pixelSize = 0.05, rgbShift = 0.01)
        val vhs = VideoEffectFrame(
            rgbShift = 0.006,
            scanlines = 0.3,
            scanlinePeriod = 1 / 270.0,
            noise = 0.2,
            noiseCellSize = 1 / 540.0,
            noiseOffsetX = 9,
            noiseOffsetY = 4,
            bands = listOf(VideoEffectBand(0.1, 0.2, 0.01)),
        )
        val merged = VideoEffectConfig.resolve(
            listOf(
                VideoEffectConfig(null, null, 24, listOf(pixelate)),
                VideoEffectConfig(null, 1_000, 24, listOf(vhs)),
            ),
            timeUs = 0,
        )
        assertEquals(0.05, merged.pixelSize)
        assertEquals(0.016, merged.rgbShift, 1e-12)
        assertEquals(0.3, merged.scanlines)
        assertEquals(9, merged.noiseOffsetX)
        assertEquals(vhs.bands, merged.bands)

        // Past the second effect's end only the first applies.
        assertEquals(pixelate, VideoEffectConfig.resolve(
            listOf(
                VideoEffectConfig(null, null, 24, listOf(pixelate)),
                VideoEffectConfig(null, 1_000, 24, listOf(vhs)),
            ),
            timeUs = 1_000,
        ))
    }

    @Test
    fun timeAfterSpeedChangeUs_movesFramesLikeTheClipsSpeedChange() {
        // A clip whose frames arrive from 3 s on: Media3's speed change keeps
        // the first frame where it is and scales the gaps after it.
        assertEquals(3_000_000, VideoEffectConfig.timeAfterSpeedChangeUs(3_000_000, 3_000_000, 2f))
        assertEquals(3_500_000, VideoEffectConfig.timeAfterSpeedChangeUs(4_000_000, 3_000_000, 2f))
        assertEquals(5_000_000, VideoEffectConfig.timeAfterSpeedChangeUs(4_000_000, 3_000_000, 0.5f))
        assertEquals(4_000_000, VideoEffectConfig.timeAfterSpeedChangeUs(4_000_000, 3_000_000, 1f))
    }

    @Test
    fun merge_combinesTonesLikeDart() {
        val oldFilm = VideoEffectFrame(sepia = 0.8, brightness = 0.03, vignette = 0.5, vignetteRadius = 0.3)
        val strobe = VideoEffectFrame(brightness = -0.01, flash = 0.9, invert = 0.2)
        val vignette = VideoEffectFrame(vignette = 0.7, vignetteRadius = 0.4)
        val merged = oldFilm.merge(strobe).merge(vignette)
        assertEquals(0.8, merged.sepia)
        assertEquals(0.02, merged.brightness, 1e-12)
        assertEquals(0.2, merged.invert)
        assertEquals(0.9, merged.flash)
        assertEquals(0.7, merged.vignette)
        assertEquals(0.4, merged.vignetteRadius)
    }

    @Test
    fun fromArray_readsTheTonesAfterTheBands() {
        val values = DoubleArray(VideoEffectFrame.STRIDE)
        for (i in 0 until 6) values[VideoEffectFrame.STRIDE - 6 + i] = (i + 1) / 10.0
        val frame = VideoEffectFrame.fromArray(values, 0)
        assertEquals(
            listOf(0.1, 0.2, 0.3, 0.4, 0.5, 0.6),
            listOf(frame.sepia, frame.brightness, frame.invert, frame.flash, frame.vignette, frame.vignetteRadius),
        )
    }
}
