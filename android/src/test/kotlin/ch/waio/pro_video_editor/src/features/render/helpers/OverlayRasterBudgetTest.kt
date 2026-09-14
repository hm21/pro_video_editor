package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins [overlayRasterBudget], the ceiling on how many pixels one overlay may
 * be rastered at, and how [overlayDecodeSize] holds a layer under it.
 *
 * [overlayRasterScale] shrinks an overlay by the ratio the frame is scaled by,
 * which bounds nothing for a layer that is larger than the frame itself: a
 * sticker pinched far past the canvas is laid out at that size and was rastered
 * whole, though only the slice inside the frame is visible. Every fatal
 * `unpremultiplyAlpha` OOM in the downstream crash data was one such layer, at
 * 32 to 147 million pixels against a 256 MiB heap.
 *
 * The budget must leave every layer that fits its allowance untouched — the
 * cap is compensated by an overlay scale, so a raster it does not shrink is
 * pixel-identical to before — and shrink an oversized one on both axes alike.
 */
internal class OverlayRasterBudgetTest {

    private fun sized(width: Double, height: Double) =
        VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = width, height = height, x = 0, y = 0,
        )

    @Test
    fun aBudgetIsFourFramesOfTheRasteredFrame() {
        assertEquals(4L * 1080 * 1920, overlayRasterBudget(1080, 1920, rasterScale = 1f))
    }

    /** The frame counts as it is rastered: a 4K frame at half scale is a 1080p frame. */
    @Test
    fun theBudgetFollowsTheRatioCap() {
        assertEquals(
            overlayRasterBudget(1080, 1920, rasterScale = 1f),
            overlayRasterBudget(2160, 3840, rasterScale = 0.5f),
        )
    }

    /** Four 4K frames would be 133 MB of RGBA; the absolute ceiling holds it at 64 MiB. */
    @Test
    fun aLargeFrameIsHeldToTheAbsoluteCeiling() {
        assertEquals(OVERLAY_RASTER_MAX_PIXELS, overlayRasterBudget(2160, 3840, rasterScale = 1f))
        assertEquals(4096L * 4096L, OVERLAY_RASTER_MAX_PIXELS)
    }

    @Test
    fun aDegenerateFrameLeavesOnlyTheAbsoluteCeiling() {
        assertEquals(OVERLAY_RASTER_MAX_PIXELS, overlayRasterBudget(0, 1920, rasterScale = 1f))
        assertEquals(OVERLAY_RASTER_MAX_PIXELS, overlayRasterBudget(1080, -1, rasterScale = 1f))
    }

    /**
     * The shape behind the crash: a layer laid out at 10 954 x 13 412 on a
     * 1080 x 1920 export — 147 million pixels, 588 MB — is rastered at the
     * four-frame budget, in its own proportions.
     */
    @Test
    fun anOversizedLayerIsHeldToTheBudget() {
        val budget = overlayRasterBudget(1080, 1920, rasterScale = 1f)

        val (width, height) = overlayDecodeSize(
            sized(10954.0, 13412.0), 1080, 1920,
            rasterScale = 1f, rasterBudget = budget,
        )

        assertEquals(Pair(2603, 3187), Pair(width, height))
        // Whole-pixel rounding may leave the product a row over; no more.
        assertTrue(width.toLong() * height <= budget + maxOf(width, height))
    }

    /** The ratio cap and the budget compose to the same raster a 1080p source gets. */
    @Test
    fun theBudgetComposesWithTheRatioCap() {
        assertEquals(
            Pair(2603, 3187),
            overlayDecodeSize(
                sized(10954.0, 13412.0), 2160, 3840,
                rasterScale = 0.5f,
                rasterBudget = overlayRasterBudget(2160, 3840, rasterScale = 0.5f),
            ),
        )
    }

    /** A layer within its allowance is not touched, so its raster stays pixel-identical. */
    @Test
    fun aLayerWithinTheBudgetIsNotCapped() {
        val budget = overlayRasterBudget(1080, 1920, rasterScale = 1f)

        assertEquals(
            Pair(1080, 1920),
            overlayDecodeSize(sized(1080.0, 1920.0), 1080, 1920, 1f, budget),
        )
        // Exactly twice the frame on each axis is exactly the budget.
        assertEquals(
            Pair(2160, 3840),
            overlayDecodeSize(sized(2160.0, 3840.0), 1080, 1920, 1f, budget),
        )
    }

    /** A long thin layer has few pixels however long it is. */
    @Test
    fun aThinLayerIsNotCapped() {
        val budget = overlayRasterBudget(1080, 1920, rasterScale = 1f)

        assertEquals(
            Pair(3, 200000),
            overlayDecodeSize(sized(3.0, 200000.0), 1080, 1920, 1f, budget),
        )
    }

    /** A stretched layer is the frame, which the budget always allows. */
    @Test
    fun aStretchedLayerIsNotCapped() {
        val stretched = VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = null, height = null, x = null, y = null,
        )
        val budget = overlayRasterBudget(2160, 3840, rasterScale = 1f)

        assertEquals(Pair(2160, 3840), overlayDecodeSize(stretched, 2160, 3840, 1f, budget))
    }

    @Test
    fun theAbsoluteCeilingBindsOnALargeExport() {
        val budget = overlayRasterBudget(2160, 3840, rasterScale = 1f)

        assertEquals(
            Pair(3072, 5461),
            overlayDecodeSize(sized(6480.0, 11520.0), 2160, 3840, 1f, budget),
        )
        assertEquals(
            Pair(4096, 4096),
            overlayDecodeSize(sized(20000.0, 20000.0), 2160, 3840, 1f, budget),
        )
    }

    /** The compensation reads each axis off its own raster, so the extent is unchanged. */
    @Test
    fun aBudgetedRasterIsCompensatedBackToItsLayout() {
        assertEquals(10954f / 2603f, rasterCompensation(displaySize = 10954, rasterSize = 2603))
        assertEquals(13412f / 3187f, rasterCompensation(displaySize = 13412, rasterSize = 3187))
    }

    /** Without a budget the decode target is exactly what it was before the budget existed. */
    @Test
    fun noBudgetLeavesTheRatioCapAlone() {
        assertEquals(
            Pair(1080, 1920),
            overlayDecodeSize(sized(2160.0, 3840.0), 2160, 3840, rasterScale = 0.5f),
        )
    }

    @Test
    fun theOutOfMemoryExceptionNamesTheLayout() {
        val exception = OverlayOutOfMemoryException(
            sized(10954.0, 13412.0), 1080, 1920,
            OutOfMemoryError("Failed to allocate a 587660211 byte allocation"),
        )

        assertEquals(
            "Out of memory rastering an overlay laid out at 10954 x 13412 px: " +
                "Failed to allocate a 587660211 byte allocation",
            exception.message,
        )
    }

    /** A stretched layer is laid out at the frame, and an error may carry no message. */
    @Test
    fun theOutOfMemoryExceptionNamesTheFrameForAStretchedLayer() {
        val stretched = VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = null, height = null, x = null, y = null,
        )

        val exception = OverlayOutOfMemoryException(stretched, 2160, 3840, OutOfMemoryError())

        assertEquals(
            "Out of memory rastering an overlay laid out at 2160 x 3840 px (frame): no message",
            exception.message,
        )
    }
}
