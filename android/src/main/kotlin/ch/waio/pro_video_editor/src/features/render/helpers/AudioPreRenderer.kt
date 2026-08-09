package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.PcmRangeDecoder
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

            val sink = BufferedOutputStream(FileOutputStream(pcmFile))
            pcmOutput = sink

            val effectiveEndUs = endUs ?: Long.MAX_VALUE
            var pcmByteLength = 0L
            var sampleRate = 0
            var channelCount = 0

            // The extractor seeks to the sync frame at or before `startUs`, so
            // the first buffer usually begins early. Dropping that lead-in — and
            // the tail past `endUs` — is what makes the trim sample-exact, which
            // is what keeps a loop boundary gap-less.
            var hasCrossedStart = false

            PcmRangeDecoder.decode(
                extractor = extractor,
                audioTrackIndex = audioTrackIndex,
                inputFormat = inputFormat,
                startUs = startUs,
                endUs = effectiveEndUs,
                stopAfterEndUs = true,
                onFormat = { format ->
                    sampleRate = format.sampleRate
                    channelCount = format.channelCount
                },
                onPcm = { pcm, bufferStartUs, format ->
                    val bytesPerFrame = (format.channelCount * 2).coerceAtLeast(1)
                    val rate = format.sampleRate

                    val skipBytes = if (!hasCrossedStart && rate > 0) {
                        val deltaUs = (startUs - bufferStartUs).coerceAtLeast(0L)
                        ((deltaUs * rate / 1_000_000L) * bytesPerFrame)
                            .coerceAtMost(pcm.size.toLong()).toInt()
                    } else 0

                    val dropBytes = if (effectiveEndUs != Long.MAX_VALUE && rate > 0) {
                        val frameDurationUs = 1_000_000.0 / rate
                        val bufferEndUs = bufferStartUs +
                                ((pcm.size / bytesPerFrame) * frameDurationUs).toLong()
                        if (bufferEndUs > effectiveEndUs) {
                            val overUs = bufferEndUs - effectiveEndUs
                            ((overUs * rate / 1_000_000L) * bytesPerFrame)
                                .coerceAtMost((pcm.size - skipBytes).toLong()).toInt()
                        } else 0
                    } else 0

                    val writeLen = pcm.size - skipBytes - dropBytes
                    if (writeLen > 0) {
                        sink.write(pcm, skipBytes, writeLen)
                        pcmByteLength += writeLen
                        hasCrossedStart = true
                    }
                },
            )

            sink.flush()

            if (sampleRate <= 0 || channelCount <= 0) {
                Log.e(RENDER_TAG, "AudioPreRenderer: decoder reported no usable PCM format")
                return null
            }

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
                extractor.release()
            } catch (_: Exception) {
            }
            // A range that never made it to a DecodedAudio owns no scratch file.
            if (!decodedFully) pcmFile.delete()
        }
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

    /**
     * Writes the measured [dataSize] into the RIFF and data chunk headers.
     *
     * RIFF sizes are *unsigned* 32-bit, so they are clamped at `0xFFFFFFFF`
     * (~4 GB, the format's ceiling) rather than at [Int.MAX_VALUE] — clamping at
     * half the range would still let `36 + dataSize` wrap negative and write a
     * size no reader accepts, which is the corrupt-file case the measured byte
     * count exists to prevent.
     */
    internal fun updateWavSizes(raf: RandomAccessFile, dataSize: Long) {
        val safeDataSize = dataSize.coerceIn(0L, MAX_RIFF_SIZE)
        val riffSize = (36L + safeDataSize).coerceAtMost(MAX_RIFF_SIZE)
        // RIFF chunk size at offset 4 (little-endian).
        raf.seek(4)
        raf.write(uInt32ToLittleEndian(riffSize))
        // data chunk size at offset 40 (little-endian).
        raf.seek(40)
        raf.write(uInt32ToLittleEndian(safeDataSize))
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
     * Fills [targetBytes] of audio body into [raf]: [sourcePcm] copied in,
     * replayed from the start as often as needed when [loop] is set, and
     * whatever the source cannot cover left silent.
     *
     * That silence is the documented behavior for a non-looping track shorter
     * than its slot (see [render]) — and dropping the gap instead would end the
     * WAV early, finishing the export short of the video. Covering it here
     * rather than at the call site keeps the two from drifting apart.
     *
     * Returns how many bytes were written, which is [targetBytes] rounded down
     * to a frame boundary. The count is what the WAV header declares, and a
     * header that disagrees with the body by even one frame makes the file
     * unreadable.
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

        writeSilence(raf, alignedTarget - written)
        return alignedTarget
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

    /** [value] as the four little-endian bytes of an unsigned 32-bit field. */
    private fun uInt32ToLittleEndian(value: Long): ByteArray {
        return ByteArray(4) { i -> ((value ushr (8 * i)) and 0xFF).toByte() }
    }

    /** The largest value a RIFF/data chunk size field can hold. */
    private const val MAX_RIFF_SIZE = 0xFFFFFFFFL
}
