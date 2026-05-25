package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/** My tien
 * Pre-renders reversed video segments into a single MP4 temp file so that the
 * main render pipeline can consume them as a normal forward clip.
 *
 * Algorithm ("All-Intra trick"):
 *  Phase A – decode the source segment in a single forward pass and re-encode
 *    with KEY_I_FRAME_INTERVAL = 0 so every output frame is a keyframe.
 *  Phase B – read all compressed I-frames from the Phase-A temp file into
 *    memory, sort by PTS descending, remux into the output file with new
 *    monotonically-increasing PTS. Zero codec involvement: pure byte copy.
 *
 * Audio is decoded into PCM, byte-reversed per audio frame, and re-encoded
 * as AAC into the same output muxer.
 */
@UnstableApi
object VideoReverser {

    /** Result of [reverseSync]. */
    data class ReverseResult(val outputPath: String, val durationUs: Long)

    private const val DECODER_TIMEOUT_US = 10_000L
    private const val ENCODER_TIMEOUT_US = 10_000L

    /**
     * Reverses a single segment of [inputPath] (in source-time coordinates) and
     * writes it to a new temp MP4 inside [Context.getCacheDir].
     *
     * @param segmentStartUs Inclusive source start (us). Pass `0` for "from start".
     * @param segmentEndUs Exclusive source end (us). Pass [Long.MAX_VALUE] for "until end".
     * @param includeAudio When `true` the audio track is reversed too. When `false`
     *  the output is video-only.
     */
    fun reverseSync(
        context: Context,
        inputPath: String,
        segmentStartUs: Long,
        segmentEndUs: Long,
        includeAudio: Boolean,
        onProgress: (Float) -> Unit = {},
    ): ReverseResult {
        val outputFile = File(
            context.cacheDir,
            "reversed_${System.currentTimeMillis()}.mp4"
        )

        Log.i(
            RENDER_TAG,
            "Reverse pre-render starting: input=$inputPath, " +
                    "segment=${segmentStartUs / 1000}..${segmentEndUs / 1000}ms, " +
                    "audio=$includeAudio, out=${outputFile.absolutePath}"
        )

        // The muxer is shared between video + audio. MediaMuxer.addTrack() may
        // only be called BEFORE start(), so we must register both tracks before
        // writing the first sample. To make that possible we pre-encode the
        // reversed audio into a temp packet file (capturing its MediaFormat),
        // then start the muxer once the video format is also known.
        val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var muxerStarted = false
        val workDir = File(context.cacheDir, "reverse_${System.currentTimeMillis()}")
        workDir.mkdirs()
        var audioPre: AudioPreEncoded? = null

        try {
            // Phase 1: pre-encode reversed audio to a packet file (no muxer yet).
            if (includeAudio) {
                try {
                    audioPre = preEncodeReversedAudio(
                        inputPath = inputPath,
                        segmentStartUs = segmentStartUs,
                        segmentEndUs = segmentEndUs,
                        workDir = workDir,
                        onProgress = { f ->
                            // Audio gets 0..0.1, video gets 0.1..0.95, audio remux 0.95..1.0
                            onProgress((f * 0.1f).coerceIn(0f, 1f))
                        },
                    )
                } catch (e: Exception) {
                    // Audio reversal is best-effort: never fail the whole render.
                    Log.w(RENDER_TAG, "Audio pre-encode failed, continuing without audio: ${e.message}")
                    audioPre = null
                }
            }

            // Phase 2: reverse the video track. The format-ready callback adds
            // BOTH the (pre-encoded) audio track and the video track to the
            // muxer, then starts it. The returned track index is for the video.
            var audioTrackIdx = -1
            val videoResult = reverseVideoTrack(
                inputPath = inputPath,
                segmentStartUs = segmentStartUs,
                segmentEndUs = segmentEndUs,
                muxer = muxer,
                onVideoFormatReady = { videoFmt ->
                    audioPre?.let { audioTrackIdx = muxer.addTrack(it.format) }
                    val videoIdx = muxer.addTrack(videoFmt)
                    muxer.start()
                    muxerStarted = true
                    videoIdx
                },
                workDir = workDir,
                onProgress = { f ->
                    val base = if (includeAudio && audioPre != null) 0.1f else 0f
                    val share = if (includeAudio && audioPre != null) 0.85f else 1.0f
                    onProgress((base + f * share).coerceIn(0f, 1f))
                },
            )

            // Phase 3: remux buffered audio packets into the muxer.
            audioPre?.let { pre ->
                if (muxerStarted && audioTrackIdx >= 0) {
                    try {
                        writeBufferedAudio(
                            muxer = muxer,
                            audioTrackIndex = audioTrackIdx,
                            packets = pre.packetsFile,
                            onProgress = { f -> onProgress((0.95f + f * 0.05f).coerceIn(0f, 1f)) },
                        )
                    } catch (e: Exception) {
                        Log.w(RENDER_TAG, "Audio remux failed, output will be silent: ${e.message}")
                    }
                }
            }

            return ReverseResult(outputFile.absolutePath, videoResult.durationUs)
        } catch (e: Exception) {
            outputFile.delete()
            throw e
        } finally {
            try {
                if (muxerStarted) muxer.stop()
            } catch (e: Exception) {
                Log.w(RENDER_TAG, "Muxer stop failed: ${e.message}")
            }
            try {
                muxer.release()
            } catch (_: Exception) { /* ignore */ }
            try { audioPre?.packetsFile?.delete() } catch (_: Exception) {}
            // Best-effort cleanup of intermediate frame files.
            workDir.deleteRecursively()
        }
    }

    /** Pre-encoded reversed audio: AAC packets + format, both ready to be muxed. */
    private data class AudioPreEncoded(val format: MediaFormat, val packetsFile: File)

    // ---------------------------------------------------------------------
    // VIDEO
    // ---------------------------------------------------------------------

    private data class VideoReverseResult(val durationUs: Long)

    /**
     * Two-phase "All-Intra" approach:
     *
     * Phase A – [transcodeSegmentToAllIntra]: decode the source segment in a
     *   single forward pass and re-encode with KEY_I_FRAME_INTERVAL = 0 so
     *   every output frame is an independent keyframe. No seeking, no
     *   YUV file-spilling; one straight decode → encode pass.
     *
     * Phase B – [remuxReversed]: read all compressed I-frames from the Phase-A
     *   temp file into memory, sort by PTS descending, then write to the output
     *   muxer with new monotonically-increasing timestamps. Zero codec
     *   involvement — pure byte copy.
     *
     * Memory: roughly (bitrate × duration / 8) bytes for the in-memory sample
     * list, typically 20–80 MB for a 40-second 1080p clip at 4–8 Mbps.
     */
    private fun reverseVideoTrack(
        inputPath: String,
        segmentStartUs: Long,
        segmentEndUs: Long,
        muxer: MediaMuxer,
        onVideoFormatReady: (MediaFormat) -> Int,
        workDir: File,
        onProgress: (Float) -> Unit,
    ): VideoReverseResult {
        val allIntraFile = File(workDir, "all_intra.mp4")

        // Read container-level rotation from the source once so it can be
        // forwarded to the final output muxer (MediaMuxer.setOrientationHint
        // must be called before start(), which happens inside remuxReversed).
        val rotation = run {
            val ex = MediaExtractor().apply { setDataSource(inputPath) }
            try {
                val vidIdx = findTrack(ex, "video/")
                if (vidIdx != null) {
                    val fmt = ex.getTrackFormat(vidIdx)
                    if (fmt.containsKey(MediaFormat.KEY_ROTATION))
                        fmt.getInteger(MediaFormat.KEY_ROTATION)
                    else 0
                } else 0
            } finally {
                ex.release()
            }
        }

        // Phase A: single forward decode + re-encode (70 % of progress).
        transcodeSegmentToAllIntra(
            inputPath = inputPath,
            segmentStartUs = segmentStartUs,
            segmentEndUs = segmentEndUs,
            outFile = allIntraFile,
            onProgress = { f -> onProgress(f * 0.7f) },
        )

        // Phase B: byte-level reverse + remux into the shared output muxer
        //          (remaining 30 % of progress).
        val durationUs = remuxReversed(
            allIntraFile = allIntraFile,
            muxer = muxer,
            onVideoFormatReady = { fmt ->
                // Apply rotation BEFORE the muxer is started inside the callback.
                if (rotation != 0) muxer.setOrientationHint(rotation)
                onVideoFormatReady(fmt)
            },
            onProgress = { f -> onProgress(0.7f + f * 0.3f) },
        )

        return VideoReverseResult(durationUs = durationUs)
    }

    /**
     * Decodes [inputPath] within [[segmentStartUs]..[segmentEndUs]] in a
     * single forward pass and writes an all-intra H.264 MP4 to [outFile].
     * KEY_I_FRAME_INTERVAL = 0 forces every output frame to be an I-frame,
     * making Phase B (sample reorder) codec-free.
     */
    private fun transcodeSegmentToAllIntra(
        inputPath: String,
        segmentStartUs: Long,
        segmentEndUs: Long,
        outFile: File,
        onProgress: (Float) -> Unit,
    ) {
        val extractor = MediaExtractor().apply { setDataSource(inputPath) }
        val videoTrackIndex = findTrack(extractor, "video/")
            ?: throw IllegalStateException("No video track found in $inputPath")
        extractor.selectTrack(videoTrackIndex)
        val inputFormat = extractor.getTrackFormat(videoTrackIndex)

        val width = inputFormat.getInteger(MediaFormat.KEY_WIDTH)
        val height = inputFormat.getInteger(MediaFormat.KEY_HEIGHT)
        val frameRate = if (inputFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
            inputFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else 30
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)
            ?: throw IllegalStateException("Video mime missing")

        // Estimate segment duration for smooth progress reporting.
        val trackDurationUs = if (inputFormat.containsKey(MediaFormat.KEY_DURATION))
            inputFormat.getLong(MediaFormat.KEY_DURATION) else Long.MAX_VALUE
        val effectiveEndUs = if (segmentEndUs == Long.MAX_VALUE) trackDurationUs else segmentEndUs
        val totalDurationUs = (effectiveEndUs - segmentStartUs).coerceAtLeast(1L)

        Log.d(
            RENDER_TAG,
            "All-intra transcode: ${width}x$height @ ${frameRate}fps, mime=$mime, " +
                    "segment=${segmentStartUs / 1000}..${effectiveEndUs / 1000}ms"
        )

        // Encoder: H.264, all-intra (KEY_I_FRAME_INTERVAL = 0).
        val outMime = "video/avc"
        val encoderFormat = MediaFormat.createVideoFormat(outMime, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            )
            val bitRate = if (inputFormat.containsKey(MediaFormat.KEY_BIT_RATE))
                inputFormat.getInteger(MediaFormat.KEY_BIT_RATE)
            else width * height * 4
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 0) // ← every frame is a keyframe
        }
        val encoder = MediaCodec.createEncoderByType(outMime)
        encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()

        // Decoder: flexible YUV so getOutputImage() works on all devices.
        val decoderFormat = extractor.getTrackFormat(videoTrackIndex).also {
            it.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            )
        }
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(decoderFormat, null, null, 0)
        decoder.start()

        val tempMuxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        // Carry over container-level rotation so the Phase-A output file is
        // correctly oriented (required for Phase-B remux and any direct inspection).
        if (inputFormat.containsKey(MediaFormat.KEY_ROTATION)) {
            tempMuxer.setOrientationHint(inputFormat.getInteger(MediaFormat.KEY_ROTATION))
        }
        var tempMuxerStarted = false
        var tempTrackIndex = -1
        val encInfo = MediaCodec.BufferInfo()

        extractor.seekTo(segmentStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val decInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        try {
            while (!outputDone) {
                // ── Fill ALL available decoder input slots (non-blocking after first) ──
                if (!inputDone) {
                    var firstInput = true
                    while (!inputDone) {
                        val inTimeout = if (firstInput) DECODER_TIMEOUT_US else 0L
                        firstInput = false
                        val inIdx = decoder.dequeueInputBuffer(inTimeout)
                        if (inIdx < 0) break
                        val t = extractor.sampleTime
                        if (t < 0 || t >= segmentEndUs) {
                            decoder.queueInputBuffer(
                                inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            val buf = decoder.getInputBuffer(inIdx)!!
                            buf.clear()
                            val size = extractor.readSampleData(buf, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(
                                    inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(
                                    inIdx, 0, size, t, extractor.sampleFlags
                                )
                                extractor.advance()
                            }
                        }
                    }
                }

                // ── Drain ALL available decoder output frames ──────────────────────
                // Use DECODER_TIMEOUT_US on first call so we yield to the decoder;
                // thereafter non-blocking to process all buffered frames at once.
                var firstOutput = true
                while (true) {
                    val outTimeout = if (firstOutput) DECODER_TIMEOUT_US else 0L
                    firstOutput = false
                    val outIdx = decoder.dequeueOutputBuffer(decInfo, outTimeout)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            firstOutput = true // re-try with timeout after format change
                        }
                        outIdx >= 0 -> {
                            if (decInfo.size > 0) {
                                val pts = decInfo.presentationTimeUs
                                if (pts in segmentStartUs until effectiveEndUs) {
                                    val decImage = decoder.getOutputImage(outIdx)
                                    if (decImage != null) {
                                        // Drain encoder BEFORE getting its input slot to
                                        // avoid spin-waiting when the pipeline is full.
                                        drainEncoder(
                                            encoder = encoder,
                                            muxer = tempMuxer,
                                            bufferInfo = encInfo,
                                            endOfStream = false,
                                            onFormatChanged = { fmt ->
                                                if (tempTrackIndex < 0) {
                                                    tempTrackIndex = tempMuxer.addTrack(fmt)
                                                    tempMuxer.start()
                                                    tempMuxerStarted = true
                                                }
                                            },
                                            getTrackIndex = { tempTrackIndex },
                                        )
                                        // Direct decoder-image → encoder-image copy:
                                        // no intermediate I420 ByteArray, half the
                                        // memory bandwidth of the two-step approach.
                                        var encInIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                                        while (encInIdx < 0) {
                                            drainEncoder(
                                                encoder = encoder,
                                                muxer = tempMuxer,
                                                bufferInfo = encInfo,
                                                endOfStream = false,
                                                onFormatChanged = { fmt ->
                                                    if (tempTrackIndex < 0) {
                                                        tempTrackIndex = tempMuxer.addTrack(fmt)
                                                        tempMuxer.start()
                                                        tempMuxerStarted = true
                                                    }
                                                },
                                                getTrackIndex = { tempTrackIndex },
                                            )
                                            encInIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                                        }
                                        val encImage = encoder.getInputImage(encInIdx)
                                        if (encImage != null) {
                                            copyImageDirect(decImage, encImage)
                                            encoder.queueInputBuffer(
                                                encInIdx, 0, width * height * 3 / 2, pts, 0
                                            )
                                        } else {
                                            encoder.queueInputBuffer(encInIdx, 0, 0, pts, 0)
                                        }
                                        decImage.close()
                                        onProgress(
                                            ((pts - segmentStartUs).toFloat() / totalDurationUs)
                                                .coerceIn(0f, 1f)
                                        )
                                    }
                                }
                            }
                            decoder.releaseOutputBuffer(outIdx, false)
                            if ((decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                outputDone = true
                                break
                            }
                        }
                    }
                }
            }

            // Drain encoder after EOS.
            feedEncoderEos(encoder)
            drainEncoder(
                encoder = encoder,
                muxer = tempMuxer,
                bufferInfo = encInfo,
                endOfStream = true,
                onFormatChanged = { fmt ->
                    if (tempTrackIndex < 0) {
                        tempTrackIndex = tempMuxer.addTrack(fmt)
                        tempMuxer.start()
                        tempMuxerStarted = true
                    }
                },
                getTrackIndex = { tempTrackIndex },
            )
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            try { encoder.stop() } catch (_: Exception) {}
            try { encoder.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
            if (tempMuxerStarted) {
                try { tempMuxer.stop() } catch (_: Exception) {}
            }
            try { tempMuxer.release() } catch (_: Exception) {}
        }

        Log.d(RENDER_TAG, "All-intra transcode done: ${outFile.length()} bytes")
    }

    /**
     * Reads all compressed video samples from [allIntraFile] (an all-intra
     * MP4) into memory, reverses them by PTS, then writes to [muxer] with
     * monotonically-increasing timestamps. No codec is involved.
     *
     * Returns the total output duration in microseconds.
     */
    private fun remuxReversed(
        allIntraFile: File,
        muxer: MediaMuxer,
        onVideoFormatReady: (MediaFormat) -> Int,
        onProgress: (Float) -> Unit,
    ): Long {
        data class Sample(val ptsUs: Long, val data: ByteArray)

        val extractor = MediaExtractor().apply { setDataSource(allIntraFile.absolutePath) }
        val trackIdx = findTrack(extractor, "video/")
            ?: throw IllegalStateException("No video track in all-intra temp file")
        extractor.selectTrack(trackIdx)
        val format = extractor.getTrackFormat(trackIdx)

        // Load all compressed I-frames into memory.
        val samples = mutableListOf<Sample>()
        try {
            while (true) {
                val pts = extractor.sampleTime
                if (pts < 0) break
                val sampleSize = extractor.sampleSize
                if (sampleSize <= 0) { extractor.advance(); continue }
                val rawBuf = ByteArray(sampleSize.toInt())
                val wrapped = ByteBuffer.wrap(rawBuf)
                val bytesRead = extractor.readSampleData(wrapped, 0)
                if (bytesRead < 0) break
                val data = if (bytesRead.toLong() < sampleSize) rawBuf.copyOf(bytesRead) else rawBuf
                samples.add(Sample(pts, data))
                if (!extractor.advance()) break
            }
        } finally {
            extractor.release()
        }

        if (samples.isEmpty()) {
            throw IllegalStateException("All-intra file has no video samples")
        }

        Log.d(RENDER_TAG, "Remux reversed: ${samples.size} I-frames loaded, reversing…")

        // Sort descending: last original frame becomes first output frame.
        samples.sortByDescending { it.ptsUs }

        // Compute frame duration from PTS spread.
        val maxPts = samples.maxOf { it.ptsUs }
        val minPts = samples.minOf { it.ptsUs }
        val frameDurationUs = if (samples.size > 1)
            (maxPts - minPts) / (samples.size - 1)
        else
            1_000_000L / 30

        // Register video track + start the shared muxer (audio is registered
        // beforehand via the onVideoFormatReady callback in reverseSync).
        val muxerTrackIndex = onVideoFormatReady(format)

        val bufInfo = MediaCodec.BufferInfo()
        var newPts = 0L
        val total = samples.size
        for ((i, sample) in samples.withIndex()) {
            val buf = ByteBuffer.wrap(sample.data)
            bufInfo.offset = 0
            bufInfo.size = sample.data.size
            bufInfo.presentationTimeUs = newPts
            bufInfo.flags = MediaCodec.BUFFER_FLAG_KEY_FRAME
            muxer.writeSampleData(muxerTrackIndex, buf, bufInfo)
            newPts += frameDurationUs
            onProgress((i + 1).toFloat() / total)
        }

        return newPts
    }

    /**
     * Copies all three YUV planes directly from a decoder [android.media.Image]
     * into an encoder [android.media.Image], handling any combination of planar
     * (pixelStride = 1) and semi-planar (pixelStride = 2, NV12) layouts on
     * either side. This avoids allocating an intermediate I420 ByteArray and
     * halves the memory bandwidth compared to the two-step approach.
     */
    private fun copyImageDirect(src: android.media.Image, dst: android.media.Image) {
        copyImagePlane(src.planes[0], dst.planes[0], src.width,     src.height)
        copyImagePlane(src.planes[1], dst.planes[1], src.width / 2, src.height / 2)
        copyImagePlane(src.planes[2], dst.planes[2], src.width / 2, src.height / 2)
    }

    private fun copyImagePlane(
        src: android.media.Image.Plane,
        dst: android.media.Image.Plane,
        planeWidth: Int,
        planeHeight: Int,
    ) {
        val srcBuf         = src.buffer
        val dstBuf         = dst.buffer
        val srcRowStride   = src.rowStride
        val srcPixelStride = src.pixelStride
        val dstRowStride   = dst.rowStride
        val dstPixelStride = dst.pixelStride

        // Reusable row scratch buffers — allocated once per plane call.
        val srcRow = ByteArray(planeWidth)  // de-interleaved source pixels

        for (r in 0 until planeHeight) {
            // ── Read source row, de-interleaving if needed ──────────────────
            srcBuf.position(r * srcRowStride)
            if (srcPixelStride == 1) {
                srcBuf.get(srcRow, 0, planeWidth)
            } else {
                val raw = ByteArray(minOf(planeWidth * srcPixelStride, srcBuf.remaining()))
                srcBuf.get(raw)
                for (c in 0 until planeWidth) srcRow[c] = raw[c * srcPixelStride]
            }

            // ── Write to destination row, interleaving if needed ────────────
            val dstPos = r * dstRowStride
            if (dstPixelStride == 1) {
                dstBuf.position(dstPos)
                dstBuf.put(srcRow, 0, planeWidth)
            } else {
                // Interleaved dst (e.g. NV12): U and V share one buffer.
                // Read existing row first so the OTHER component's bytes are
                // preserved, then overwrite only OUR component bytes.
                val dstRow = ByteArray(minOf(planeWidth * dstPixelStride, dstBuf.limit() - dstPos))
                dstBuf.position(dstPos)
                dstBuf.get(dstRow)
                for (c in 0 until planeWidth) dstRow[c * dstPixelStride] = srcRow[c]
                dstBuf.position(dstPos)
                dstBuf.put(dstRow)
            }
        }
    }

    private fun feedEncoderEos(encoder: MediaCodec) {
        while (true) {
            val idx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
            if (idx >= 0) {
                encoder.queueInputBuffer(
                    idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                )
                return
            }
        }
    }

    private fun drainEncoder(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        bufferInfo: MediaCodec.BufferInfo,
        endOfStream: Boolean,
        onFormatChanged: (MediaFormat) -> Unit,
        getTrackIndex: () -> Int,
    ) {
        while (true) {
            val idx = encoder.dequeueOutputBuffer(bufferInfo, ENCODER_TIMEOUT_US)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                    // else continue waiting for EOS
                }
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    onFormatChanged(encoder.outputFormat)
                }
                idx >= 0 -> {
                    val outBuf = encoder.getOutputBuffer(idx)!!
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0
                    }
                    if (bufferInfo.size > 0) {
                        val trackIdx = getTrackIndex()
                        if (trackIdx >= 0) {
                            outBuf.position(bufferInfo.offset)
                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
                            muxer.writeSampleData(trackIdx, outBuf, bufferInfo)
                        }
                    }
                    encoder.releaseOutputBuffer(idx, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        return
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // AUDIO
    // ---------------------------------------------------------------------

    private fun preEncodeReversedAudio(
        inputPath: String,
        segmentStartUs: Long,
        segmentEndUs: Long,
        workDir: File,
        onProgress: (Float) -> Unit = {},
    ): AudioPreEncoded? {
        val extractor = MediaExtractor().apply { setDataSource(inputPath) }
        val audioTrackIndex = findTrack(extractor, "audio/")
        if (audioTrackIndex == null) {
            extractor.release()
            Log.d(RENDER_TAG, "Reverse audio skipped: no audio track")
            return null
        }
        extractor.selectTrack(audioTrackIndex)
        val inputFormat = extractor.getTrackFormat(audioTrackIndex)
        val sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val inMime = inputFormat.getString(MediaFormat.KEY_MIME)!!

        // 1) Decode PCM into a temp file (16-bit signed LE, frame = channelCount * 2 bytes).
        val pcmFile = File.createTempFile("rev_pcm_", ".raw")
        val decoder = MediaCodec.createDecoderByType(inMime)
        decoder.configure(inputFormat, null, null, 0)
        decoder.start()

        extractor.seekTo(segmentStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

        val bufferInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        try {
            pcmFile.outputStream().use { pcmOut ->
                while (!outputDone) {
                    if (!inputDone) {
                        val inIdx = decoder.dequeueInputBuffer(DECODER_TIMEOUT_US)
                        if (inIdx >= 0) {
                            val t = extractor.sampleTime
                            if (t < 0 || t >= segmentEndUs) {
                                decoder.queueInputBuffer(
                                    inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputDone = true
                            } else {
                                val buf = decoder.getInputBuffer(inIdx)!!
                                buf.clear()
                                val size = extractor.readSampleData(buf, 0)
                                if (size < 0) {
                                    decoder.queueInputBuffer(
                                        inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                    inputDone = true
                                } else {
                                    decoder.queueInputBuffer(inIdx, 0, size, t, 0)
                                    extractor.advance()
                                }
                            }
                        }
                    }
                    val outIdx = decoder.dequeueOutputBuffer(bufferInfo, DECODER_TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                        outIdx >= 0 -> {
                            if (bufferInfo.size > 0 &&
                                bufferInfo.presentationTimeUs in segmentStartUs until segmentEndUs
                            ) {
                                val outBuf = decoder.getOutputBuffer(outIdx)!!
                                outBuf.position(bufferInfo.offset)
                                outBuf.limit(bufferInfo.offset + bufferInfo.size)
                                val tmp = ByteArray(bufferInfo.size)
                                outBuf.get(tmp)
                                pcmOut.write(tmp)
                            }
                            decoder.releaseOutputBuffer(outIdx, false)
                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                outputDone = true
                            }
                        }
                    }
                }
            }
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }

        val pcmLength = pcmFile.length()
        val frameSize = channelCount * 2
        if (pcmLength < frameSize) {
            pcmFile.delete()
            Log.w(RENDER_TAG, "Reverse audio: no PCM samples extracted")
            return null
        }

        // 2) Set up AAC encoder.
        val outMime = "audio/mp4a-latm"
        val outFormat = MediaFormat.createAudioFormat(outMime, sampleRate, channelCount).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val encoder = MediaCodec.createEncoderByType(outMime)
        encoder.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()

        // Buffer encoded AAC packets to a file together with their BufferInfo,
        // so they can be remuxed AFTER the muxer is started (which only happens
        // once the video track format is also known).
        val packetsFile = File(workDir, "reversed_audio_packets.bin")
        val packetsOut = DataOutputStream(packetsFile.outputStream().buffered())
        var capturedAudioFormat: MediaFormat? = null
        val encInfo = MediaCodec.BufferInfo()

        fun drain(endOfStream: Boolean) {
            while (true) {
                val idx = encoder.dequeueOutputBuffer(encInfo, ENCODER_TIMEOUT_US)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!endOfStream) return
                    }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        capturedAudioFormat = encoder.outputFormat
                    }
                    idx >= 0 -> {
                        val outBuf = encoder.getOutputBuffer(idx)!!
                        val isCodecConfig =
                            (encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        if (!isCodecConfig && encInfo.size > 0) {
                            outBuf.position(encInfo.offset)
                            outBuf.limit(encInfo.offset + encInfo.size)
                            val bytes = ByteArray(encInfo.size)
                            outBuf.get(bytes)
                            packetsOut.writeInt(encInfo.size)
                            packetsOut.writeLong(encInfo.presentationTimeUs)
                            packetsOut.writeInt(encInfo.flags)
                            packetsOut.write(bytes)
                        }
                        encoder.releaseOutputBuffer(idx, false)
                        if ((encInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                    }
                }
            }
        }

        // 3) Feed PCM in reverse, frame-aligned.
        val readChunkBytes = 4096 * frameSize // ~32k per chunk; small enough for any encoder input
        val raf = RandomAccessFile(pcmFile, "r")
        val totalFrames = pcmLength / frameSize
        val sampleDurationUs = 1_000_000L / sampleRate
        var outFramePos = 0L

        try {
            var remainingFrames = totalFrames
            while (remainingFrames > 0) {
                val chunkFrames = minOf(remainingFrames, (readChunkBytes / frameSize).toLong())
                val chunkBytes = (chunkFrames * frameSize).toInt()
                val startByte = (remainingFrames - chunkFrames) * frameSize
                raf.seek(startByte)
                val chunk = ByteArray(chunkBytes)
                raf.readFully(chunk)
                reverseFramesInPlace(chunk, frameSize)

                var offset = 0
                while (offset < chunkBytes) {
                    val inIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                    if (inIdx < 0) {
                        drain(false)
                        continue
                    }
                    val buf = encoder.getInputBuffer(inIdx)!!
                    buf.clear()
                    val toWrite = minOf(buf.capacity(), chunkBytes - offset)
                    val toWriteFrameAligned = (toWrite / frameSize) * frameSize
                    if (toWriteFrameAligned == 0) {
                        encoder.queueInputBuffer(inIdx, 0, 0, 0, 0)
                        break
                    }
                    buf.put(chunk, offset, toWriteFrameAligned)
                    val ptsUs = outFramePos * sampleDurationUs
                    encoder.queueInputBuffer(inIdx, 0, toWriteFrameAligned, ptsUs, 0)
                    outFramePos += toWriteFrameAligned / frameSize
                    offset += toWriteFrameAligned
                    drain(false)
                }
                remainingFrames -= chunkFrames
                onProgress(
                    ((totalFrames - remainingFrames).toFloat() / totalFrames.toFloat())
                        .coerceIn(0f, 1f)
                )
            }
            // EOS
            while (true) {
                val inIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                if (inIdx >= 0) {
                    encoder.queueInputBuffer(
                        inIdx, 0, 0, outFramePos * sampleDurationUs,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                    )
                    break
                }
                drain(false)
            }
            drain(true)
        } finally {
            try { raf.close() } catch (_: Exception) {}
            try { pcmFile.delete() } catch (_: Exception) {}
            try { encoder.stop() } catch (_: Exception) {}
            try { encoder.release() } catch (_: Exception) {}
            try { packetsOut.close() } catch (_: Exception) {}
        }

        val format = capturedAudioFormat
        if (format == null || packetsFile.length() == 0L) {
            packetsFile.delete()
            Log.w(RENDER_TAG, "Reverse audio: encoder produced no packets")
            return null
        }
        return AudioPreEncoded(format, packetsFile)
    }

    /** Replays the packets produced by [preEncodeReversedAudio] into [muxer]. */
    private fun writeBufferedAudio(
        muxer: MediaMuxer,
        audioTrackIndex: Int,
        packets: File,
        onProgress: (Float) -> Unit,
    ) {
        val totalLength = packets.length().coerceAtLeast(1L)
        var bytesRead = 0L
        val info = MediaCodec.BufferInfo()
        DataInputStream(packets.inputStream().buffered()).use { input ->
            while (true) {
                val size = try { input.readInt() } catch (_: Exception) { break }
                val ptsUs = input.readLong()
                val flags = input.readInt()
                val bytes = ByteArray(size)
                input.readFully(bytes)
                val buf = ByteBuffer.allocate(size).apply { put(bytes); flip() }
                info.set(0, size, ptsUs, flags)
                muxer.writeSampleData(audioTrackIndex, buf, info)
                bytesRead += 4 + 8 + 4 + size
                onProgress((bytesRead.toFloat() / totalLength.toFloat()).coerceIn(0f, 1f))
            }
        }
    }

    /** Reverses `data` frame-by-frame in place (frame = [frameSize] bytes). */
    private fun reverseFramesInPlace(data: ByteArray, frameSize: Int) {
        val frames = data.size / frameSize
        val tmp = ByteArray(frameSize)
        var i = 0
        var j = frames - 1
        while (i < j) {
            System.arraycopy(data, i * frameSize, tmp, 0, frameSize)
            System.arraycopy(data, j * frameSize, data, i * frameSize, frameSize)
            System.arraycopy(tmp, 0, data, j * frameSize, frameSize)
            i++
            j--
        }
    }

    // ---------------------------------------------------------------------
    // SHARED
    // ---------------------------------------------------------------------

    private fun findTrack(extractor: MediaExtractor, mimePrefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(mimePrefix)) return i
        }
        return null
    }

    /** Deletes reversed-segment temp files (best effort). */
    fun cleanupReversedFiles(paths: Collection<String>) {
        for (path in paths) {
            try {
                val f = File(path)
                if (f.exists() && f.name.startsWith("reversed_")) {
                    f.delete()
                }
            } catch (_: Exception) { /* ignore */ }
        }
    }
}
