package ch.waio.pro_video_editor.src.features.render.helpers

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

/**
 * Pins where each channel of a multichannel source lands when it is folded to
 * stereo.
 *
 * Media3's `ChannelMixingMatrix` reads its coefficients input channel by input
 * channel. Written output by output instead, a 5.1 fold put front right on the
 * left and the LFE on the right, and nothing but a listening test noticed.
 */
internal class StereoDownmixTest {

    private companion object {
        const val FL = 0
        const val FR = 1
        const val FC = 2
        const val LFE = 3
        const val BL = 4
        const val BR = 5
        const val LEFT = 0
        const val RIGHT = 1
    }

    @Test
    fun aFiveOneMatrixKeepsEachFrontOnItsOwnSide() {
        val matrix = StereoDownmix.matrix(6)

        assertEquals(0f, matrix.getMixingCoefficient(FR, LEFT))
        assertEquals(0f, matrix.getMixingCoefficient(FL, RIGHT))
        assertEquals(1.4f, matrix.getMixingCoefficient(FL, LEFT), 1e-4f)
        assertEquals(1.4f, matrix.getMixingCoefficient(FR, RIGHT), 1e-4f)
    }

    @Test
    fun aFiveOneMatrixSplitsTheCentreAndDropsTheLfe() {
        val matrix = StereoDownmix.matrix(6)

        assertEquals(
            matrix.getMixingCoefficient(FC, LEFT),
            matrix.getMixingCoefficient(FC, RIGHT)
        )
        assertEquals(0f, matrix.getMixingCoefficient(LFE, LEFT))
        assertEquals(0f, matrix.getMixingCoefficient(LFE, RIGHT))
        assertEquals(0f, matrix.getMixingCoefficient(BL, RIGHT))
        assertEquals(0f, matrix.getMixingCoefficient(BR, LEFT))
    }

    @Test
    fun foldingPcmMatchesTheMatrix() {
        val frame = shortArrayOf(0, 1000, 0, 0, 0, 0) // front right only

        val stereo = shorts(StereoDownmix.foldPcm16(pcm(frame), 0, 12, 6))

        assertContentEquals(shortArrayOf(0, 1400), stereo)
    }

    @Test
    fun foldingClampsAtFullScale() {
        val frame = shortArrayOf(30000, 0, 30000, 0, 30000, 0)

        val stereo = shorts(StereoDownmix.foldPcm16(pcm(frame), 0, 12, 6))

        assertEquals(Short.MAX_VALUE, stereo[0])
    }

    @Test
    fun foldingReadsOnlyTheRequestedRange() {
        // One leading frame to skip, then front left only.
        val frames = shortArrayOf(9, 9, 9, 9, 9, 9, 500, 0, 0, 0, 0, 0)

        val stereo = shorts(StereoDownmix.foldPcm16(pcm(frames), 12, 12, 6))

        assertContentEquals(shortArrayOf(700, 0), stereo)
    }

    @Test
    fun monoAndStereoAreNotFolded() {
        val bytes = pcm(shortArrayOf(1, -2, 3, -4))

        assertContentEquals(bytes, StereoDownmix.foldPcm16(bytes, 0, 8, 2))
        assertContentEquals(bytes, StereoDownmix.foldPcm16(bytes, 0, 8, 1))
    }

    @Test
    fun anUnusualLayoutKeepsItsFirstTwoChannelsAsLeftAndRight() {
        val frame = shortArrayOf(100, 200, 0) // L, R, C

        val stereo = shorts(StereoDownmix.foldPcm16(pcm(frame), 0, 6, 3))

        assertContentEquals(shortArrayOf(100, 200), stereo)
    }

    private fun pcm(samples: ShortArray): ByteArray {
        val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { buffer.putShort(it) }
        return buffer.array()
    }

    private fun shorts(bytes: ByteArray): ShortArray {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return ShortArray(bytes.size / 2) { buffer.short }
    }
}
