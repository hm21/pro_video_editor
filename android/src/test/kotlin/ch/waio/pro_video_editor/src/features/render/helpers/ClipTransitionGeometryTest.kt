package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class ClipTransitionGeometryTest {

    @Test
    fun planOverlap_atOneXMatchesLegacyBehavior() {
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L,
            incomingSourceDurationUs = 1_000_000L,
            transitionDurationUs = 300_000L,
            outgoingSpeed = null,
            incomingSpeed = null,
        )
        // At 1× the output duration equals the source consumed on both sides.
        assertEquals(
            ClipTransitionGeometry.OverlapPlan(300_000L, 300_000L, 300_000L),
            plan,
        )
    }

    @Test
    fun planOverlap_speedTwoConsumesDoubleSource() {
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L,
            incomingSourceDurationUs = 1_000_000L,
            transitionDurationUs = 200_000L,
            outgoingSpeed = 2.0f,
            incomingSpeed = 2.0f,
        )
        // 200ms of OUTPUT at 2× consumes 400ms of source from each side.
        assertEquals(
            ClipTransitionGeometry.OverlapPlan(200_000L, 400_000L, 400_000L),
            plan,
        )
    }

    @Test
    fun planOverlap_slowMotionConsumesHalfSource() {
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L,
            incomingSourceDurationUs = 1_000_000L,
            transitionDurationUs = 300_000L,
            outgoingSpeed = 0.5f,
            incomingSpeed = null,
        )
        // 300ms output at 0.5× consumes 150ms of the outgoing source; the
        // incoming side stays 1× and consumes the full 300ms.
        assertEquals(
            ClipTransitionGeometry.OverlapPlan(300_000L, 150_000L, 300_000L),
            plan,
        )
    }

    @Test
    fun planOverlap_supportsIndependentPerSideSpeeds() {
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L,
            incomingSourceDurationUs = 1_000_000L,
            transitionDurationUs = 400_000L,
            outgoingSpeed = 2.0f,
            incomingSpeed = 0.5f,
        )
        // Outgoing 2× → 800ms source; incoming 0.5× → 200ms source; both for a
        // single 400ms output blend.
        assertEquals(
            ClipTransitionGeometry.OverlapPlan(400_000L, 800_000L, 200_000L),
            plan,
        )
    }

    @Test
    fun planOverlap_clampsRequestedDurationToShorterOutputSide() {
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L, // 500ms output @2×
            incomingSourceDurationUs = 4_000_000L, // 4000ms output @1×
            transitionDurationUs = 2_000_000L,
            outgoingSpeed = 2.0f,
            incomingSpeed = null,
        )
        // Clamped to the outgoing output duration (500ms) minus the body guard.
        // 500ms output is the full outgoing clip, so it must clamp below that.
        // min(2000ms, 500ms, 4000ms) = 500ms → tail 1000ms == source → null.
        assertNull(plan)
    }

    @Test
    fun planOverlap_returnsNullWhenTransitionConsumesWholeClip() {
        // The reproduction case: two 550ms clips at 2× (275ms output each) with a
        // 500ms transition. The blend would consume an entire clip, so it must
        // degrade to a hard cut rather than leave a zero-length body.
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 550_000L,
            incomingSourceDurationUs = 550_000L,
            transitionDurationUs = 500_000L,
            outgoingSpeed = 2.0f,
            incomingSpeed = 2.0f,
        )
        assertNull(plan)
    }

    @Test
    fun planOverlap_rendersWhenBodyRemainsAtSpeed() {
        // Same 2× speed but a short enough transition to keep a visible body.
        val plan = ClipTransitionGeometry.planOverlap(
            outgoingSourceDurationUs = 1_000_000L, // 500ms output @2×
            incomingSourceDurationUs = 1_000_000L,
            transitionDurationUs = 150_000L,
            outgoingSpeed = 2.0f,
            incomingSpeed = 2.0f,
        )
        assertEquals(
            ClipTransitionGeometry.OverlapPlan(150_000L, 300_000L, 300_000L),
            plan,
        )
    }

    @Test
    fun outputFrameCount_keepsFramesAtOneX() {
        // 333ms tail at 1× → same frame count, played at the same rate.
        assertEquals(
            10,
            ClipTransitionGeometry.outputFrameCount(
                decodedTailFrames = 10,
                tailSourceDurationUs = 333_000L,
                outputDurationUs = 333_000L,
            ),
        )
    }

    @Test
    fun outputFrameCount_halvesFramesAtDoubleSpeed() {
        // 400ms tail compressed into a 200ms output → half the frames (2× faster).
        assertEquals(
            6,
            ClipTransitionGeometry.outputFrameCount(
                decodedTailFrames = 12,
                tailSourceDurationUs = 400_000L,
                outputDurationUs = 200_000L,
            ),
        )
    }

    @Test
    fun outputFrameCount_doublesFramesAtHalfSpeed() {
        // 150ms tail stretched over a 300ms output → twice the frames (0.5× slower).
        assertEquals(
            12,
            ClipTransitionGeometry.outputFrameCount(
                decodedTailFrames = 6,
                tailSourceDurationUs = 150_000L,
                outputDurationUs = 300_000L,
            ),
        )
    }

    @Test
    fun outputFrameCount_fallsBackForNonPositiveInput() {
        assertEquals(
            8,
            ClipTransitionGeometry.outputFrameCount(
                decodedTailFrames = 8,
                tailSourceDurationUs = 200_000L,
                outputDurationUs = 0L,
            ),
        )
    }

    @Test
    fun planOverlap_returnsNullForInvalidDurations() {
        assertNull(
            ClipTransitionGeometry.planOverlap(
                outgoingSourceDurationUs = 0L,
                incomingSourceDurationUs = 1_000_000L,
                transitionDurationUs = 100_000L,
                outgoingSpeed = 1.0f,
                incomingSpeed = 1.0f,
            )
        )
        assertNull(
            ClipTransitionGeometry.planOverlap(
                outgoingSourceDurationUs = 1_000_000L,
                incomingSourceDurationUs = 1_000_000L,
                transitionDurationUs = 0L,
                outgoingSpeed = 1.0f,
                incomingSpeed = 1.0f,
            )
        )
    }
}
