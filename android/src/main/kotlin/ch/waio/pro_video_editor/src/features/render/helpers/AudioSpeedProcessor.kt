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
    /** Streams interleaved int16 PCM, using bounded overlap and source windows. */
    fun stretch(
        source: File, destination: File, sampleRate: Int, channels: Int, speed: Float,
        maxFrames: Long = Long.MAX_VALUE
    ) {
        require(speed.isFinite() && speed > 0f)
        val bytesPerFrame = channels * 2
        require(channels > 0 && sampleRate > 0 && source.length() % bytesPerFrame == 0L)
        if (speed == 1f) {
            source.copyTo(destination, overwrite = true)
            return
        }
        val frame = maxOf(4, (sampleRate * FRAME_SECONDS).roundToInt() and -2)
        val hop = frame / 2
        val tolerance = minOf(hop - 1, (sampleRate * TOLERANCE_SECONDS).roundToInt())
        val stride = maxOf(1, sampleRate / CORRELATION_SAMPLE_RATE)
        val cropStart = (frame / speed.toDouble()).roundToLong()
        val window = DoubleArray(frame) { 0.5 - 0.5 * cos(2 * PI * it / (frame - 1)) }
        val accumulator = DoubleArray(frame * channels)
        try {
            RandomAccessFile(source, "r").use { input ->
                RandomAccessFile(destination, "rw").use { output ->
                    output.setLength(0)
                    val sourceFrames = input.length() / bytesPerFrame
                    val outputFrames = minOf(ceil(sourceFrames / speed.toDouble()).toLong(), maxFrames)
                    val cropEnd = cropStart + outputFrames
                    val buffer = ByteBuffer.allocate(hop * bytesPerFrame).order(ByteOrder.LITTLE_ENDIAN)
                    var previous = 0L
                    var outStart = 0L
                    while (outStart < cropEnd && outputFrames > 0) {
                        val nominal = (outStart * speed.toDouble()).roundToLong()
                        val firstCandidate = nominal - tolerance
                        val candidates = readFrames(
                            input, firstCandidate - frame, frame + 2 * tolerance, channels
                        )
                        var position = 0L
                        if (outStart > 0) {
                            val target = readFrames(input, previous + hop - frame, hop, channels)
                            fun correlation(candidate: Long): Double {
                                val offset = (candidate - firstCandidate).toInt() * channels
                                var sum = 0.0
                                var index = 0
                                while (index < hop) {
                                    for (channel in 0 until channels) {
                                        sum += target[index * channels + channel] *
                                            candidates[offset + index * channels + channel]
                                    }
                                    index += stride
                                }
                                return sum
                            }
                            var best = nominal
                            var bestScore = Double.NEGATIVE_INFINITY
                            var delta = -tolerance
                            while (delta <= tolerance) {
                                val score = correlation(nominal + delta)
                                if (score > bestScore) {
                                    bestScore = score
                                    best = nominal + delta
                                }
                                delta += COARSE_STEP
                            }
                            val first = maxOf(best - COARSE_STEP + 1, nominal - tolerance)
                            val last = minOf(best + COARSE_STEP - 1, nominal + tolerance)
                            for (candidate in first..last) {
                                val score = correlation(candidate)
                                if (score > bestScore) {
                                    bestScore = score
                                    best = candidate
                                }
                            }
                            position = best.coerceAtLeast(0L)
                        }
                        val offset = (position - firstCandidate).toInt() * channels
                        for (index in 0 until frame) {
                            for (channel in 0 until channels) {
                                accumulator[index * channels + channel] +=
                                    window[index] * candidates[offset + index * channels + channel]
                            }
                        }
                        buffer.clear()
                        val first = maxOf(cropStart, outStart)
                        val last = minOf(cropEnd, outStart + hop)
                        for (index in first until last) {
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
                        previous = position
                        outStart += hop
                    }
                }
            }
        } catch (error: Exception) {
            destination.delete()
            throw error
        }
    }

    /** Reads a bounded frame window, padding positions outside the source with zero. */
    private fun readFrames(input: RandomAccessFile, start: Long, count: Int, channels: Int): DoubleArray {
        val samples = DoubleArray(count * channels)
        val bytesPerFrame = channels * 2
        val first = start.coerceAtLeast(0L)
        val end = minOf(start + count, input.length() / bytesPerFrame)
        if (end <= first) return samples
        val bytes = ByteArray(((end - first) * bytesPerFrame).toInt())
        input.seek(first * bytesPerFrame)
        input.readFully(bytes)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = ((first - start) * channels).toInt()
        while (buffer.hasRemaining()) samples[offset++] = buffer.short.toDouble()
        return samples
    }

    private const val FRAME_SECONDS = 0.03
    private const val TOLERANCE_SECONDS = 0.008
    private const val CORRELATION_SAMPLE_RATE = 16000
    private const val COARSE_STEP = 4
}
