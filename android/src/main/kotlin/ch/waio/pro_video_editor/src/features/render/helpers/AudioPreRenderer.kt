package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pre-renders a custom audio track into a single, gap-less PCM WAV file
 * that is ready to be inserted as ONE EditedMediaItem in the Media3
 * composition.
 *
 * This is the core fix for audible clicks/gaps that occurred at every
 * loop boundary and silence/audio transition with the previous
 * implementation, where each loop iteration and silence segment was a
 * separate `EditedMediaItem`. Each item boundary forced AAC encoder
 * frame realignment, producing audible artifacts.
 *
 * The output file contains, in order:
 *   1. Leading silence (matching `compositionStartUs`)
 *   2. The trimmed source audio looped (or played once) to cover
 *      `compositionDurationUs`, with sample-exact tail trimming
 *   3. Trailing silence (matching `videoDurationUs - compositionStartUs -
 *      compositionDurationUs`)
 *
 * The output sample rate, channel count and bit depth match the decoder
 * output of the source file. Float PCM is converted to 16-bit signed PCM.
 * Final resampling/mixing happens later inside Media3's encoder pipeline.
 */
@UnstableApi
object AudioPreRenderer {

    /**
     * Result of a successful pre-render operation.
     *
     * @property outputFile The pre-rendered PCM WAV file (caller is
     *   responsible for deleting it when no longer needed).
     * @property sampleRate Sample rate of the WAV body (Hz).
     * @property channelCount Number of channels in the WAV body.
     */
    data class Result(
        val outputFile: File,
        val sampleRate: Int,
        val channelCount: Int
    )

    /**
     * Pre-renders the audio track described by the parameters.
     *
     * @param context Android context (used for `cacheDir`).
     * @param audioPath Absolute path to the source audio file.
     * @param audioStartUs Trim start within the source (microseconds, >=0).
     * @param audioEndUs Trim end within the source (microseconds, null
     *   = use full source duration).
     * @param loop If true, the trimmed window repeats to fill
     *   `compositionDurationUs`. If false, plays once and any remaining
     *   composition time is filled with silence.
     * @param compositionStartUs Where on the composition timeline the
     *   audio body should start. The output file contains this much
     *   leading silence.
     * @param compositionDurationUs How long the audio body should sound
     *   on the composition timeline.
     * @param videoDurationUs Total duration of the composition (used to
     *   determine trailing silence).
     * @return [Result] on success, null on failure (file missing, decode
     *   error, invalid parameters).
     */
    fun render(
        context: Context,
        audioPath: String,
        audioStartUs: Long,
        audioEndUs: Long?,
        loop: Boolean,
        compositionStartUs: Long,
        compositionDurationUs: Long,
        videoDurationUs: Long
    ): Result? {
        val sourceFile = File(audioPath)
        if (!sourceFile.exists()) {
            Log.e(RENDER_TAG, "AudioPreRenderer: source file not found: $audioPath")
            return null
        }

        if (compositionDurationUs <= 0L) {
            Log.w(RENDER_TAG, "AudioPreRenderer: compositionDurationUs <= 0, skipping")
            return null
        }

        // Step 1: Decode the trimmed source range into a scratch PCM file.
        val decoded = try {
            decodeRange(
                context.cacheDir, audioPath, audioStartUs.coerceAtLeast(0L), audioEndUs
            )
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "AudioPreRenderer: decode failed: ${e.message}")
            return null
        } ?: return null

        try {
            return assemble(
                context = context,
                decoded = decoded,
                loop = loop,
                compositionStartUs = compositionStartUs,
                compositionDurationUs = compositionDurationUs,
                videoDurationUs = videoDurationUs
            )
        } finally {
            decoded.pcmFile.delete()
        }
    }

    /**
     * Writes the WAV described by [decoded] and the composition timing, i.e.
     * everything after the source has been decoded.
     */
    private fun assemble(
        context: Context,
        decoded: DecodedAudio,
        loop: Boolean,
        compositionStartUs: Long,
        compositionDurationUs: Long,
        videoDurationUs: Long
    ): Result? {
        if (decoded.byteLength <= 0L) {
            Log.e(RENDER_TAG, "AudioPreRenderer: decoder produced no PCM data")
            return null
        }

        val sampleRate = decoded.sampleRate
        val channelCount = decoded.channelCount
        val bytesPerFrame = channelCount * 2 // 16-bit PCM

        // Step 2: Compute byte sizes for leading silence, audio body and
        // trailing silence using the native sample rate.
        val leadingSilenceBytes = alignToFrame(
            usToBytes(compositionStartUs, sampleRate, bytesPerFrame),
            bytesPerFrame
        )
        val bodyBytes = alignToFrame(
            usToBytes(compositionDurationUs, sampleRate, bytesPerFrame),
            bytesPerFrame
        )
        val totalCompositionBytes = leadingSilenceBytes + bodyBytes
        val totalVideoBytes = alignToFrame(
            usToBytes(videoDurationUs, sampleRate, bytesPerFrame),
            bytesPerFrame
        )
        val trailingSilenceBytes = (totalVideoBytes - totalCompositionBytes)
            .coerceAtLeast(0L)

        // Step 3: Open the output WAV file and stream the data.
        val outputFile = File(
            context.cacheDir,
            "prerender_audio_${System.currentTimeMillis()}_${System.nanoTime()}.wav"
        )

        try {
            RandomAccessFile(outputFile, "rw").use { raf ->
                writeWavHeader(raf, sampleRate, channelCount, dataSize = 0)

                writeSilence(raf, leadingSilenceBytes)

                val bodyBytesWritten = writeAudioBody(
                    raf = raf,
                    sourcePcm = decoded.pcmFile,
                    targetBytes = bodyBytes,
                    loop = loop,
                    bytesPerFrame = bytesPerFrame
                )

                writeSilence(raf, trailingSilenceBytes)

                // Update RIFF/data chunk sizes in the header.
                val totalDataBytes =
                    leadingSilenceBytes + bodyBytesWritten + trailingSilenceBytes
                updateWavSizes(raf, totalDataBytes)
            }
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "AudioPreRenderer: write failed: ${e.message}")
            outputFile.delete()
            return null
        }

        Log.d(
            RENDER_TAG,
            "AudioPreRenderer: rendered ${outputFile.length()} bytes, " +
                    "${sampleRate}Hz x ${channelCount}ch, " +
                    "leadSilence=${compositionStartUs / 1000}ms, " +
                    "body=${compositionDurationUs / 1000}ms, " +
                    "loop=$loop"
        )

        return Result(outputFile, sampleRate, channelCount)
    }

    // ---------------------------------------------------------------------
    // Internal: decoding
    // ---------------------------------------------------------------------

    /**
     * The decoded source range, spooled to disk.
     *
     * @property pcmFile Scratch file holding the raw PCM; the caller deletes it.
     * @property byteLength How many PCM bytes [pcmFile] holds.
     */
    private class DecodedAudio(
        val pcmFile: File,
        val byteLength: Long,
        val sampleRate: Int,
        val channelCount: Int
    )

    /**
     * Decodes the audio range `[startUs, endUs)` from `path` into a scratch file
     * of 16-bit signed little-endian PCM.
     *
     * The PCM goes to disk rather than into a byte array because it is the one
     * allocation here that grows with the clip: a three-minute stereo track
     * decodes to ~30 MB, and holding that (plus the copy every array growth
     * makes) is enough to push an export over Android's managed-heap limit.
     *
     * Float PCM is converted to int16. Output sample rate / channel
     * count match the decoder output.
     */
    private fun decodeRange(
        cacheDir: File,
        path: String,
        startUs: Long,
        endUs: Long?
    ): DecodedAudio? {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        val pcmFile = File(
            cacheDir,
            "prerender_pcm_${System.currentTimeMillis()}_${System.nanoTime()}.raw"
        )
        var pcmOutput: OutputStream? = null
        var decodedFully = false

        try {
            extractor.setDataSource(path)

            var audioTrackIndex = -1
            var inputFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    inputFormat = format
                    break
                }
            }

            if (audioTrackIndex < 0 || inputFormat == null) {
                Log.e(RENDER_TAG, "AudioPreRenderer: no audio track in $path")
                return null
            }

            extractor.selectTrack(audioTrackIndex)
            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            // Initial format from decoder (may change later).
            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloatPcm = false

            val decoderInitialFormat = decoder.outputFormat
            if (decoderInitialFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                sampleRate = decoderInitialFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            }
            if (decoderInitialFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                channelCount = decoderInitialFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            }
            isFloatPcm = readIsFloatPcm(decoderInitialFormat) ?: false

            val sink = BufferedOutputStream(FileOutputStream(pcmFile))
            pcmOutput = sink
            var pcmByteLength = 0L
            val effectiveEndUs = endUs ?: Long.MAX_VALUE
            val timeoutUs = 10_000L
            var inputEos = false
            var outputEos = false

            // Track the actual presentation time of the first sample we emit.
            // We only start writing PCM once we have crossed `startUs` so the
            // resulting buffer is sample-aligned with the requested trim.
            var hasCrossedStart = false

            while (!outputEos) {
                if (!inputEos) {
                    val inputBufferId = decoder.dequeueInputBuffer(timeoutUs)
                    if (inputBufferId >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputBufferId)!!
                        inputBuffer.clear()

                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        val presentationTimeUs = extractor.sampleTime

                        if (sampleSize < 0 || presentationTimeUs > effectiveEndUs) {
                            decoder.queueInputBuffer(
                                inputBufferId, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputEos = true
                        } else {
                            decoder.queueInputBuffer(
                                inputBufferId, 0, sampleSize, presentationTimeUs, 0
                            )
                            extractor.advance()
                        }
                    }
                }

                val info = MediaCodec.BufferInfo()
                val outputBufferId = decoder.dequeueOutputBuffer(info, timeoutUs)
                when {
                    outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = decoder.outputFormat
                        if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            sampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }
                        if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channelCount = newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }
                        readIsFloatPcm(newFormat)?.let { isFloatPcm = it }
                    }

                    outputBufferId >= 0 -> {
                        val outputBuffer = decoder.getOutputBuffer(outputBufferId)!!

                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEos = true
                        }

                        if (info.size > 0) {
                            val bufferStartUs = info.presentationTimeUs
                            val bytesPerFrameOut = channelCount * 2
                            val frameDurationUs =
                                if (sampleRate > 0) 1_000_000.0 / sampleRate else 0.0

                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)

                            // Convert decoder bytes to int16 PCM bytes.
                            val pcmChunk = if (isFloatPcm) {
                                convertFloatToInt16(outputBuffer, info.size)
                            } else {
                                val arr = ByteArray(info.size)
                                outputBuffer.get(arr)
                                arr
                            }

                            // Determine how many leading bytes to skip so
                            // the output starts exactly at `startUs`.
                            val skipBytes = if (!hasCrossedStart) {
                                val bytesPerFrameLocal = bytesPerFrameOut.coerceAtLeast(1)
                                val deltaUs = (startUs - bufferStartUs).coerceAtLeast(0L)
                                val rawSkip = (deltaUs * sampleRate / 1_000_000L) *
                                        bytesPerFrameLocal
                                rawSkip.coerceAtMost(pcmChunk.size.toLong()).toInt()
                            } else 0

                            // Determine how many trailing bytes to drop so
                            // the output ends exactly at `endUs`.
                            val dropBytes = if (effectiveEndUs != Long.MAX_VALUE) {
                                val bufferEndUs = bufferStartUs +
                                        ((pcmChunk.size / bytesPerFrameOut) * frameDurationUs).toLong()
                                if (bufferEndUs > effectiveEndUs) {
                                    val overUs = bufferEndUs - effectiveEndUs
                                    val rawDrop = (overUs * sampleRate / 1_000_000L) *
                                            bytesPerFrameOut
                                    rawDrop.coerceAtMost((pcmChunk.size - skipBytes).toLong())
                                        .toInt()
                                } else 0
                            } else 0

                            val writeLen = pcmChunk.size - skipBytes - dropBytes
                            if (writeLen > 0) {
                                sink.write(pcmChunk, skipBytes, writeLen)
                                pcmByteLength += writeLen
                                hasCrossedStart = true
                            }
                        }

                        decoder.releaseOutputBuffer(outputBufferId, false)

                        if (effectiveEndUs != Long.MAX_VALUE &&
                            info.presentationTimeUs >= effectiveEndUs
                        ) {
                            // We have decoded past the requested end; signal
                            // EOS so we can finish quickly.
                            outputEos = true
                        }
                    }
                }
            }

            sink.flush()
            decodedFully = true
            return DecodedAudio(
                pcmFile = pcmFile,
                byteLength = pcmByteLength,
                sampleRate = sampleRate,
                channelCount = channelCount
            )
        } finally {
            try {
                pcmOutput?.close()
            } catch (_: Exception) {
            }
            try {
                decoder?.stop()
            } catch (_: Exception) {
            }
            try {
                decoder?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
            // A range that never made it to a DecodedAudio owns no scratch file.
            if (!decodedFully) pcmFile.delete()
        }
    }

    private fun readIsFloatPcm(format: MediaFormat): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        if (!format.containsKey(MediaFormat.KEY_PCM_ENCODING)) return null
        return when (format.getInteger(MediaFormat.KEY_PCM_ENCODING)) {
            AudioFormat.ENCODING_PCM_FLOAT -> true
            else -> false
        }
    }

    private fun convertFloatToInt16(buffer: ByteBuffer, byteCount: Int): ByteArray {
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

    // ---------------------------------------------------------------------
    // Internal: WAV writing
    // ---------------------------------------------------------------------

    private fun writeWavHeader(
        raf: RandomAccessFile,
        sampleRate: Int,
        channelCount: Int,
        dataSize: Int
    ) {
        val bitsPerSample = 16
        val byteRate = sampleRate * channelCount * bitsPerSample / 8
        val blockAlign = (channelCount * bitsPerSample / 8).toShort()

        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(36 + dataSize) // RIFF chunk size
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)             // fmt subchunk size (PCM)
        header.putShort(1)            // PCM format
        header.putShort(channelCount.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort(blockAlign)
        header.putShort(bitsPerSample.toShort())
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataSize)

        raf.seek(0)
        raf.write(header.array())
    }

    private fun updateWavSizes(raf: RandomAccessFile, dataSize: Long) {
        val safeDataSize = dataSize.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        // RIFF chunk size at offset 4 (little-endian).
        raf.seek(4)
        raf.write(intToLittleEndian(36 + safeDataSize))
        // data chunk size at offset 40 (little-endian).
        raf.seek(40)
        raf.write(intToLittleEndian(safeDataSize))
        // Move back to end so subsequent writes append correctly.
        raf.seek(raf.length())
    }

    private fun writeSilence(raf: RandomAccessFile, byteCount: Long) {
        if (byteCount <= 0L) return
        val chunk = ByteArray(8192)
        var remaining = byteCount
        while (remaining > 0) {
            val toWrite = minOf(remaining, chunk.size.toLong()).toInt()
            raf.write(chunk, 0, toWrite)
            remaining -= toWrite
        }
    }

    /**
     * Copies [sourcePcm] into [raf] until [targetBytes] is covered, replaying it
     * from the start as often as needed when [loop] is set, and returns how many
     * bytes were written.
     *
     * The count is measured rather than predicted: it is what the WAV header has
     * to declare, and a header that disagrees with the body by even one frame
     * makes the file unreadable.
     */
    internal fun writeAudioBody(
        raf: RandomAccessFile,
        sourcePcm: File,
        targetBytes: Long,
        loop: Boolean,
        bytesPerFrame: Int
    ): Long {
        if (targetBytes <= 0L) return 0L

        // Align targetBytes to frame boundary (defensive).
        val alignedTarget = (targetBytes / bytesPerFrame) * bytesPerFrame
        val buffer = ByteArray(1 shl 16)
        var written = 0L

        while (written < alignedTarget) {
            val passStart = written
            FileInputStream(sourcePcm).use { source ->
                while (written < alignedTarget) {
                    val wanted = minOf(buffer.size.toLong(), alignedTarget - written).toInt()
                    val read = source.read(buffer, 0, wanted)
                    if (read <= 0) break
                    raf.write(buffer, 0, read)
                    written += read
                }
            }
            // An empty (or vanished) source would otherwise spin here forever.
            if (written == passStart || !loop) break
        }

        return written
    }

    // ---------------------------------------------------------------------
    // Internal: math helpers
    // ---------------------------------------------------------------------

    private fun usToBytes(durationUs: Long, sampleRate: Int, bytesPerFrame: Int): Long {
        if (durationUs <= 0L) return 0L
        // (durationUs * sampleRate / 1_000_000) frames * bytesPerFrame
        // Use Math.multiplyExact-style guard via Long multiplication.
        val frames = (durationUs.toDouble() * sampleRate / 1_000_000.0).toLong()
        return frames * bytesPerFrame
    }

    private fun alignToFrame(byteCount: Long, bytesPerFrame: Int): Long {
        if (bytesPerFrame <= 1) return byteCount
        return (byteCount / bytesPerFrame) * bytesPerFrame
    }

    private fun intToLittleEndian(value: Int): ByteArray {
        return ByteArray(4) { i -> ((value ushr (8 * i)) and 0xFF).toByte() }
    }
}
