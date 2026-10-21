package ch.waio.pro_video_editor.src.features.render.helpers

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** Pitch-preserving WSOLA with one waveform alignment across all channels. */
internal object AudioSpeedProcessor {
    /**
     * Streams interleaved int16 PCM, using bounded overlap and source windows,
     * and writes at most [maxFrames].
     *
     * The first frame starts on the first source sample at full level, so the
     * sound starts at once. With [loop] the source repeats without end and
     * exactly [maxFrames] are written: each seam is stretched like the rest of
     * the sound, while looping a stretched copy would leave a gap at every seam.
     */
    fun stretch(
        source: File, destination: File, sampleRate: Int, channels: Int, speed: Float,
        maxFrames: Long = Long.MAX_VALUE, loop: Boolean = false
    ) {
        require(speed.isFinite() && speed > 0f)
        val bytesPerFrame = channels * 2
        require(channels > 0 && sampleRate > 0 && source.length() % bytesPerFrame == 0L)
        require(!loop || maxFrames < Long.MAX_VALUE)
        if (speed == 1f) {
            source.copyTo(destination, overwrite = true)
            return
        }
        val frame = maxOf(4, (sampleRate * FRAME_SECONDS).roundToInt() and -2)
        val hop = frame / 2
        val tolerance = minOf(hop - 1, (sampleRate * TOLERANCE_SECONDS).roundToInt())
        val stride = maxOf(1, sampleRate / CORRELATION_SAMPLE_RATE)
        // Periodic Hann: two windows half a frame apart add up to exactly 1.
        val window = DoubleArray(frame) { 0.5 - 0.5 * cos(2 * PI * it / frame) }
        val accumulator = DoubleArray(frame * channels)
        try {
            RandomAccessFile(source, "r").use { input ->
                RandomAccessFile(destination, "rw").use { output ->
                    output.setLength(0)
                    val sourceFrames = input.length() / bytesPerFrame
                    if (sourceFrames == 0L) return
                    val outputFrames = if (loop) maxFrames
                        else minOf(ceil(sourceFrames / speed.toDouble()).toLong(), maxFrames)
                    // Without a loop no frame reads past the end, where its
                    // silence would leave a dip just before the sound stops.
                    val end = if (loop) Long.MAX_VALUE else maxOf(0L, sourceFrames - frame)
                    val buffer = ByteBuffer.allocate(hop * bytesPerFrame).order(ByteOrder.LITTLE_ENDIAN)
                    var previous = 0L
                    var outStart = 0L
                    while (outStart < outputFrames) {
                        val samples: DoubleArray
                        var offset = 0
                        if (outStart == 0L) {
                            samples = readFrames(input, 0L, frame, channels, sourceFrames, loop)
                        } else {
                            val nominal = minOf((outStart * speed.toDouble()).roundToLong(), end)
                            val lowest = maxOf(0L, nominal - tolerance)
                            val highest = minOf(nominal + tolerance, end)
                            samples = readFrames(
                                input, lowest, (highest - lowest).toInt() + frame, channels,
                                sourceFrames, loop
                            )
                            val target = readFrames(
                                input, previous + hop, hop, channels, sourceFrames, loop
                            )
                            fun correlation(candidate: Long): Double {
                                val base = (candidate - lowest).toInt() * channels
                                var sum = 0.0
                                var index = 0
                                while (index < hop) {
                                    for (channel in 0 until channels) {
                                        sum += target[index * channels + channel] *
                                            samples[base + index * channels + channel]
                                    }
                                    index += stride
                                }
                                return sum
                            }
                            // Ties, e.g. in silence, keep the nominal position.
                            var best = nominal
                            var bestScore = correlation(nominal)
                            var candidate = lowest
                            while (candidate <= highest) {
                                val score = correlation(candidate)
                                if (score > bestScore) {
                                    bestScore = score
                                    best = candidate
                                }
                                candidate += COARSE_STEP
                            }
                            val first = maxOf(best - COARSE_STEP + 1, lowest)
                            val last = minOf(best + COARSE_STEP - 1, highest)
                            for (fine in first..last) {
                                val score = correlation(fine)
                                if (score > bestScore) {
                                    bestScore = score
                                    best = fine
                                }
                            }
                            offset = (best - lowest).toInt() * channels
                            previous = best
                        }
                        // Nothing overlaps the first half of the first frame.
                        for (index in 0 until frame) {
                            val weight = if (outStart == 0L && index < hop) 1.0 else window[index]
                            for (channel in 0 until channels) {
                                accumulator[index * channels + channel] +=
                                    weight * samples[offset + index * channels + channel]
                            }
                        }
                        buffer.clear()
                        for (index in outStart until minOf(outputFrames, outStart + hop)) {
                            for (channel in 0 until channels) {
                                val value = accumulator[(index - outStart).toInt() * channels + channel]
                                buffer.putShort(value.roundToInt().coerceIn(-32768, 32767).toShort())
                            }
                        }
                        output.write(buffer.array(), 0, buffer.position())
                        for (index in 0 until hop * channels) {
                            accumulator[index] = accumulator[index + hop * channels]
                            accumulator[index + hop * channels] = 0.0
                        }
                        outStart += hop
                    }
                }
            }
        } catch (error: Exception) {
            destination.delete()
            throw error
        }
    }

    /**
     * Reads [count] frames from [start], zero past the end of the source or,
     * with [loop], wrapping back to its start.
     */
    private fun readFrames(
        input: RandomAccessFile, start: Long, count: Int, channels: Int,
        sourceFrames: Long, loop: Boolean
    ): DoubleArray {
        val samples = DoubleArray(count * channels)
        val bytesPerFrame = channels * 2
        var filled = 0
        while (filled < count) {
            val index = if (loop) (start + filled) % sourceFrames else start + filled
            if (index >= sourceFrames) break
            val length = minOf((count - filled).toLong(), sourceFrames - index).toInt()
            val bytes = ByteArray(length * bytesPerFrame)
            input.seek(index * bytesPerFrame)
            input.readFully(bytes)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            var offset = filled * channels
            while (buffer.hasRemaining()) samples[offset++] = buffer.short.toDouble()
            filled += length
        }
        return samples
    }

    private const val FRAME_SECONDS = 0.03
    private const val TOLERANCE_SECONDS = 0.008
    private const val CORRELATION_SAMPLE_RATE = 16000
    private const val COARSE_STEP = 4
}
