package ch.waio.pro_video_editor.src.shared.media

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The one MediaCodec loop that turns a range of a compressed audio track into
 * PCM.
 *
 * Both audio consumers need the same state machine — feed the extractor into a
 * decoder, follow whatever format the decoder actually reports, drain to
 * end-of-stream — and differ only in what they do with the samples afterwards:
 * `WavFileWriter` writes them into a WAV with an optional speed change,
 * `AudioPreRenderer` trims them sample-exactly and spools them to a scratch
 * file. Keeping the loop here means a device quirk — a decoder that only
 * reveals its real format through `INFO_OUTPUT_FORMAT_CHANGED`, float PCM
 * output, a seek that lands on an earlier sync frame — is handled once instead
 * of in two copies that have to be kept in step.
 *
 * Float PCM is converted to 16-bit signed little-endian; every other encoding
 * is handed on exactly as the decoder produced it.
 */
internal object PcmRangeDecoder {

    private const val TIMEOUT_US = 10_000L

    /** The PCM format the decoder is currently emitting. */
    data class OutputFormat(
        val sampleRate: Int,
        val channelCount: Int,
        /**
         * The decoder's `KEY_PCM_ENCODING`, or null when it does not report one
         * — which every caller reads as 16-bit signed.
         */
        val pcmEncoding: Int?,
    ) {
        /** Whether the decoder emits float samples, which [decode] converts. */
        val isFloatPcm: Boolean get() = pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT
    }

    /**
     * Decodes `[startUs, endUs)` of [audioTrackIndex] and hands every PCM chunk
     * to [onPcm].
     *
     * Selects the track on [extractor] and seeks it for the caller. [onFormat]
     * fires once with the decoder's initial format before any PCM arrives, and
     * again whenever the decoder changes it mid-stream; the format in force is
     * passed to each [onPcm] call as well, together with the chunk's
     * presentation time so a caller doing its own sample-exact trim can line the
     * chunk up against the timeline.
     *
     * @param inputFormat The track format, as read from [extractor].
     * @param endUs Exclusive end, or [Long.MAX_VALUE] for "to the end".
     * @param stopAfterEndUs Stop as soon as a decoded buffer reaches [endUs]
     *   rather than draining to end-of-stream. Only safe for a caller that trims
     *   the tail itself, since the buffer straddling [endUs] is the last one.
     * @param onProgress Fraction of the requested range fed to the decoder.
     *   Never reaches 1.0 — the caller still has its own finishing to do, and
     *   owns saying when that is done.
     * @param shouldStop Polled each iteration; decoding returns early when set.
     */
    fun decode(
        extractor: MediaExtractor,
        audioTrackIndex: Int,
        inputFormat: MediaFormat,
        startUs: Long,
        endUs: Long,
        onFormat: (OutputFormat) -> Unit,
        onPcm: (pcm: ByteArray, bufferStartUs: Long, format: OutputFormat) -> Unit,
        onProgress: (Double) -> Unit = {},
        shouldStop: () -> Boolean = { false },
        stopAfterEndUs: Boolean = false,
    ) {
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)
            ?: throw IllegalArgumentException("No MIME type in audio format")

        var decoder: MediaCodec? = null
        try {
            val codec = MediaCodec.createDecoderByType(mime)
            decoder = codec
            codec.configure(inputFormat, null, null, 0)
            codec.start()

            // Read the decoder's own output format straight after start: some
            // devices never send INFO_OUTPUT_FORMAT_CHANGED at all.
            var format = readOutputFormat(codec.outputFormat, inputFormat, previous = null)
            onFormat(format)

            extractor.selectTrack(audioTrackIndex)
            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            val rangeUs = if (endUs == Long.MAX_VALUE) Long.MAX_VALUE else endUs - startUs
            var inputEos = false
            var outputEos = false

            onProgress(0.0)

            while (!outputEos && !shouldStop()) {
                if (!inputEos) {
                    val inputBufferId = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputBufferId >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputBufferId)!!
                        inputBuffer.clear()

                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        val presentationTimeUs = extractor.sampleTime

                        if (sampleSize < 0 || presentationTimeUs > endUs) {
                            codec.queueInputBuffer(
                                inputBufferId, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputEos = true
                        } else {
                            codec.queueInputBuffer(
                                inputBufferId, 0, sampleSize, presentationTimeUs, 0
                            )
                            extractor.advance()
                            if (rangeUs != Long.MAX_VALUE && rangeUs > 0) {
                                onProgress(
                                    ((presentationTimeUs - startUs).toDouble() / rangeUs)
                                        .coerceIn(0.0, 1.0)
                                )
                            }
                        }
                    }
                }

                val info = MediaCodec.BufferInfo()
                val outputBufferId = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val changed = readOutputFormat(
                            codec.outputFormat, inputFormat, previous = format
                        )
                        if (changed != format) {
                            format = changed
                            onFormat(changed)
                        }
                    }

                    outputBufferId >= 0 -> {
                        val outputBuffer = codec.getOutputBuffer(outputBufferId)!!

                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEos = true
                        }

                        if (info.size > 0) {
                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)
                            val pcm = if (format.isFloatPcm) {
                                floatToInt16(outputBuffer, info.size)
                            } else {
                                ByteArray(info.size).also { outputBuffer.get(it) }
                            }
                            onPcm(pcm, info.presentationTimeUs, format)
                        }

                        codec.releaseOutputBuffer(outputBufferId, false)

                        if (stopAfterEndUs && endUs != Long.MAX_VALUE &&
                            info.presentationTimeUs >= endUs
                        ) {
                            outputEos = true
                        }
                    }
                }
            }
        } finally {
            try {
                decoder?.stop()
            } catch (_: Exception) {
            }
            try {
                decoder?.release()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * The decoder's format, falling back to [previous] and then to the track
     * format for anything it does not report.
     *
     * A format change that mentions only, say, the channel count must not reset
     * the encoding to "not reported" — that would flip a float-PCM decoder back
     * to the int16 path mid-stream and turn the rest of the track into noise.
     */
    private fun readOutputFormat(
        decoderFormat: MediaFormat,
        inputFormat: MediaFormat,
        previous: OutputFormat?,
    ): OutputFormat {
        val sampleRate = decoderFormat.intOrNull(MediaFormat.KEY_SAMPLE_RATE)
            ?: previous?.sampleRate
            ?: inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = decoderFormat.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)
            ?: previous?.channelCount
            ?: inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val pcmEncoding = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            decoderFormat.intOrNull(MediaFormat.KEY_PCM_ENCODING) ?: previous?.pcmEncoding
        } else {
            previous?.pcmEncoding
        }
        return OutputFormat(sampleRate, channelCount, pcmEncoding)
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) getInteger(key) else null

    /**
     * Converts [byteCount] bytes of float PCM in [buffer] to 16-bit signed
     * little-endian.
     *
     * The buffer is read in *native* order: a `ByteBuffer` defaults to
     * big-endian regardless of the platform, and reading a little-endian
     * decoder's floats that way byte-swaps every sample into noise.
     */
    private fun floatToInt16(buffer: ByteBuffer, byteCount: Int): ByteArray {
        val floatCount = byteCount / 4
        val out = ByteBuffer.allocate(floatCount * 2).order(ByteOrder.LITTLE_ENDIAN)
        val savedOrder = buffer.order()
        buffer.order(ByteOrder.nativeOrder())
        for (i in 0 until floatCount) {
            val sample = buffer.float.coerceIn(-1.0f, 1.0f)
            out.putShort((sample * 32767.0f).toInt().toShort())
        }
        buffer.order(savedOrder)
        return out.array()
    }
}
