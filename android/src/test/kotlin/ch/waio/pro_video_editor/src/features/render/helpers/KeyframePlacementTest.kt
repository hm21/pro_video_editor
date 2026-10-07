package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.KeyframeConfig
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import ch.waio.pro_video_editor.src.features.render.models.SegmentTransformConfig
import kotlin.math.PI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins how keyframes place a layer: [keyframePlacementAt], the overlay frame of
 * an image layer and the placement of a composition clip. The editor preview
 * in `pro_image_editor` mixes keyframes the same way.
 */
internal class KeyframePlacementTest {

    private val tol = 1e-6

    private fun keyframe(
        timeUs: Long,
        x: Double = 0.0,
        y: Double = 0.0,
        scale: Double = 1.0,
        rotation: Double = 0.0,
        opacity: Double = 1.0,
        curve: String = "linear",
    ) = KeyframeConfig(timeUs, x, y, scale, rotation, opacity, curve)

    private val path = listOf(
        keyframe(1_000_000L, x = -100.0, opacity = 0.5),
        keyframe(3_000_000L, x = 100.0, y = 200.0, scale = 3.0, rotation = 2 * PI),
    )

    @Test
    fun `no keyframes place nothing`() {
        assertNull(keyframePlacementAt(emptyList(), 0L))
    }

    @Test
    fun `holds the first keyframe before it and the last after it`() {
        assertEquals(-100.0, keyframePlacementAt(path, 0L)!!.x, tol)
        val after = keyframePlacementAt(path, 9_000_000L)!!
        assertEquals(100.0, after.x, tol)
        assertEquals(3.0, after.scale, tol)
    }

    @Test
    fun `mixes linearly between two keyframes and keeps a full turn`() {
        val placement = keyframePlacementAt(path, 2_000_000L)!!
        assertEquals(0.0, placement.x, tol)
        assertEquals(100.0, placement.y, tol)
        assertEquals(2.0, placement.scale, tol)
        assertEquals(0.75, placement.opacity, tol)
        assertEquals(PI, placement.rotation, tol)
    }

    @Test
    fun `eases with the curve of the earlier keyframe`() {
        val eased = listOf(
            keyframe(0L, curve = "easeIn"),
            keyframe(1_000_000L, x = 100.0),
        )
        assertEquals(25.0, keyframePlacementAt(eased, 500_000L)!!.x, tol)
    }

    @Test
    fun `keeps opacity within 0 to 1 and scale at 0 or more when a curve overshoots`() {
        val springy = listOf(
            keyframe(0L, opacity = 0.0, curve = "elasticOut"),
            keyframe(1_000_000L, scale = 0.0, opacity = 1.0),
        )
        for (t in 0L..1_000_000L step 10_000L) {
            val placement = keyframePlacementAt(springy, t)!!
            assertTrue(placement.opacity in 0.0..1.0)
            assertTrue(placement.scale >= 0.0)
        }
    }

    @Test
    fun `listFrom sorts by time`() {
        val keyframes = KeyframeConfig.listFrom(
            listOf(
                mapOf("timeUs" to 900, "x" to 1),
                mapOf("timeUs" to 100, "x" to 2, "curve" to "easeOut"),
            )
        )
        assertEquals(listOf(100L, 900L), keyframes.map { it.timeUs })
        assertEquals("easeOut", keyframes.first().curve)
        assertEquals(1.0, keyframes.first().scale, tol)
    }

    // ---- Image layers --------------------------------------------------------

    /** A 200 x 100 layer on a 1000 x 1000 frame. */
    private fun frame(
        keyframes: List<KeyframeConfig>,
        timeUs: Long,
        animations: List<LayerAnimationConfig> = emptyList(),
    ) = overlayFrame(
        keyframes = keyframes,
        animations = animations,
        timeUs = timeUs,
        animationStartUs = 0L,
        animationEndUs = 10_000_000L,
        baseNormX = 0f,
        baseNormY = 0f,
        imageWidth = 200,
        imageHeight = 100,
        videoWidth = 1000,
        videoHeight = 1000,
        layerX = 400f,
        layerY = 450f,
    )

    @Test
    fun `an overlay without keyframes stays on its resting place`() {
        val frame = frame(emptyList(), 0L)
        assertEquals(0f, frame.backgroundAnchorX, 1e-6f)
        assertEquals(0f, frame.backgroundAnchorY, 1e-6f)
        assertEquals(1f, frame.scale, 1e-6f)
        assertEquals(0f, frame.rotationDegrees, 1e-6f)
        assertEquals(1f, frame.alpha, 1e-6f)
    }

    @Test
    fun `keyframes place, scale, turn and fade the overlay`() {
        // Top-left (0, 0): the 200 x 100 box is centered at (100, 50), which is
        // (-0.8, 0.9) in Media3's y-up [-1, 1] space.
        val frame = frame(
            listOf(keyframe(0L, scale = 2.0, rotation = PI / 2, opacity = 0.25)),
            0L,
        )
        assertEquals(-0.8f, frame.backgroundAnchorX, 1e-6f)
        assertEquals(0.9f, frame.backgroundAnchorY, 1e-6f)
        assertEquals(2f, frame.scale, 1e-6f)
        // Clockwise in Flutter, counter-clockwise in Media3.
        assertEquals(-90f, frame.rotationDegrees, 1e-4f)
        assertEquals(0.25f, frame.alpha, 1e-6f)
    }

    @Test
    fun `a slide starts from the edge nearest the keyframed place`() {
        // At the start of a slide in from the left, the doubled layer's right
        // edge sits on the frame's left edge whatever the keyframe's place.
        val frame = frame(
            listOf(keyframe(0L, x = 600.0, y = 450.0, scale = 2.0)),
            0L,
            animations = listOf(
                LayerAnimationConfig(
                    type = "slide", phase = "animateIn", durationUs = 1_000_000L,
                    slideDirection = "left",
                )
            ),
        )
        // Center x, as Media3 places it: background anchor minus the overlay
        // anchor's share of the doubled half width (0.4).
        val centerX = frame.backgroundAnchorX - frame.overlayAnchorX * 0.4f
        assertEquals(-1f - 0.4f, centerX, 1e-5f)
    }

    @Test
    fun `a bounce lifts by the keyframed height`() {
        val bounce = LayerAnimationConfig(
            type = "bounce", phase = "animateIn", durationUs = 1_000_000L,
            bounceHeight = 1.0,
        )
        val plain = frame(listOf(keyframe(0L, x = 400.0, y = 450.0)), 0L, listOf(bounce))
        val doubled = frame(
            listOf(keyframe(0L, x = 400.0, y = 450.0, scale = 2.0)), 0L, listOf(bounce)
        )
        // Lifted by its whole height, 0.2 in y-up units, and twice that doubled.
        assertEquals(0.2f, plain.backgroundAnchorY, 1e-5f)
        assertEquals(0.4f, doubled.backgroundAnchorY, 1e-5f)
    }

    @Test
    fun `a turned layer wholly off the frame is hidden`() {
        // Centered 500 px left of the frame: the anchors can only bring it to
        // 100 px left of it, where its 45° corners would reach 6 px in.
        val off = frame(listOf(keyframe(0L, x = -600.0, y = 450.0, rotation = PI / 4)), 0L)
        assertEquals(0f, off.alpha, 1e-6f)
    }

    @Test
    fun `a turned layer partly on the frame stays visible`() {
        // Centered 50 px left of the frame, its 45° corner reaches 56 px in.
        val partly = frame(
            listOf(keyframe(0L, x = -150.0, y = 450.0, rotation = PI / 4, opacity = 0.5)),
            0L,
        )
        assertEquals(0.5f, partly.alpha, 1e-6f)
    }

    @Test
    fun `liesOffFrame measures a turned layer by the box around it`() {
        // A 100 x 200 layer on a 1000 x 1000 frame, centered 80 px right of
        // it: upright its left edge is 30 px out, a quarter turn brings it 20 px
        // in, 45° 26 px in.
        val centerX = 1f + 80f / 500f
        assertTrue(liesOffFrame(centerX, 0f, 50f, 100f, 0f, 1000, 1000))
        assertEquals(false, liesOffFrame(centerX, 0f, 50f, 100f, 90f, 1000, 1000))
        assertEquals(false, liesOffFrame(centerX, 0f, 50f, 100f, -45f, 1000, 1000))
        assertEquals(false, liesOffFrame(0f, 0f, 50f, 100f, 0f, 1000, 1000))
    }

    // ---- Composition clips ---------------------------------------------------

    private val box = SegmentTransformConfig(
        offsetX = 100.0, offsetY = 200.0, width = 400.0, height = 300.0,
        fit = "contain", rotation = 0.3,
    )

    @Test
    fun `a keyframe moves the box, scales it around its center and replaces its turn`() {
        val moved = keyframedSegmentTransform(
            box,
            KeyframePlacement(x = 10.0, y = 20.0, scale = 2.0, rotation = 1.0, opacity = 1.0),
            displayW = 1920, displayH = 1080, canvasW = 1080, canvasH = 1920,
        )
        assertEquals(10.0 - 200.0, moved.offsetX!!, tol)
        assertEquals(20.0 - 150.0, moved.offsetY!!, tol)
        assertEquals(800.0, moved.width!!, tol)
        assertEquals(600.0, moved.height!!, tol)
        assertEquals(1.0, moved.rotation, tol)
        assertEquals("contain", moved.fit)
    }

    @Test
    fun `a clip without a transform is the whole canvas, filled`() {
        val moved = keyframedSegmentTransform(
            null,
            KeyframePlacement(x = 0.0, y = 0.0, scale = 0.5, rotation = 0.0, opacity = 1.0),
            displayW = 1920, displayH = 1080, canvasW = 1080, canvasH = 1920,
        )
        assertEquals(270.0, moved.offsetX!!, tol)
        assertEquals(480.0, moved.offsetY!!, tol)
        assertEquals(540.0, moved.width!!, tol)
        assertEquals("fill", moved.fit)
    }

    @Test
    fun `the animator measures frames from the clip's first one`() {
        val animator = SegmentKeyframeAnimator(
            keyframes = listOf(
                keyframe(2_000_000L, x = 0.0, opacity = 0.2),
                keyframe(4_000_000L, x = 100.0, opacity = 1.0),
            ),
            transform = box,
            displayW = 400, displayH = 300, canvasW = 1080, canvasH = 1920,
            clipStartUs = 2_000_000L,
        )
        // Media3 hands the clip's frames from 0, here from 500 ms.
        val timeUs = animator.compositionTimeUs(1_500_000L, 500_000L)
        assertEquals(3_000_000L, timeUs)

        val (placement, alpha) = animator.at(timeUs)
        assertEquals(50.0, placement.clip!!.x, tol)
        // The keyframes do not turn the box, whatever its own rotation.
        assertEquals(0.0, placement.rotation, tol)
        assertEquals(0.6f, alpha, 1e-6f)
    }

    @Test
    fun `the animator keeps the plain transform without keyframes`() {
        val animator = SegmentKeyframeAnimator(
            keyframes = emptyList(), transform = box,
            displayW = 400, displayH = 300, canvasW = 1080, canvasH = 1920,
            clipStartUs = 0L,
        )
        val (placement, alpha) = animator.at(1_000_000L)
        assertEquals(segmentPlacement(box, 400, 300, 1080, 1920), placement)
        assertEquals(1f, alpha, 1e-6f)
    }
}
