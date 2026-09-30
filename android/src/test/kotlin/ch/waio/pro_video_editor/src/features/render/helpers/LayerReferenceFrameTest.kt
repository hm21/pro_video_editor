package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * Pins [LayerReferenceFrame] to the frame iOS and macOS lay image layers out
 * in, and [scaledToClipFrame] to landing a layer on the same part of a clip of
 * another size.
 */
internal class LayerReferenceFrameTest {

    private fun layer(
        x: Int? = null,
        y: Int? = null,
        width: Double? = null,
        height: Double? = null,
        animations: List<LayerAnimationConfig> = emptyList(),
    ) = VideoSequenceBuilder.ImageLayerConfig(
        image = null,
        scaleX = null,
        scaleY = null,
        x = x,
        y = y,
        width = width,
        height = height,
        animations = animations,
    )

    @Test
    fun theFrameIsTheFirstClipWhenNoLaterClipOutgrowsIt() {
        val frame = LayerReferenceFrame.of(listOf(1080 to 1080, 720 to 720))

        assertEquals(1080 to 1080, frame)
    }

    @Test
    fun aLaterLargerClipBecomesTheFrame() {
        val frame = LayerReferenceFrame.of(listOf(480 to 480, 1080 to 1080, 720 to 720))

        assertEquals(1080 to 1080, frame)
    }

    /**
     * Apple replaces the render size with any clip that is wider *or* taller,
     * so a landscape clip after a portrait one of the same area takes over.
     */
    @Test
    fun aClipWiderOnOneAxisReplacesTheFrameAsOnApple() {
        val frame = LayerReferenceFrame.of(listOf(1080 to 1920, 1920 to 1080))

        assertEquals(1920 to 1080, frame)
    }

    @Test
    fun aClipWhoseSizeCouldNotBeReadIsSkipped() {
        val frame = LayerReferenceFrame.of(listOf(0 to 0, 720 to 1280, 0 to 1920))

        assertEquals(720 to 1280, frame)
    }

    @Test
    fun noUsableSizeMeansNoFrame() {
        assertNull(LayerReferenceFrame.of(listOf(0 to 0)))
        assertNull(LayerReferenceFrame.of(emptyList()))
    }

    @Test
    fun aClipOfTheFramesSizeKeepsItsLayers() {
        val scale = LayerReferenceFrame.layoutScale(1080, 1080, 1080 to 1080)
        val original = layer(x = 360, y = 450, width = 358.0, height = 178.0)

        assertEquals(1.0, scale)
        assertSame(original, original.scaledToClipFrame(scale))
    }

    @Test
    fun anUnknownSizeKeepsTheLayers() {
        assertEquals(1.0, LayerReferenceFrame.layoutScale(0, 0, 1080 to 1080))
        assertEquals(1.0, LayerReferenceFrame.layoutScale(720, 720, null))
    }

    /** A clip that is letterboxed into the frame is fitted by its binding axis. */
    @Test
    fun aClipOfAnotherShapeIsFittedByItsBindingAxis() {
        // 1920x1080 fits a 1080x1920 frame at 0.5625: 1.78 clip px per frame px.
        val scale = LayerReferenceFrame.layoutScale(1920, 1080, 1080 to 1920)

        assertEquals(1920.0 / 1080.0, scale, 1e-9)
    }

    /**
     * The layers from the Android square-export report: laid out for the
     * first, 1080² segment, they have to cover the same part of the 720²
     * segment that follows it.
     */
    @Test
    fun aLayerLandsOnTheSamePartOfASmallerClip() {
        val frame = LayerReferenceFrame.of(listOf(1080 to 1080, 720 to 720))
        val scale = LayerReferenceFrame.layoutScale(720, 720, frame)
        val centre = layer(x = 360, y = 450, width = 358.0, height = 178.0)
        val lower = layer(x = 360, y = 810, width = 358.0, height = 178.0)

        val onClip = centre.scaledToClipFrame(scale)
        val lowerOnClip = lower.scaledToClipFrame(scale)

        assertEquals(240, onClip.x)
        assertEquals(300, onClip.y)
        assertEquals(358.0 * 720 / 1080, onClip.width!!, 1e-9)
        assertEquals(178.0 * 720 / 1080, onClip.height!!, 1e-9)
        // Still inside the clip, where it sat inside the first segment.
        assertEquals(540, lowerOnClip.y)
        assertEquals(
            (810.0 + 178.0) / 1080,
            (lowerOnClip.y!! + lowerOnClip.height!!) / 720,
            1e-3,
        )
    }

    /**
     * A slide start point is a pixel position too; the offset it produces has
     * to match what the same layer gets on a frame-sized clip.
     */
    @Test
    fun aSlideStartPointMovesWithTheLayer() {
        val slide = LayerAnimationConfig(
            type = "slide",
            phase = "animateIn",
            durationUs = 500_000,
            slideFromX = -200.0,
            slideFromY = 900.0,
        )
        val original = layer(
            x = 360, y = 450, width = 358.0, height = 178.0, animations = listOf(slide),
        )

        val onClip = original.scaledToClipFrame(720.0 / 1080.0)
        val scaled = onClip.animations.single()

        val expected = slideFromOffset(
            1f, -200f, 900f, 360f, 450f, 1080, 1080,
        )
        val actual = slideFromOffset(
            1f, scaled.slideFromX!!.toFloat(), scaled.slideFromY!!.toFloat(),
            onClip.x!!.toFloat(), onClip.y!!.toFloat(), 720, 720,
        )
        assertEquals(expected.x, actual.x, 1e-6f)
        assertEquals(expected.y, actual.y, 1e-6f)
    }

    @Test
    fun aLayerWithoutAnExplicitSizeScalesItsNaturalSize() {
        val natural = layer(x = 540, y = 540)

        val onClip = natural.scaledToClipFrame(0.5)

        assertEquals(270, onClip.x)
        assertEquals(270, onClip.y)
        assertNull(onClip.width)
        assertEquals(0.5, onClip.naturalSizeScale)
    }

    /** A stretched layer fills whatever frame it lands on. */
    @Test
    fun aStretchedLayerStaysStretched() {
        val stretched = layer()

        val onClip = stretched.scaledToClipFrame(0.5)

        assertNull(onClip.x)
        assertNull(onClip.y)
    }
}
