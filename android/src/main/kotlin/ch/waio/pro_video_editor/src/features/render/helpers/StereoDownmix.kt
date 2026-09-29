package ch.waio.pro_video_editor.src.features.render.helpers

import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import kotlin.math.roundToInt

/**
 * Folds multichannel audio down to stereo.
 *
 * Media3 converts only mono and stereo sources to the format of the mix, so a
 * 5.1 source mixed with a stereo one fails the export unless it is folded down
 * first.
 *
 * The gains are the ITU-R BS.775 ones (fronts 1.0, centre and surrounds 0.707,
 * LFE dropped), boosted so a folded source keeps roughly its loudness next to
 * stereo ones. Channel orders are Android's: FL, FR, BL, BR for quad and FL,
 * FR, FC, LFE, BL, BR (SL, SR) for 5.1 and 7.1. Any other layout keeps its
 * first two channels as left and right and adds the rest to both at 0.707.
 */
@UnstableApi
internal object StereoDownmix {

    private const val MAX_CHANNELS = 8
    private const val BOOST = 1.4f
    private const val QUAD_BOOST = 1.2f
    private const val SIDE = 0.707f

    /**
     * How much of each input channel goes to the left and to the right output,
     * or `null` for mono and stereo, which are not folded.
     */
    fun gains(inputChannels: Int): Pair<FloatArray, FloatArray>? = when (inputChannels) {
        in 0..2 -> null
        4 -> Pair(
            floatArrayOf(1f, 0f, SIDE, 0f).scaledBy(QUAD_BOOST),
            floatArrayOf(0f, 1f, 0f, SIDE).scaledBy(QUAD_BOOST)
        )
        6 -> Pair(
            floatArrayOf(1f, 0f, SIDE, 0f, SIDE, 0f).scaledBy(BOOST),
            floatArrayOf(0f, 1f, SIDE, 0f, 0f, SIDE).scaledBy(BOOST)
        )
        8 -> Pair(
            floatArrayOf(1f, 0f, SIDE, 0f, SIDE, 0f, SIDE, 0f).scaledBy(BOOST),
            floatArrayOf(0f, 1f, SIDE, 0f, 0f, SIDE, 0f, SIDE).scaledBy(BOOST)
        )
        else -> Pair(
            FloatArray(inputChannels) { when (it) { 0 -> 1f; 1 -> 0f; else -> SIDE } },
            FloatArray(inputChannels) { when (it) { 0 -> 0f; 1 -> 1f; else -> SIDE } }
        )
    }

    /**
     * A processor that brings every source to stereo: mono is copied to both
     * sides, stereo passes, and up to eight channels are folded by [gains].
     */
    fun processor(): ChannelMixingAudioProcessor = ChannelMixingAudioProcessor().apply {
        putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(1, 2))
        putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(2, 2))
        for (channels in 3..MAX_CHANNELS) putChannelMixingMatrix(matrix(channels))
    }

    /**
     * [gains] as a Media3 matrix. Its coefficients run input channel by input
     * channel, `[in0→L, in0→R, in1→L, …]`, not output by output.
     */
    internal fun matrix(inputChannels: Int): ChannelMixingMatrix {
        val (left, right) = requireNotNull(gains(inputChannels)) {
            "$inputChannels channels are not folded"
        }
        val coefficients = FloatArray(inputChannels * 2) { i ->
            if (i % 2 == 0) left[i / 2] else right[i / 2]
        }
        return ChannelMixingMatrix(inputChannels, 2, coefficients)
    }

    /**
     * Folds [length] bytes of interleaved 16-bit little-endian PCM with
     * [inputChannels] channels, starting at [offset], into stereo, clamping at
     * full scale. Mono and stereo come back unchanged.
     */
    fun foldPcm16(pcm: ByteArray, offset: Int, length: Int, inputChannels: Int): ByteArray {
        val (left, right) = gains(inputChannels)
            ?: return pcm.copyOfRange(offset, offset + length)
        val inFrameBytes = inputChannels * 2
        val frames = length / inFrameBytes
        val out = ByteArray(frames * 4)
        for (frame in 0 until frames) {
            val base = offset + frame * inFrameBytes
            var l = 0f
            var r = 0f
            for (channel in 0 until inputChannels) {
                val p = base + channel * 2
                val sample = (pcm[p + 1].toInt() shl 8) or (pcm[p].toInt() and 0xFF)
                l += sample * left[channel]
                r += sample * right[channel]
            }
            putSample(out, frame * 4, l)
            putSample(out, frame * 4 + 2, r)
        }
        return out
    }

    private fun putSample(out: ByteArray, index: Int, value: Float) {
        val sample = value.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
        out[index] = (sample and 0xFF).toByte()
        out[index + 1] = ((sample shr 8) and 0xFF).toByte()
    }

    private fun FloatArray.scaledBy(factor: Float): FloatArray =
        FloatArray(size) { this[it] * factor }
}
