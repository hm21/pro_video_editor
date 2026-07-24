package ch.waio.pro_video_editor.src.features.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractJobHandle
import ch.waio.pro_video_editor.src.features.audio.models.AudioMergeConfig
import ch.waio.pro_video_editor.src.features.audio.models.AudioMergeSegmentConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Merges the audio of several trimmed clip windows into a single, seamlessly
 * concatenated audio file.
 *
 * Every segment's `[startUs, endUs)` window is decoded to one uniform 16-bit PCM
 * format (`targetSampleRate` / `targetChannels`), speed-adjusted and resampled
 * as needed, and concatenated back-to-back with no gaps. Segments whose source
 * has no audio track contribute silence of their normal output length instead
 * of failing. WAV output is written directly; other formats are transcoded from
 * the concatenated PCM WAV through a Media3 [Transformer] (AAC).
 *
 * A single-segment call with the default (unpinned) output format delegates to
 * [ExtractAudio] so its bytes are identical to `extractAudioToFile`.
 */
@UnstableApi
class MergeAudio(private val context: Context) {

    companion object {
        private const val TAG = "MergeAudio"
        private const val TIMEOUT_US = 10_000L
    }

    private val extractAudio = ExtractAudio(context)

    fun merge(
        config: AudioMergeConfig,
        onProgress: (Double) -> Unit,
        onComplete: (Map<String, Any>) -> Unit,
        onError: (Throwable) -> Unit
    ): AudioExtractJobHandle {
        val shouldStop = AtomicBoolean(false)
        val childHandle = AtomicReference<AudioExtractJobHandle?>(null)
        val mainHandler = Handler(Looper.getMainLooper())

        Thread {
            try {
                runMerge(config, shouldStop, childHandle, mainHandler, onProgress, onComplete, onError)
            } catch (e: Throwable) {
                mainHandler.post { onError(e) }
            }
        }.start()

        return AudioExtractJobHandle {
            shouldStop.set(true)
            childHandle.get()?.cancel()
        }
    }

    private fun runMerge(
        config: AudioMergeConfig,
        shouldStop: AtomicBoolean,
        childHandle: AtomicReference<AudioExtractJobHandle?>,
        mainHandler: Handler,
        onProgress: (Double) -> Unit,
        onComplete: (Map<String, Any>) -> Unit,
        onError: (Throwable) -> Unit
    ) {
        mainHandler.post { onProgress(0.0) }

        // Fast path: a single default-format segment with a real audio track
        // delegates to ExtractAudio for byte-for-byte parity with
        // extractAudioToFile.
        if (config.segments.size == 1 && !config.hasExplicitFormat) {
            val segment = config.segments[0]
            if (hasAudioTrack(segment.inputPath)) {
                if (shouldStop.get()) throw InterruptedException("Merge cancelled")
                val handle = extractAudio.extract(
                    config = config.extractConfig(segment),
                    onProgress = onProgress,
                    onComplete = {
                        Thread {
                            val durationUs = probeDurationUs(config.outputPath)
                            mainHandler.post {
                                onComplete(singleSegmentResult(config.outputPath, durationUs))
                            }
                        }.start()
                    },
                    onError = { e -> mainHandler.post { onError(e) } }
                )
                childHandle.set(handle)
                return
            }
            // No audio track -> fall through to the general path (silence).
        }

        val (targetRate, targetChannels) = resolveOutputFormat(config)
        val bytesPerFrame = targetChannels * 2

        val isWav = config.format.lowercase() == "wav"
        val outputFile = File(config.outputPath)
        val pcmFile = if (isWav) {
            outputFile
        } else {
            File(context.cacheDir, "merge_${config.id}_${System.nanoTime()}.wav")
        }

        val segmentFrames = ArrayList<Long>(config.segments.size)
        val count = config.segments.size

        try {
            RandomAccessFile(pcmFile, "rw").use { raf ->
                raf.setLength(0)
                writeWavHeader(raf, targetRate, targetChannels, 0)

                var totalDataBytes = 0L
                for ((index, segment) in config.segments.withIndex()) {
                    if (shouldStop.get()) throw InterruptedException("Merge cancelled")

                    val bytesWritten = if (hasAudioTrack(segment.inputPath)) {
                        decodeSegmentToRaf(
                            raf, segment, targetRate, targetChannels, shouldStop,
                            index, count, onProgress, mainHandler
                        )
                    } else {
                        val nominalUs = (segment.endUs - segment.startUs).toDouble() / segment.speed
                        val frames = (nominalUs * targetRate / 1_000_000.0).roundToLong()
                        val silenceBytes = frames * bytesPerFrame
                        writeSilence(raf, silenceBytes, shouldStop)
                        mainHandler.post { onProgress(min((index + 1.0) / count, 0.99)) }
                        silenceBytes
                    }

                    totalDataBytes += bytesWritten
                    segmentFrames.add(bytesWritten / bytesPerFrame)
                }

                updateWavSizes(raf, totalDataBytes)
            }
        } catch (e: Throwable) {
            if (!isWav) pcmFile.delete() else if (outputFile.exists()) outputFile.delete()
            throw e
        }

        if (shouldStop.get()) {
            pcmFile.delete()
            throw InterruptedException("Merge cancelled")
        }

        // Transcode the concatenated PCM WAV to the requested container.
        if (!isWav) {
            try {
                transcode(pcmFile, outputFile, shouldStop, childHandle, mainHandler)
            } finally {
                pcmFile.delete()
            }
        }

        val result = buildResult(config.outputPath, segmentFrames, targetRate)
        mainHandler.post {
            onProgress(1.0)
            onComplete(result)
        }
    }

    // ---------------------------------------------------------------------
    // Segment decode
    // ---------------------------------------------------------------------

    /**
     * Decodes one segment's trimmed, speed-adjusted window to uniform PCM
     * (`targetRate` / `targetChannels`) and appends it to [raf]. Returns the
     * number of PCM bytes written.
     */
    private fun decodeSegmentToRaf(
        raf: RandomAccessFile,
        segment: AudioMergeSegmentConfig,
        targetRate: Int,
        targetChannels: Int,
        shouldStop: AtomicBoolean,
        segmentIndex: Int,
        segmentCount: Int,
        onProgress: (Double) -> Unit,
        mainHandler: Handler
    ): Long {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var speedProcessor: PcmSpeedProcessor? = null
        var bytesWritten = 0L

        try {
            extractor.setDataSource(segment.inputPath)
            val audioTrackIndex = findAudioTrack(extractor)
            if (audioTrackIndex < 0) return 0L

            val inputFormat = extractor.getTrackFormat(audioTrackIndex)
            extractor.selectTrack(audioTrackIndex)
            if (segment.startUs > 0) {
                extractor.seekTo(segment.startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            var srcRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var srcChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloatPcm = false
            decoder.outputFormat.let { f ->
                if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                }
                if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                    srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
                isFloatPcm = readIsFloatPcm(f) ?: false
            }

            // Sonic is only needed when the speed or the sample rate changes; it
            // runs on `targetChannels` (channel conversion happens first).
            val needsSonic = segment.speed != 1.0f || srcRate != targetRate
            if (needsSonic) {
                speedProcessor = PcmSpeedProcessor(
                    speed = segment.speed,
                    sampleRate = srcRate,
                    channelCount = targetChannels,
                    outputSampleRate = targetRate
                )
            }

            fun processAndWrite(pcm: ByteArray) {
                if (pcm.isEmpty()) return
                val converted =
                    if (srcChannels != targetChannels) convertChannels(pcm, srcChannels, targetChannels)
                    else pcm
                val out = speedProcessor?.process(converted) ?: converted
                if (out.isNotEmpty()) {
                    raf.write(out)
                    bytesWritten += out.size
                }
            }

            val effectiveEndUs = segment.endUs
            val trimDurationUs = (segment.endUs - segment.startUs).coerceAtLeast(1L)
            var inputEos = false
            var outputEos = false
            var hasCrossedStart = false
            val bufferInfo = MediaCodec.BufferInfo()

            while (!outputEos) {
                if (shouldStop.get()) throw InterruptedException("Merge cancelled")

                if (!inputEos) {
                    val inIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inIndex)!!
                        inputBuffer.clear()
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        val presentationTimeUs = extractor.sampleTime
                        if (sampleSize < 0 || presentationTimeUs > effectiveEndUs) {
                            decoder.queueInputBuffer(
                                inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputEos = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, sampleSize, presentationTimeUs, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = decoder.outputFormat
                        if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }
                        if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }
                        readIsFloatPcm(f)?.let { isFloatPcm = it }
                    }

                    outIndex >= 0 -> {
                        val outputBuffer = decoder.getOutputBuffer(outIndex)!!
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEos = true
                        }

                        if (bufferInfo.size > 0) {
                            val bufferStartUs = bufferInfo.presentationTimeUs
                            val bytesPerFrameOut = srcChannels * 2
                            val frameDurationUs = if (srcRate > 0) 1_000_000.0 / srcRate else 0.0

                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                            val pcmChunk = if (isFloatPcm) {
                                convertFloatToInt16(outputBuffer, bufferInfo.size)
                            } else {
                                val arr = ByteArray(bufferInfo.size)
                                outputBuffer.get(arr)
                                arr
                            }

                            val skipBytes = if (!hasCrossedStart) {
                                val deltaUs = (segment.startUs - bufferStartUs).coerceAtLeast(0L)
                                val rawSkip = (deltaUs * srcRate / 1_000_000L) * bytesPerFrameOut
                                rawSkip.coerceAtMost(pcmChunk.size.toLong()).toInt()
                            } else 0

                            val dropBytes = run {
                                val bufferEndUs = bufferStartUs +
                                    ((pcmChunk.size / bytesPerFrameOut) * frameDurationUs).toLong()
                                if (bufferEndUs > effectiveEndUs) {
                                    val overUs = bufferEndUs - effectiveEndUs
                                    val rawDrop = (overUs * srcRate / 1_000_000L) * bytesPerFrameOut
                                    rawDrop.coerceAtMost((pcmChunk.size - skipBytes).toLong()).toInt()
                                } else 0
                            }

                            val writeLen = pcmChunk.size - skipBytes - dropBytes
                            if (writeLen > 0) {
                                processAndWrite(pcmChunk.copyOfRange(skipBytes, skipBytes + writeLen))
                                hasCrossedStart = true

                                val elapsedUs = (bufferStartUs - segment.startUs).coerceAtLeast(0L)
                                val fraction = (elapsedUs.toDouble() / trimDurationUs).coerceIn(0.0, 1.0)
                                val overall = (segmentIndex + fraction) / segmentCount
                                mainHandler.post { onProgress(min(overall, 0.99)) }
                            }
                        }

                        decoder.releaseOutputBuffer(outIndex, false)

                        if (bufferInfo.presentationTimeUs >= effectiveEndUs) {
                            outputEos = true
                        }
                    }
                }
            }

            speedProcessor?.drain()?.let { tail ->
                if (tail.isNotEmpty()) {
                    raf.write(tail)
                    bytesWritten += tail.size
                }
            }

            return bytesWritten
        } finally {
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
        }
    }

    /** Converts interleaved 16-bit PCM between channel counts. */
    private fun convertChannels(pcm: ByteArray, srcCh: Int, dstCh: Int): ByteArray {
        if (srcCh == dstCh || srcCh <= 0 || dstCh <= 0) return pcm
        val srcFrameBytes = srcCh * 2
        val frameCount = pcm.size / srcFrameBytes
        val out = ByteArray(frameCount * dstCh * 2)
        val inBuf = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN)
        val outBuf = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        val samples = ShortArray(srcCh)
        for (frame in 0 until frameCount) {
            for (c in 0 until srcCh) samples[c] = inBuf.short
            when {
                dstCh == 1 -> {
                    var sum = 0
                    for (c in 0 until srcCh) sum += samples[c]
                    outBuf.putShort((sum / srcCh).toShort())
                }
                srcCh == 1 -> for (c in 0 until dstCh) outBuf.putShort(samples[0])
                else -> for (c in 0 until dstCh) {
                    outBuf.putShort(if (c < srcCh) samples[c] else samples[srcCh - 1])
                }
            }
        }
        return out
    }

    private fun readIsFloatPcm(format: MediaFormat): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        if (!format.containsKey(MediaFormat.KEY_PCM_ENCODING)) return null
        return format.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
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
    // Transcode (non-WAV)
    // ---------------------------------------------------------------------

    /**
     * Transcodes a PCM WAV file to AAC (m4a/aac container) using a Media3
     * [Transformer]. Blocks the calling (background) thread until the export
     * finishes; the Transformer itself runs on the main Looper.
     */
    private fun transcode(
        input: File,
        output: File,
        shouldStop: AtomicBoolean,
        childHandle: AtomicReference<AudioExtractJobHandle?>,
        mainHandler: Handler
    ) {
        val latch = CountDownLatch(1)
        val errorRef = AtomicReference<Throwable?>(null)

        mainHandler.post {
            if (shouldStop.get()) {
                latch.countDown()
                return@post
            }
            try {
                if (output.exists()) output.delete()
                val mediaItem = MediaItem.fromUri(Uri.fromFile(input))
                val editedMediaItem = EditedMediaItem.Builder(mediaItem)
                    .setRemoveVideo(true)
                    .build()
                val transformer = Transformer.Builder(context)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            latch.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            result: ExportResult,
                            exception: ExportException
                        ) {
                            errorRef.set(exception)
                            latch.countDown()
                        }
                    })
                    .build()
                childHandle.set(AudioExtractJobHandle { mainHandler.post { transformer.cancel() } })
                transformer.start(editedMediaItem, output.absolutePath)
            } catch (e: Exception) {
                errorRef.set(e)
                latch.countDown()
            }
        }

        latch.await()
        errorRef.get()?.let { throw it }
    }

    // ---------------------------------------------------------------------
    // Probing
    // ---------------------------------------------------------------------

    private fun resolveOutputFormat(config: AudioMergeConfig): Pair<Int, Int> {
        var rate = config.sampleRate ?: 0
        var channels = config.channels ?: 0
        if (rate <= 0 || channels <= 0) {
            for (segment in config.segments) {
                val format = probeAudioFormat(segment.inputPath) ?: continue
                if (rate <= 0) rate = format.first
                if (channels <= 0) channels = format.second
                break
            }
        }
        if (rate <= 0) rate = 44100
        if (channels <= 0) channels = 2
        return Pair(rate, channels)
    }

    private fun probeAudioFormat(path: String): Pair<Int, Int>? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val index = findAudioTrack(extractor)
            if (index < 0) return null
            val format = extractor.getTrackFormat(index)
            val rate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else 0
            val channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else 0
            return if (rate > 0) Pair(rate, if (channels > 0) channels else 2) else null
        } catch (e: Exception) {
            return null
        } finally {
            extractor.release()
        }
    }

    private fun hasAudioTrack(path: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            findAudioTrack(extractor) >= 0
        } catch (e: Exception) {
            false
        } finally {
            extractor.release()
        }
    }

    private fun probeDurationUs(path: String): Long {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val index = findAudioTrack(extractor)
            if (index < 0) return 0L
            val format = extractor.getTrackFormat(index)
            if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION)
            else 0L
        } catch (e: Exception) {
            0L
        } finally {
            extractor.release()
        }
    }

    private fun findAudioTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return -1
    }

    // ---------------------------------------------------------------------
    // Result
    // ---------------------------------------------------------------------

    private fun singleSegmentResult(outputPath: String, durationUs: Long): Map<String, Any> = mapOf(
        "outputPath" to outputPath,
        "totalDurationUs" to durationUs,
        "segments" to listOf(
            mapOf("outputStartUs" to 0L, "outputDurationUs" to durationUs)
        )
    )

    /**
     * Builds the result map from per-segment frame counts. Offsets are derived
     * from cumulative frame boundaries so `start[i] + dur[i] == start[i+1]` and
     * `sum(dur) == total` hold exactly.
     */
    private fun buildResult(
        outputPath: String,
        segmentFrames: List<Long>,
        sampleRate: Int
    ): Map<String, Any> {
        val bounds = LongArray(segmentFrames.size + 1)
        for (i in segmentFrames.indices) bounds[i + 1] = bounds[i] + segmentFrames[i]

        fun framesToUs(frames: Long): Long =
            (frames.toDouble() * 1_000_000.0 / sampleRate).roundToLong()

        val segments = ArrayList<Map<String, Any>>(segmentFrames.size)
        for (i in segmentFrames.indices) {
            val startUs = framesToUs(bounds[i])
            val endUs = framesToUs(bounds[i + 1])
            segments.add(mapOf("outputStartUs" to startUs, "outputDurationUs" to (endUs - startUs)))
        }

        return mapOf(
            "outputPath" to outputPath,
            "totalDurationUs" to framesToUs(bounds[segmentFrames.size]),
            "segments" to segments
        )
    }

    // ---------------------------------------------------------------------
    // WAV writing
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
        header.putInt(36 + dataSize)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1)
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
        raf.seek(4)
        raf.write(intToLittleEndian(36 + safeDataSize))
        raf.seek(40)
        raf.write(intToLittleEndian(safeDataSize))
        raf.seek(raf.length())
    }

    private fun writeSilence(raf: RandomAccessFile, byteCount: Long, shouldStop: AtomicBoolean) {
        if (byteCount <= 0L) return
        val chunk = ByteArray(1 shl 16)
        var remaining = byteCount
        while (remaining > 0) {
            if (shouldStop.get()) throw InterruptedException("Merge cancelled")
            val toWrite = min(remaining, chunk.size.toLong()).toInt()
            raf.write(chunk, 0, toWrite)
            remaining -= toWrite
        }
    }

    private fun intToLittleEndian(value: Int): ByteArray =
        ByteArray(4) { i -> ((value ushr (8 * i)) and 0xFF).toByte() }
}
