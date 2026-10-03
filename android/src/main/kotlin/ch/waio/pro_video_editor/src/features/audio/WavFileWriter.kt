package ch.waio.pro_video_editor.src.features.audio

import android.media.AudioFormat
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.media.PcmRangeDecoder
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Utility class for writing WAV audio files with proper RIFF/WAVE format.
 *
 * This class handles the creation of WAV files by:
 * - Writing a proper RIFF/WAVE header
 * - Decoding compressed audio to PCM samples
 * - Writing PCM data in the correct format
 * - Optionally applying a pitch-preserving playback speed change
 * - Updating the file size fields after writing
 *
 * @param outputFile Destination WAV file.
 * @param speed Playback speed multiplier (1.0 = original). Values other than
 *   1.0 time-stretch the audio while keeping the original pitch. Only applied
 *   to 16-bit PCM output.
 */
@UnstableApi
class WavFileWriter(private val outputFile: File, private val speed: Float = 1.0f) {

    companion object {
        // Magic numbers for WAV format
        // Note: These are stored in little-endian byte order (reversed) so that when
        // written via a LITTLE_ENDIAN ByteBuffer, they appear correctly in the file.
        private const val RIFF_HEADER = 0x46464952 // "RIFF" in little-endian
        private const val WAVE_HEADER = 0x45564157 // "WAVE" in little-endian
        private const val FMT_HEADER = 0x20746d66  // "fmt " in little-endian
        private const val DATA_HEADER = 0x61746164 // "data" in little-endian
        private const val PCM_FORMAT = 1.toShort()
        private const val BUFFER_SIZE = 1024 * 1024 // 1MB buffer

        // MediaFormat.KEY_ENCODER_DELAY / KEY_ENCODER_PADDING, public from API 30.
        private const val KEY_ENCODER_DELAY = "encoder-delay"
        private const val KEY_ENCODER_PADDING = "encoder-padding"

        /** How far ahead of a trim's start decoding begins. */
        private const val PREROLL_US = 200_000L
    }

    private var sampleRate: Int = 44100
    private var numChannels: Int = 2
    private var bitsPerSample: Int = 16
    private var isFloatPcm: Boolean = false
    private var totalDataSize: Long = 0

    /** Active when a pitch-preserving speed change is being applied. */
    private var speedProcessor: PcmSpeedProcessor? = null

    /**
     * Initializes the speed processor once the PCM format is known.
     *
     * Speed is only applied to 16-bit PCM (the format this writer always emits
     * after float conversion); 8-bit sources are written unchanged.
     */
    private fun maybeInitSpeedProcessor() {
        if (speed != 1.0f && bitsPerSample == 16 && speedProcessor == null) {
            speedProcessor = PcmSpeedProcessor(speed, sampleRate, numChannels)
        }
    }

    /**
     * Writes a chunk of 16-bit PCM, routing it through the speed processor when
     * a speed change is active. Accumulates the number of bytes actually
     * written so the WAV header reflects the (re-timed) output length.
     */
    private fun writePcm(outputStream: FileOutputStream, pcm: ByteArray) {
        val processor = speedProcessor
        if (processor == null) {
            outputStream.write(pcm)
            totalDataSize += pcm.size
        } else {
            val processed = processor.process(pcm)
            if (processed.isNotEmpty()) {
                outputStream.write(processed)
                totalDataSize += processed.size
            }
        }
    }

    /** Flushes any samples buffered inside the speed processor. */
    private fun flushSpeedProcessor(outputStream: FileOutputStream) {
        val processor = speedProcessor ?: return
        val tail = processor.drain()
        if (tail.isNotEmpty()) {
            outputStream.write(tail)
            totalDataSize += tail.size
        }
    }

    /**
     * Extracts audio from a video file and writes it as a WAV file.
     *
     * @param extractor MediaExtractor configured with the source video
     * @param audioTrackIndex Index of the audio track in the extractor
     * @param startUs Optional start time in microseconds
     * @param endUs Optional end time in microseconds
     * @param onProgress Progress callback (0.0 to 1.0)
     * @param shouldStop Atomic boolean to check for cancellation
     * @throws Exception if extraction or writing fails
     */
    fun extractAndWrite(
        extractor: MediaExtractor,
        audioTrackIndex: Int,
        startUs: Long = 0L,
        endUs: Long = Long.MAX_VALUE,
        onProgress: (Double) -> Unit = {},
        shouldStop: () -> Boolean = { false }
    ) {
        val audioFormat = extractor.getTrackFormat(audioTrackIndex)

        sampleRate = audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        numChannels = audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        bitsPerSample = 16 // PCM 16-bit is standard

        val mime = audioFormat.getString(MediaFormat.KEY_MIME) ?: throw IllegalArgumentException("No MIME type in audio format")

        val isPcm = mime.equals("audio/raw", ignoreCase = true) ||
                           mime.equals("audio/pcm", ignoreCase = true)
        if (isPcm) {
            extractPcmToWav(extractor, audioFormat, audioTrackIndex, startUs, endUs, onProgress, shouldStop)
        } else {
            extractAndDecodeToWav(extractor, audioFormat, audioTrackIndex, startUs, endUs, onProgress, shouldStop)
        }
    }

    /**
     * Extracts compressed audio and decodes it to PCM WAV format.
     *
     * An AAC or MP3 track opens with encoder delay, priming samples ahead of
     * the audio, and ends in encoder padding. A decoder drops both on its own,
     * but counted from wherever it starts: after a seek it drops that many
     * samples of real audio instead, so a trimmed WAV came out short (AAC by
     * ~70 ms, HE-AAC by over 100 ms) and shifted. The decoder is therefore
     * told to keep them, and `[startUs, endUs)` is cut out of its output here.
     */
    private fun extractAndDecodeToWav(
        extractor: MediaExtractor,
        audioFormat: MediaFormat,
        audioTrackIndex: Int,
        startUs: Long,
        endUs: Long,
        onProgress: (Double) -> Unit,
        shouldStop: () -> Boolean
    ) {
        var outputStream: FileOutputStream? = null

        try {
            totalDataSize = 0

            val stream = FileOutputStream(outputFile)
            outputStream = stream

            // Placeholder header, so the PCM starts at byte 44. It is rewritten
            // as soon as the decoder reports its real format, and again at the
            // end with the measured sizes.
            writeWavHeader(stream, 0)
            var formatKnown = false

            // Both values count samples at the track's sample rate, which for
            // HE-AAC is the rate of its AAC core.
            val trackRate = audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE).toLong()
            val delayUs = audioFormat.intOrZero(KEY_ENCODER_DELAY) * 1_000_000L / trackRate
            val paddingUs = audioFormat.intOrZero(KEY_ENCODER_PADDING) * 1_000_000L / trackRate

            // Where an edit list declares the delay, the extractor already
            // moves the first sample that far before zero; only what is left
            // of the delay still has to be skipped on the timeline.
            extractor.selectTrack(audioTrackIndex)
            val firstSampleUs = extractor.sampleTime
            val pendingDelayUs = (delayUs + minOf(firstSampleUs, 0L)).coerceAtLeast(0L)
            val windowStartUs = startUs + pendingDelayUs
            val windowEndUs = if (endUs == Long.MAX_VALUE) endUs else endUs + pendingDelayUs

            // A fresh copy of the track format, so the caller's stays intact.
            val decoderFormat = extractor.getTrackFormat(audioTrackIndex).apply {
                setInteger(KEY_ENCODER_DELAY, 0)
                setInteger(KEY_ENCODER_PADDING, 0)
            }

            // Only the end of the stream tells where the padding starts, so
            // that much of the newest output waits in here until then.
            var unwritten = ByteArray(0)
            fun write(pcm: ByteArray, format: PcmRangeDecoder.OutputFormat) {
                val paddingBytes =
                    (paddingUs * format.sampleRate / 1_000_000L).toInt() * format.bytesPerFrame
                val pending = unwritten + pcm
                val ready = pending.size - paddingBytes
                if (ready > 0) {
                    writePcm(stream, pending.copyOfRange(0, ready))
                    unwritten = pending.copyOfRange(ready, pending.size)
                } else {
                    unwritten = pending
                }
            }
            fun flushUnwritten() {
                if (unwritten.isNotEmpty()) writePcm(stream, unwritten)
                unwritten = ByteArray(0)
            }

            // Writes the part of a decoded chunk that lies inside the window.
            var decodedUntilUs = Long.MIN_VALUE
            fun writeInWindow(pcm: ByteArray, chunkStartUs: Long, format: PcmRangeDecoder.OutputFormat) {
                val bytesPerFrame = format.bytesPerFrame
                if (bytesPerFrame <= 0 || format.sampleRate <= 0) return
                val frames = pcm.size / bytesPerFrame
                decodedUntilUs = chunkStartUs + frames * 1_000_000L / format.sampleRate
                fun frameAt(timeUs: Long): Int {
                    if (timeUs == Long.MAX_VALUE) return frames
                    val frame = Math.round((timeUs - chunkStartUs) * format.sampleRate / 1_000_000.0)
                    return frame.coerceIn(0L, frames.toLong()).toInt()
                }
                val from = frameAt(windowStartUs)
                val to = frameAt(windowEndUs)
                if (to > from) {
                    write(pcm.copyOfRange(from * bytesPerFrame, to * bytesPerFrame), format)
                }
            }

            // The first chunk is held back until the second one arrives. A
            // decoder that drops priming anyway keeps only the tail of that
            // chunk while stamping it with the start of its input, so where
            // it really starts follows from where the next chunk begins.
            var heldChunk: Triple<ByteArray, Long, PcmRangeDecoder.OutputFormat>? = null
            var chunkCount = 0

            PcmRangeDecoder.decode(
                extractor = extractor,
                audioTrackIndex = audioTrackIndex,
                inputFormat = decoderFormat,
                // Start a little early: an AAC decoder needs the previous frame
                // (HE-AAC a few) before its output is right.
                startUs = (windowStartUs - PREROLL_US).coerceAtLeast(0L),
                endUs = windowEndUs,
                stopAfterEndUs = true,
                onFormat = { format ->
                    // What is held back belongs to the old format.
                    flushUnwritten()

                    sampleRate = format.sampleRate
                    numChannels = format.channelCount
                    isFloatPcm = format.isFloatPcm
                    // Float is converted to int16 before it reaches us, so the
                    // only depth that survives the decoder is 8-bit.
                    bitsPerSample =
                        if (format.pcmEncoding == AudioFormat.ENCODING_PCM_8BIT) 8 else 16

                    rewriteWavHeader(stream)
                    if (!formatKnown) {
                        formatKnown = true
                        maybeInitSpeedProcessor()
                    } else {
                        // A mid-stream change: the processor is tied to the old
                        // sample rate and channel count, so drain what it holds
                        // and build a new one for the new format.
                        val processor = speedProcessor
                        if (processor != null) {
                            val tail = processor.drain()
                            if (tail.isNotEmpty()) {
                                stream.write(tail)
                                totalDataSize += tail.size
                            }
                            speedProcessor = null
                            maybeInitSpeedProcessor()
                        }
                    }
                },
                onPcm = { pcm, chunkStartUs, format ->
                    chunkCount++
                    val held = heldChunk
                    if (chunkCount == 1) {
                        heldChunk = Triple(pcm, chunkStartUs, format)
                    } else {
                        if (held != null) {
                            val (heldPcm, heldStartUs, heldFormat) = held
                            val heldFrames = heldPcm.size / heldFormat.bytesPerFrame.coerceAtLeast(1)
                            val impliedStartUs = chunkStartUs -
                                    heldFrames * 1_000_000L / heldFormat.sampleRate.coerceAtLeast(1)
                            writeInWindow(heldPcm, maxOf(heldStartUs, impliedStartUs), heldFormat)
                            heldChunk = null
                        }
                        writeInWindow(pcm, chunkStartUs, format)
                    }
                },
                onProgress = onProgress,
                shouldStop = shouldStop,
            )
            heldChunk?.let { (pcm, chunkStartUs, format) -> writeInWindow(pcm, chunkStartUs, format) }

            // Decoding that stopped short of the window ran into the end of
            // the track, and what is still held back is its padding.
            if (decodedUntilUs >= windowEndUs) flushUnwritten()

            // Flush any samples buffered by the speed processor.
            flushSpeedProcessor(stream)

            stream.flush()
            stream.close()
            outputStream = null

            // Update WAV header with actual sizes
            updateWavHeader()

            onProgress(1.0)
        } finally {
            outputStream?.close()
        }
    }

    private fun MediaFormat.intOrZero(key: String): Int =
        if (containsKey(key)) getInteger(key) else 0

    /** Float arrives converted to int16, so only 8-bit PCM is narrower. */
    private val PcmRangeDecoder.OutputFormat.bytesPerFrame: Int
        get() = channelCount * (if (pcmEncoding == AudioFormat.ENCODING_PCM_8BIT) 1 else 2)

    /**
     * Rewrites the 44-byte header in place with the format now in force,
     * leaving the size fields at zero for [updateWavHeader] to fill in.
     */
    private fun rewriteWavHeader(outputStream: FileOutputStream) {
        outputStream.flush()
        RandomAccessFile(outputFile, "rw").use { raf ->
            raf.seek(0L)
            raf.write(wavHeaderBytes(0))
        }
    }

    /**
     * Extracts PCM audio directly without decoding.
     */
    private fun extractPcmToWav(
        extractor: MediaExtractor,
        audioFormat: MediaFormat,
        audioTrackIndex: Int,
        startUs: Long,
        endUs: Long,
        onProgress: (Double) -> Unit,
        shouldStop: () -> Boolean
    ) {
        var outputStream: FileOutputStream? = null

        try {
            // Reset total data size for this extraction
            totalDataSize = 0

            // Determine bits per sample from the source PCM encoding
            if (audioFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                val pcmEncoding = audioFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                when (pcmEncoding) {
                    AudioFormat.ENCODING_PCM_16BIT -> {
                        bitsPerSample = 16
                        isFloatPcm = false
                    }
                    AudioFormat.ENCODING_PCM_8BIT -> {
                        bitsPerSample = 8
                        isFloatPcm = false
                    }
                    AudioFormat.ENCODING_PCM_FLOAT -> {
                        // Convert float to 16-bit for better compatibility
                        bitsPerSample = 16
                        isFloatPcm = true
                    }
                    else -> {
                        bitsPerSample = 16
                        isFloatPcm = false
                    }
                }
            } else {
                bitsPerSample = 16
                isFloatPcm = false
            }

            // Select the audio track in the extractor
            extractor.selectTrack(audioTrackIndex)

            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            outputStream = FileOutputStream(outputFile)

            // Write placeholder WAV header
            writeWavHeader(outputStream, 0)

            val buffer = ByteBuffer.allocate(BUFFER_SIZE)
            val validEndUs = if (endUs == Long.MAX_VALUE) Long.MAX_VALUE else endUs
            val totalDurationUs = if (validEndUs == Long.MAX_VALUE) Long.MAX_VALUE else (validEndUs - startUs)
            var currentTimeUs = startUs

            onProgress(0.0)
            maybeInitSpeedProcessor()

            while (!shouldStop()) {
                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)

                if (sampleSize < 0) {
                    // End of stream
                    break
                }

                val presentationTimeUs = extractor.sampleTime

                if (presentationTimeUs > validEndUs) {
                    break
                }

                buffer.position(0)
                buffer.limit(sampleSize)

                val pcmData = ByteArray(sampleSize)
                buffer.get(pcmData)

                if (isFloatPcm) {
                    // Convert float PCM to 16-bit integer PCM
                    val floatBuffer = ByteBuffer.wrap(pcmData).order(ByteOrder.LITTLE_ENDIAN)
                    val floatSamples = pcmData.size / 4
                    val int16Buffer = ByteBuffer.allocate(floatSamples * 2).order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until floatSamples) {
                        val floatValue = floatBuffer.float
                        val intValue = (floatValue.coerceIn(-1.0f, 1.0f) * 32767.0f).toInt().toShort()
                        int16Buffer.putShort(intValue)
                    }
                    writePcm(outputStream, int16Buffer.array())
                } else {
                    writePcm(outputStream, pcmData)
                }

                currentTimeUs = presentationTimeUs
                if (totalDurationUs != Long.MAX_VALUE) {
                    val progress = ((currentTimeUs - startUs).toDouble() / totalDurationUs).coerceIn(0.0, 1.0)
                    onProgress(progress)
                }

                extractor.advance()
            }

            // Flush any samples buffered by the speed processor.
            flushSpeedProcessor(outputStream)

            outputStream.flush()
            outputStream.close()
            outputStream = null

            // Update WAV header with actual sizes
            updateWavHeader()

            onProgress(1.0)

        } finally {
            outputStream?.close()
        }
    }

    /**
     * Writes a WAV file header with RIFF/WAVE format.
     *
     * Note: RIFF files have a 4GB limit due to 32-bit size fields. This is a WAV format limitation.
     */
    private fun writeWavHeader(outputStream: FileOutputStream, dataSize: Long) {
        outputStream.write(wavHeaderBytes(dataSize))
    }

    /** The 44-byte RIFF/WAVE header for the current format and [dataSize]. */
    private fun wavHeaderBytes(dataSize: Long): ByteArray {
        val header = ByteBuffer.allocate(44)
        header.order(ByteOrder.LITTLE_ENDIAN)

        val byteRate = sampleRate * numChannels * bitsPerSample / 8
        val blockAlign = (numChannels * bitsPerSample / 8).toShort()

        // RIFF chunk sizes are unsigned 32-bit, so the actual WAV limit is ~4GB.
        // Clamp to 0xFFFFFFFF; .toInt() gives the correct bit pattern for ByteBuffer.putInt.
        val safeSizeForHeader = if (dataSize > 0xFFFFFFFFL) {
            0xFFFFFFFF.toInt()
        } else {
            dataSize.toInt()
        }

        // RIFF header - all values written in little-endian order
        // Magic number constants are pre-encoded for little-endian
        header.putInt(RIFF_HEADER)                          // "RIFF"
        header.putInt(36 + safeSizeForHeader)               // File size - 8
        header.putInt(WAVE_HEADER)                          // "WAVE"

        // fmt sub-chunk
        header.putInt(FMT_HEADER)                           // "fmt "
        header.putInt(16)                                   // Sub-chunk size (16 for PCM)
        header.putShort(PCM_FORMAT)                         // Audio format (1 = PCM)
        header.putShort(numChannels.toShort())              // Number of channels
        header.putInt(sampleRate)                           // Sample rate
        header.putInt(byteRate)                             // Byte rate
        header.putShort(blockAlign)                         // Block align
        header.putShort(bitsPerSample.toShort())            // Bits per sample

        // data sub-chunk
        header.putInt(DATA_HEADER)                          // "data"
        header.putInt(safeSizeForHeader)                    // Data size

        return header.array()
    }

    /**
     * Updates the WAV header with the actual file sizes after writing is complete.
     * 
     * Note: WAV files are limited to ~4GB due to unsigned 32-bit size fields in the RIFF spec.
     * If the file exceeds this, the header size fields are clamped to 0xFFFFFFFF.
     */
    private fun updateWavHeader() {
        // RIFF chunk sizes are unsigned 32-bit; clamp to 0xFFFFFFFF (~4GB).
        // .toInt() gives the correct bit pattern for ByteBuffer.putInt.
        val safeSizeForHeader = if (totalDataSize > 0xFFFFFFFFL) {
            0xFFFFFFFF.toInt()
        } else {
            totalDataSize.toInt()
        }

        RandomAccessFile(outputFile, "rw").use { raf ->
            // Update file size at byte 4 (RIFF chunk size = 36 + data size)
            // RIFF chunk size = file size - 8 bytes
            raf.seek(4L)
            val riffSize = 36 + safeSizeForHeader
            raf.write(ByteBuffer.allocate(4).apply {
                order(ByteOrder.LITTLE_ENDIAN)
                putInt(riffSize)
                flip()
            }.array())

            // Update data size at byte 40 (data chunk size)
            raf.seek(40L)
            raf.write(ByteBuffer.allocate(4).apply {
                order(ByteOrder.LITTLE_ENDIAN)
                putInt(safeSizeForHeader)
                flip()
            }.array())
        }
    }
}
