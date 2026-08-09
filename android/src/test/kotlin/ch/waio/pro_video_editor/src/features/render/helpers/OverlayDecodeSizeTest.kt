package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [overlayDecodeSize] to the branching [prepareOverlay] actually does.
 *
 * An image layer is decoded no larger than the size it is about to be scaled
 * down to, because a full-resolution decode of a phone photo costs a *second*
 * full-resolution copy when its EXIF orientation has to be turned — the point
 * where an overlay runs out of memory. That only holds while this function and
 * `prepareOverlay` agree on which layers get scaled and to what; if they drift,
 * a layer starts being sampled below the resolution it keeps, so the two are
 * pinned together here.
 */
internal class OverlayDecodeSizeTest {

    private val videoWidth = 1920
    private val videoHeight = 1080

    private fun layer(
        width: Double? = null,
        height: Double? = null,
        x: Int? = null,
        y: Int? = null,
    ) = VideoSequenceBuilder.ImageLayerConfig(
        image = null,
        scaleX = null,
        scaleY = null,
        width = width,
        height = height,
        x = x,
        y = y,
    )

    @Test
    fun explicitSizeIsTheDecodeTarget() {
        val size = overlayDecodeSize(
            layer(width = 480.0, height = 270.0, x = 100, y = 50), videoWidth, videoHeight
        )

        assertEquals(Pair(480, 270), size)
    }

    /** An explicit size wins even when the layer is also stretched. */
    @Test
    fun explicitSizeWinsOverTheFrame() {
        val size = overlayDecodeSize(
            layer(width = 480.0, height = 270.0), videoWidth, videoHeight
        )

        assertEquals(Pair(480, 270), size)
    }

    @Test
    fun aStretchedLayerIsDecodedToTheFrame() {
        val size = overlayDecodeSize(layer(), videoWidth, videoHeight)

        assertEquals(Pair(videoWidth, videoHeight), size)
    }

    /**
     * The case that must *not* downscale: a positioned layer with no explicit
     * size is laid out from its own pixel dimensions, so sampling it down would
     * shrink the rendered overlay.
     */
    @Test
    fun aPositionedLayerWithoutASizeKeepsItsOwnResolution() {
        assertEquals(Pair(0, 0), overlayDecodeSize(layer(x = 40, y = 80), videoWidth, videoHeight))
        assertEquals(Pair(0, 0), overlayDecodeSize(layer(x = 40), videoWidth, videoHeight))
        assertEquals(Pair(0, 0), overlayDecodeSize(layer(y = 80), videoWidth, videoHeight))
    }

    /** Half a size is no size: both dimensions are needed to scale to one. */
    @Test
    fun aHalfSpecifiedSizeIsNotADecodeTarget() {
        assertEquals(
            Pair(0, 0),
            overlayDecodeSize(layer(width = 480.0, x = 10, y = 10), videoWidth, videoHeight)
        )
        assertEquals(
            Pair(videoWidth, videoHeight),
            overlayDecodeSize(layer(height = 270.0), videoWidth, videoHeight)
        )
    }
}
