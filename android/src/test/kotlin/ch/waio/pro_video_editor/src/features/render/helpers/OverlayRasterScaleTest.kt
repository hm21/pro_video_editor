package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [overlayRasterScale], the ceiling on how large an overlay is rastered.
 *
 * Overlays are laid out in the composition's pixel space — the source clip's own
 * resolution — and a custom output resolution is applied *after* them, so an
 * overlay rastered above that ratio has its extra pixels discarded before
 * anything is encoded. It is not free: `unpremultiplyAlpha` needs two full-frame
 * Java-heap buffers per layer against Android's 256 MiB growth limit, and every
 * prepared overlay stays resident for the whole render.
 *
 * The scale must therefore shrink only what the output cannot show, and must be
 * exactly `1f` everywhere else — a cap applied where it is not warranted would
 * soften overlays on an export that could display them.
 */
internal class OverlayRasterScaleTest {

    @Test
    fun a4kSourceExportedAt1080pRastersAtHalf() {
        assertEquals(
            0.5f,
            overlayRasterScale(
                videoWidth = 2160, videoHeight = 3840,
                outputWidth = 1080, outputHeight = 1920,
            ),
        )
    }

    /** The axis that binds first decides, because SCALE_TO_FIT keeps the ratio. */
    @Test
    fun theTighterAxisWins() {
        assertEquals(
            0.25f,
            overlayRasterScale(
                videoWidth = 4000, videoHeight = 1000,
                outputWidth = 1000, outputHeight = 1000,
            ),
        )
    }

    @Test
    fun aMatchingOutputIsNotCapped() {
        assertEquals(
            1f,
            overlayRasterScale(
                videoWidth = 1080, videoHeight = 1920,
                outputWidth = 1080, outputHeight = 1920,
            ),
        )
    }

    /** Upscaling to the output would only cost memory for pixels nobody drew. */
    @Test
    fun anOutputLargerThanTheCompositionIsNotCapped() {
        assertEquals(
            1f,
            overlayRasterScale(
                videoWidth = 1080, videoHeight = 1920,
                outputWidth = 2160, outputHeight = 3840,
            ),
        )
    }

    /** No custom output resolution means no downscale to size the overlay against. */
    @Test
    fun noOutputResolutionIsNotCapped() {
        assertEquals(1f, overlayRasterScale(2160, 3840, null, null))
        assertEquals(1f, overlayRasterScale(2160, 3840, 1080, null))
        assertEquals(1f, overlayRasterScale(2160, 3840, null, 1920))
    }

    @Test
    fun degenerateDimensionsAreNotCapped() {
        assertEquals(1f, overlayRasterScale(0, 3840, 1080, 1920))
        assertEquals(1f, overlayRasterScale(2160, 0, 1080, 1920))
        assertEquals(1f, overlayRasterScale(2160, 3840, 0, 1920))
        assertEquals(1f, overlayRasterScale(2160, 3840, 1080, 0))
    }

    /** The cap reaches the decode, so the reduced raster is never allocated large. */
    @Test
    fun theDecodeTargetFollowsTheCap() {
        val layer = VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = 2160.0, height = 3840.0, x = 0, y = 0,
        )

        assertEquals(
            Pair(1080, 1920),
            overlayDecodeSize(layer, 2160, 3840, rasterScale = 0.5f),
        )
    }

    /**
     * A positioned layer with no explicit size is laid out from its own pixel
     * dimensions, so the cap must not reach it — [prepareOverlay] leaves that
     * raster alone and would otherwise scale the overlay up against nothing.
     */
    @Test
    fun aNaturallySizedLayerIsNotCapped() {
        val layer = VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = null, height = null, x = 40, y = 80,
        )

        assertEquals(
            Pair(0, 0),
            overlayDecodeSize(layer, 2160, 3840, rasterScale = 0.5f),
        )
    }

    /** A cap can round down to nothing on a thin layer; one pixel is the floor. */
    @Test
    fun aThinLayerKeepsAtLeastOnePixelPerAxis() {
        val layer = VideoSequenceBuilder.ImageLayerConfig(
            image = null, scaleX = null, scaleY = null,
            width = 3.0, height = 2000.0, x = 0, y = 0,
        )

        assertEquals(
            Pair(1, 200),
            overlayDecodeSize(layer, 2160, 3840, rasterScale = 0.1f),
        )
    }

    /**
     * The compensation Media3 is handed must return each axis to the size the
     * layer was laid out at — read off that axis' own raster, not off the cap.
     *
     * The floor and the rounding move the two axes by different amounts: the
     * thin layer above lands on 1 x 200 for a declared 3 x 2000, so its short
     * axis needs 3x and its long axis 10x. One shared factor would render it at
     * a third of its height.
     */
    @Test
    fun theCompensationReturnsEachAxisToItsDisplaySize() {
        assertEquals(3f, rasterCompensation(displaySize = 3, rasterSize = 1))
        assertEquals(10f, rasterCompensation(displaySize = 2000, rasterSize = 200))
    }

    @Test
    fun anUncappedAxisIsNotCompensated() {
        assertEquals(1f, rasterCompensation(displaySize = 1080, rasterSize = 1080))
        assertEquals(1f, rasterCompensation(displaySize = 1080, rasterSize = 0))
    }
}
