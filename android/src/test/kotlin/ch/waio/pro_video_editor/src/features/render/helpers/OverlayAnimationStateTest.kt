package ch.waio.pro_video_editor.src.features.render.helpers

import ch.waio.pro_video_editor.src.features.render.models.KeyframeClock
import ch.waio.pro_video_editor.src.features.render.models.LayerAnimationConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins [animationProgress] and [overlayAnimationState]: the loop phase, the
 * wiggle, bounce, spin and flip types and the animation range a layer can
 * count from.
 * The editor preview in `pro_image_editor` computes the same values.
 */
internal class OverlayAnimationStateTest {

    private val tol = 1e-6

    private fun anim(
        type: String,
        phase: String,
        durationUs: Long = 1_000_000L,
        curve: String = "linear",
        wiggleAngle: Double? = null,
        bounceHeight: Double? = null,
        turns: Double? = null,
        flipAxis: String? = null,
    ) = LayerAnimationConfig(
        type = type,
        phase = phase,
        durationUs = durationUs,
        curve = curve,
        wiggleAngle = wiggleAngle,
        bounceHeight = bounceHeight,
        turns = turns,
        flipAxis = flipAxis,
    )

    private fun state(
        animations: List<LayerAnimationConfig>,
        timeUs: Long,
        startUs: Long = 0L,
        endUs: Long = 10_000_000L,
    ) = overlayAnimationState(
        animations = animations,
        timeUs = timeUs,
        startUs = startUs,
        endUs = endUs,
        baseNormX = 0f,
        baseNormY = 0f,
        halfNormW = 0.2f,
        halfNormH = 0.1f,
        layerX = 400f,
        layerY = 450f,
        videoWidth = 1000,
        videoHeight = 1000,
    )

    @Test
    fun loopRunsFromRestToFullyAwayAndBackOncePerCycle() {
        val loop = anim("scale", "loop")
        assertEquals(1.0, animationProgress(loop, 0L, 0L, -1L)!!.value, tol)
        assertEquals(0.5, animationProgress(loop, 250_000L, 0L, -1L)!!.value, tol)
        assertEquals(0.0, animationProgress(loop, 500_000L, 0L, -1L)!!.value, tol)
        assertEquals(0.5, animationProgress(loop, 750_000L, 0L, -1L)!!.value, tol)
        // The next cycle starts at rest again, however long the layer lasts.
        assertEquals(1.0, animationProgress(loop, 7_000_000L, 0L, -1L)!!.value, tol)
        assertEquals(0.0, animationProgress(loop, 7_500_000L, 0L, -1L)!!.value, tol)
    }

    @Test
    fun loopCountsFromTheStartOfTheRange() {
        val loop = anim("fade", "loop")
        assertEquals(1.0, animationProgress(loop, 2_000_000L, 2_000_000L, -1L)!!.value, tol)
        assertEquals(0.0, animationProgress(loop, 2_500_000L, 2_000_000L, -1L)!!.value, tol)
    }

    @Test
    fun loopPlaysOnlyWithinItsWindowCountingFromItsStart() {
        val loop = LayerAnimationConfig(
            type = "fade",
            phase = "loop",
            durationUs = 1_000_000L,
            loopStartUs = 3_000_000L,
            loopEndUs = 5_000_000L,
        )
        assertNull(animationProgress(loop, 2_999_999L, 0L, -1L))
        assertEquals(1.0, animationProgress(loop, 3_000_000L, 0L, -1L)!!.value, tol)
        // Cycles count from the window, not from the layer's start.
        assertEquals(0.0, animationProgress(loop, 3_500_000L, 0L, -1L)!!.value, tol)
        assertEquals(0.0, animationProgress(loop, 4_500_000L, 0L, -1L)!!.value, tol)
        assertNull(animationProgress(loop, 5_000_000L, 0L, -1L))
    }

    @Test
    fun loopStartsAtItsPhaseAndRunsOnFromThere() {
        // A quarter cycle in at its start: half way out already.
        val loop = LayerAnimationConfig(
            type = "fade",
            phase = "loop",
            durationUs = 1_000_000L,
            loopStartUs = 3_000_000L,
            loopEndUs = 5_000_000L,
            loopPhaseUs = 250_000L,
        )
        assertEquals(0.5, animationProgress(loop, 3_000_000L, 0L, -1L)!!.value, tol)
        assertEquals(0.0, animationProgress(loop, 3_250_000L, 0L, -1L)!!.value, tol)
        assertEquals(1.0, animationProgress(loop, 3_750_000L, 0L, -1L)!!.value, tol)
        // A phase below zero lands inside the cycle, not past rest.
        val behind = loop.copy(loopPhaseUs = -750_000L)
        assertEquals(0.5, animationProgress(behind, 3_000_000L, 0L, -1L)!!.value, tol)
    }

    @Test
    fun loopCurveShapesTheWayOutLikeAnOutAnimation() {
        // easeIn: x², with x = 1 at rest. A quarter cycle has x = 0.5.
        val loop = anim("fade", "loop", curve = "easeIn")
        assertEquals(0.25, animationProgress(loop, 250_000L, 0L, -1L)!!.value, tol)
    }

    @Test
    fun wiggleLoopSwingsToOneSideAndThenTheOther() {
        val wiggle = anim("wiggle", "loop")
        val first = animationProgress(wiggle, 250_000L, 0L, -1L)!!
        val second = animationProgress(wiggle, 750_000L, 0L, -1L)!!
        assertEquals(0.0, first.value, tol)
        assertEquals(1f, first.swing)
        assertEquals(0.0, second.value, tol)
        assertEquals(-1f, second.swing)
        // Upright between the two swings.
        assertEquals(1.0, animationProgress(wiggle, 500_000L, 0L, -1L)!!.value, tol)
    }

    @Test
    fun wiggleTiltsClockwiseFirstWhichMedia3ReadsAsNegative() {
        val angle = Math.toRadians(12.0)
        val wiggle = anim("wiggle", "loop", wiggleAngle = angle)
        assertEquals(-12f, state(listOf(wiggle), 250_000L).rotationDegrees, 1e-4f)
        assertEquals(12f, state(listOf(wiggle), 750_000L).rotationDegrees, 1e-4f)
        assertEquals(0f, state(listOf(wiggle), 500_000L).rotationDegrees, 1e-4f)
    }

    @Test
    fun wiggleWithoutAnAngleTiltsTenDegrees() {
        val wiggle = anim("wiggle", "animateIn")
        assertEquals(-10f, state(listOf(wiggle), 0L).rotationDegrees, 1e-4f)
        assertEquals(0f, state(listOf(wiggle), 1_000_000L).rotationDegrees, 1e-4f)
    }

    @Test
    fun bounceLiftsByAMultipleOfTheLayerHeight() {
        // halfNormH 0.1: the layer is 0.2 tall in NDC.
        val bounce = anim("bounce", "animateIn", bounceHeight = 1.5)
        assertEquals(0.3f, state(listOf(bounce), 0L).offsetY, 1e-6f)
        assertEquals(0.15f, state(listOf(bounce), 500_000L).offsetY, 1e-6f)
        assertEquals(0f, state(listOf(bounce), 1_000_000L).offsetY, 1e-6f)
        assertEquals(0f, state(listOf(bounce), 0L).offsetX, 1e-6f)
    }

    @Test
    fun bounceOutRisesFromTheRestingPlace() {
        val bounce = anim("bounce", "animateOut")
        // Default height: half the layer, 0.1 in NDC.
        assertEquals(0f, state(listOf(bounce), 9_000_000L).offsetY, 1e-6f)
        assertEquals(0.1f, state(listOf(bounce), 10_000_000L).offsetY, 1e-6f)
    }

    @Test
    fun textRevealsLeaveTheImageAsItIs() {
        val reveals = listOf(
            anim("typewriter", "animateIn"),
            anim("wordByWord", "animateOut"),
        )
        val s = state(reveals, 0L)
        assertEquals(1f, s.alpha, 1e-6f)
        assertEquals(1f, s.scale, 1e-6f)
        assertEquals(0f, s.offsetX, 1e-6f)
        assertEquals(0f, s.offsetY, 1e-6f)
        assertEquals(0f, s.rotationDegrees, 1e-6f)
    }

    @Test
    fun effectsCompose() {
        val s = state(
            listOf(
                anim("fade", "loop"),
                anim("bounce", "animateIn", bounceHeight = 1.0),
                anim("wiggle", "animateIn", wiggleAngle = Math.toRadians(20.0)),
            ),
            250_000L,
        )
        assertEquals(0.5f, s.alpha, 1e-6f)
        // 3/4 of the lift (1 - 0.25) of one layer height (0.2).
        assertEquals(0.15f, s.offsetY, 1e-6f)
        assertEquals(-15f, s.rotationDegrees, 1e-4f)
    }

    @Test
    fun aSpinTurnsIntoPlaceTheWayItTurnsAway() {
        val spin = anim("spin", "animateInOut", turns = 2.0)
        fun turn(t: Long) = animationProgress(spin, t, 0L, 5_000_000L)!!.turn
        // Two turns back at the start, up to rest, and on beyond it at the
        // end: clockwise throughout.
        assertEquals(-2.0, turn(0L), tol)
        assertEquals(-0.5, turn(750_000L), tol)
        assertEquals(0.5, turn(4_250_000L), tol)
        assertEquals(2.0, turn(5_000_000L), tol)
    }

    @Test
    fun aSpinLoopKeepsTurning() {
        val spin = anim("spin", "loop", turns = 0.25)
        fun turn(t: Long) = animationProgress(spin, t, 0L, -1L)!!.turn
        assertEquals(0.0, turn(0L), tol)
        assertEquals(0.125, turn(500_000L), tol)
        // A quarter turn per cycle, picking up where the last cycle stopped.
        assertEquals(0.375, turn(1_500_000L), tol)
        // Whole turns are taken off.
        assertEquals(0.125, turn(4_500_000L), tol)
    }

    @Test
    fun aSpinTurnsTheOverlayClockwise() {
        // A quarter of the way in, three quarters of a turn to go: a quarter
        // clockwise from where it started, which Media3 counts the other way.
        val s = state(listOf(anim("spin", "animateIn")), 250_000L)
        assertEquals(270f, s.rotationDegrees, 1e-3f)
        assertEquals(1f, s.flipX, 1e-6f)
        assertEquals(1f, s.flipY, 1e-6f)
    }

    @Test
    fun aFlipSqueezesTheOverlayAcrossItsAxis() {
        val flip = anim("flip", "animateIn", turns = 0.5, flipAxis = "horizontal")
        // Half a turn away, it shows its mirror image.
        val mirrored = state(listOf(flip), 0L)
        assertEquals(1f, mirrored.flipX, 1e-6f)
        assertEquals(-1f, mirrored.flipY, 1e-6f)
        // A quarter turn away, it is edge-on.
        assertEquals(0f, state(listOf(flip), 500_000L).flipY, 1e-6f)
        // Without an axis it turns sideways.
        assertEquals(-1f, state(listOf(anim("flip", "animateIn", turns = 0.5)), 0L).flipX, 1e-6f)
        assertEquals(0f, state(listOf(flip), 500_000L).rotationDegrees, 1e-6f)
    }

    @Test
    fun anOverlayFrameCarriesTheFlip() {
        // Near the right edge, which a mirrored width counted as negative
        // would push the layer past.
        val frame = overlayFrame(
            keyframes = emptyList(),
            keyframeClock = KeyframeClock.OUTPUT,
            animations = listOf(anim("flip", "animateIn", turns = 0.5)),
            timeUs = 0L,
            animationStartUs = 0L,
            animationEndUs = 10_000_000L,
            baseNormX = 0.9f,
            baseNormY = 0f,
            imageWidth = 200,
            imageHeight = 100,
            videoWidth = 1000,
            videoHeight = 1000,
            layerX = 850f,
            layerY = 450f,
        )
        assertEquals(-1f, frame.flipX, 1e-6f)
        assertEquals(1f, frame.flipY, 1e-6f)
        // A mirrored layer still shows.
        assertEquals(1f, frame.alpha, 1e-6f)
    }

    @Test
    fun anAnimationWithoutDurationDoesNotPlay() {
        assertNull(animationProgress(anim("wiggle", "loop", durationUs = 0L), 0L, 0L, -1L))
    }

    @Test
    fun outsideItsWindowAnInAnimationDoesNotPlay() {
        assertNull(animationProgress(anim("bounce", "animateIn"), 1_000_000L, 0L, -1L))
        assertNull(animationProgress(anim("bounce", "animateOut"), 0L, 0L, -1L))
    }
}
