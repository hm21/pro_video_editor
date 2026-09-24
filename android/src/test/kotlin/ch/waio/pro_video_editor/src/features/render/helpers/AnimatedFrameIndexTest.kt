package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

internal class AnimatedFrameIndexTest {

    // Four frames of 500 ms each: one playthrough lasts 2 s.
    private val frameEndsUs = longArrayOf(500_000, 1_000_000, 1_500_000, 2_000_000)

    private fun index(
        atUs: Long,
        startUs: Long = 1_000_000,
        offsetUs: Long = 0,
        loop: Boolean = true,
    ) = animatedFrameIndex(atUs, startUs, offsetUs, frameEndsUs, loop)

    @Test
    fun withoutAnOffset_opensOnTheFirstFrameWhenTheLayerAppears() {
        assertEquals(0, index(1_000_000))
        assertEquals(0, index(1_250_000))
        assertEquals(1, index(1_750_000))
    }

    @Test
    fun anOffset_startsPlaybackThatFarIn() {
        assertEquals(2, index(1_000_000, offsetUs = 1_000_000))
        assertEquals(2, index(1_250_000, offsetUs = 1_000_000))
        assertEquals(3, index(1_750_000, offsetUs = 1_000_000))
    }

    @Test
    fun aLayerPickingUpWhereAnotherLeftOff_continuesItsAnimation() {
        // One layer shown 0–1 s, the next from 1 s on with the 1 s already played.
        val single = (0L until 3_000_000L step 40_000L).map { index(it, startUs = 0) }
        val split = (0L until 3_000_000L step 40_000L).map {
            if (it < 1_000_000L) index(it, startUs = 0)
            else index(it, startUs = 1_000_000, offsetUs = 1_000_000)
        }
        assertEquals(single, split)
    }

    @Test
    fun anOffset_wrapsAroundALoopingAnimation() {
        assertEquals(1, index(1_250_000, offsetUs = 2_500_000))
        assertEquals(0, index(1_000_000, offsetUs = 4_000_000))
    }

    @Test
    fun anOffset_pastTheEndHoldsTheLastFrameWithoutLooping() {
        assertEquals(3, index(1_000_000, offsetUs = 5_000_000, loop = false))
        assertEquals(3, index(1_000_000, offsetUs = 2_000_000, loop = false))
        assertEquals(2, index(1_000_000, offsetUs = 1_000_000, loop = false))
    }

    @Test
    fun aHugeOffset_doesNotOverflow() {
        // Long.MAX_VALUE µs lands 775_807 µs into a 2 s playthrough, so 250 ms
        // after the layer appears it is 1_025_807 µs in: frame 2.
        assertEquals(2, index(1_250_000, offsetUs = Long.MAX_VALUE))
        assertEquals(3, index(3_000_000, offsetUs = Long.MAX_VALUE, loop = false))
    }

    @Test
    fun beforeTheLayerAppears_showsTheFrameItOpensOn() {
        assertEquals(2, index(0, offsetUs = 1_000_000))
    }

    @Test
    fun aLayerFromTheStartOfTheVideo_countsFromZero() {
        assertEquals(1, index(250_000, startUs = -1, offsetUs = 500_000))
    }

    @Test
    fun aNegativeOffset_isTreatedAsNone() {
        assertEquals(0, index(1_250_000, offsetUs = -700_000))
    }

    @Test
    fun aStaticImage_alwaysShowsItsOnlyFrame() {
        assertEquals(0, animatedFrameIndex(5_000_000, 0, 1_000_000, longArrayOf(0), true))
    }
}
