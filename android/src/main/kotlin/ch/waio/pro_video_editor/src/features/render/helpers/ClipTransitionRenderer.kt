package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Pre-renders an **overlap** clip transition (dissolve / slide / push / wipe)
 * into a single short MP4 that the main render pipeline consumes as an ordinary
 * forward clip.
 *
 * It decodes the **tail** of the outgoing clip and the **head** of the incoming
 * clip into packed I420 frames, blends them per output frame according to the
 * transition [type]/[direction], and re-encodes the result. The two segments
 * must share the same dimensions (which split clips from one source always do);
 * if they differ the renderer returns `null` so the caller can fall back to a
 * hard cut.
 *
 * This mirrors [VideoReverser]'s MediaCodec decode → encode → mux approach and
 * is intentionally isolated from the main composition so a failure degrades to
 * a plain cut rather than crashing the render.
 */
@UnstableApi
object ClipTransitionRenderer {

    /** Result of [renderSync]. */
    data class TransitionResult(val outputPath: String, val durationUs: Long)

    private const val DECODER_TIMEOUT_US = 10_000L
    private const val ENCODER_TIMEOUT_US = 10_000L
    private const val DEFAULT_FPS = 30

    /**
     * Renders the blended transition segment.
     *
     * @param outTailStartUs Inclusive source start of the outgoing clip's tail.
     * @param outTailEndUs Exclusive source end of the outgoing clip's tail.
     * @param inHeadStartUs Inclusive source start of the incoming clip's head.
     * @param inHeadEndUs Exclusive source end of the incoming clip's head.
     * @return The rendered transition clip, or `null` if it could not be
     *  produced (caller should fall back to a hard cut).
     */
    fun renderSync(
        context: Context,
        outgoingPath: String,
        outTailStartUs: Long,
        outTailEndUs: Long,
        incomingPath: String,
        inHeadStartUs: Long,
        inHeadEndUs: Long,
        type: String,
        direction: String,
        curve: String,
        includeAudio: Boolean,
        onProgress: (Float) -> Unit = {},
    ): TransitionResult? {
        val outputFile = File(context.cacheDir, "transition_${System.currentTimeMillis()}.mp4")
        val workDir = File(context.cacheDir, "transition_work_${System.currentTimeMillis()}")
        workDir.mkdirs()

        Log.i(
            RENDER_TAG,
            "Transition pre-render: type=$type dir=$direction, " +
                    "out=${outTailStartUs / 1000}..${outTailEndUs / 1000}ms, " +
                    "in=${inHeadStartUs / 1000}..${inHeadEndUs / 1000}ms"
        )

        try {
            // 1) Decode both segments to packed I420 frames.
            val outSeg = decodeSegment(outgoingPath, outTailStartUs, outTailEndUs)
            val inSeg = decodeSegment(incomingPath, inHeadStartUs, inHeadEndUs)

            if (outSeg == null || inSeg == null ||
                outSeg.frames.isEmpty() || inSeg.frames.isEmpty()
            ) {
                Log.w(RENDER_TAG, "Transition: failed to decode one of the segments")
                return null
            }
            if (outSeg.width != inSeg.width || outSeg.height != inSeg.height) {
                Log.w(
                    RENDER_TAG,
                    "Transition: dimension mismatch " +
                            "(${outSeg.width}x${outSeg.height} vs ${inSeg.width}x${inSeg.height}); " +
                            "falling back to hard cut"
                )
                return null
            }

            val width = outSeg.width
            val height = outSeg.height
            val frameCount = outSeg.frames.size
            val tailDurationUs = (outTailEndUs - outTailStartUs).coerceAtLeast(1L)
            val frameDurationUs = tailDurationUs / frameCount

            // 2) Pre-encode the cross-faded audio (best effort, no muxer yet).
            var audioPre: AudioPreEncoded? = null
            if (includeAudio) {
                try {
                    audioPre = preEncodeCrossfadeAudio(
                        outgoingPath, outTailStartUs, outTailEndUs,
                        incomingPath, inHeadStartUs, inHeadEndUs,
                        curve, workDir
                    )
                } catch (e: Exception) {
                    Log.w(RENDER_TAG, "Transition audio crossfade failed: ${e.message}")
                    audioPre = null
                }
            }

            // 3) Encode the blended video frames into the shared muxer.
            val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var muxerStarted = false
            var audioTrackIdx = -1
            var videoTrackIdx = -1
            val encoder = createEncoder(width, height, frameDurationUs)
            val encInfo = MediaCodec.BufferInfo()

            try {
                var nextEncoderFrame = 0
                var outputDone = false

                // Feed all blended frames, draining the encoder as we go.
                while (!outputDone) {
                    // Feed one frame if available.
                    if (nextEncoderFrame < frameCount) {
                        val inIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                        if (inIdx >= 0) {
                            val progress = if (frameCount > 1) {
                                nextEncoderFrame.toDouble() / (frameCount - 1)
                            } else 1.0
                            val eased = applyEasing(progress, curve)
                            val bIdx = if (frameCount > 1) {
                                (progress * (inSeg.frames.size - 1)).roundToInt()
                            } else inSeg.frames.size - 1
                            val blended = blendFrame(
                                outSeg.frames[nextEncoderFrame],
                                inSeg.frames[bIdx.coerceIn(0, inSeg.frames.size - 1)],
                                width, height, eased, type, direction
                            )
                            val encImage = encoder.getInputImage(inIdx)
                            if (encImage != null) {
                                i420ToImage(blended, encImage, width, height)
                                encoder.queueInputBuffer(
                                    inIdx, 0, width * height * 3 / 2,
                                    nextEncoderFrame * frameDurationUs, 0
                                )
                            } else {
                                encoder.queueInputBuffer(
                                    inIdx, 0, 0, nextEncoderFrame * frameDurationUs, 0
                                )
                            }
                            nextEncoderFrame++
                            onProgress((nextEncoderFrame.toFloat() / frameCount).coerceIn(0f, 1f))
                            if (nextEncoderFrame == frameCount) {
                                // Signal EOS after the final frame.
                                val eosIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                                if (eosIdx >= 0) {
                                    encoder.queueInputBuffer(
                                        eosIdx, 0, 0,
                                        nextEncoderFrame * frameDurationUs,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                }
                            }
                        }
                    }

                    // Drain available encoder output.
                    val outIdx = encoder.dequeueOutputBuffer(encInfo, ENCODER_TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> { /* keep feeding */ }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            audioPre?.let { audioTrackIdx = muxer.addTrack(it.format) }
                            videoTrackIdx = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                        outIdx >= 0 -> {
                            val outBuf = encoder.getOutputBuffer(outIdx)!!
                            if ((encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                encInfo.size = 0
                            }
                            if (encInfo.size > 0 && muxerStarted && videoTrackIdx >= 0) {
                                outBuf.position(encInfo.offset)
                                outBuf.limit(encInfo.offset + encInfo.size)
                                muxer.writeSampleData(videoTrackIdx, outBuf, encInfo)
                            }
                            encoder.releaseOutputBuffer(outIdx, false)
                            if ((encInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                outputDone = true
                            }
                        }
                    }
                }

                // Replay buffered audio packets into the shared muxer.
                audioPre?.let { pre ->
                    if (muxerStarted && audioTrackIdx >= 0) {
                        try {
                            writeBufferedAudio(muxer, audioTrackIdx, pre.packetsFile)
                        } catch (e: Exception) {
                            Log.w(RENDER_TAG, "Transition audio remux failed: ${e.message}")
                        }
                    }
                }
            } finally {
                try { encoder.stop() } catch (_: Exception) {}
                try { encoder.release() } catch (_: Exception) {}
                if (muxerStarted) {
                    try { muxer.stop() } catch (_: Exception) {}
                }
                try { muxer.release() } catch (_: Exception) {}
                try { audioPre?.packetsFile?.delete() } catch (_: Exception) {}
            }

            val durationUs = frameCount * frameDurationUs
            Log.i(
                RENDER_TAG,
                "Transition pre-render done: ${outputFile.length()} bytes, " +
                        "${durationUs / 1000}ms, $frameCount frames"
            )
            return TransitionResult(outputFile.absolutePath, durationUs)
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Transition pre-render failed: ${e.message}", e)
            outputFile.delete()
            return null
        } finally {
            workDir.deleteRecursively()
        }
    }

    /** Deletes transition temp files (best effort). */
    fun cleanupFiles(paths: Collection<String>) {
        for (path in paths) {
            try {
                val f = File(path)
                if (f.exists() && f.name.startsWith("transition_")) f.delete()
            } catch (_: Exception) { /* ignore */ }
        }
    }

    // ---------------------------------------------------------------------
    // VIDEO DECODE
    // ---------------------------------------------------------------------

    private class DecodedSegment(
        val frames: MutableList<ByteArray>,
        val width: Int,
        val height: Int,
    )

    /**
     * Decodes [path] within [[startUs]..[endUs]] into packed I420 frames.
     */
    private fun decodeSegment(path: String, startUs: Long, endUs: Long): DecodedSegment? {
        val extractor = MediaExtractor().apply { setDataSource(path) }
        val videoTrackIndex = findTrack(extractor, "video/") ?: run {
            extractor.release(); return null
        }
        extractor.selectTrack(videoTrackIndex)
        val inputFormat = extractor.getTrackFormat(videoTrackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: run {
            extractor.release(); return null
        }
        val width = inputFormat.getInteger(MediaFormat.KEY_WIDTH)
        val height = inputFormat.getInteger(MediaFormat.KEY_HEIGHT)

        val decoderFormat = inputFormat.also {
            it.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            )
        }
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(decoderFormat, null, null, 0)
        decoder.start()

        val frames = mutableListOf<ByteArray>()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIdx = decoder.dequeueInputBuffer(DECODER_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val t = extractor.sampleTime
                        if (t < 0 || t >= endUs) {
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
                                decoder.queueInputBuffer(inIdx, 0, size, t, extractor.sampleFlags)
                                extractor.advance()
                            }
                        }
                    }
                }

                val outIdx = decoder.dequeueOutputBuffer(info, DECODER_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                    outIdx >= 0 -> {
                        if (info.size > 0 && info.presentationTimeUs in startUs until endUs) {
                            val image = decoder.getOutputImage(outIdx)
                            if (image != null) {
                                frames.add(imageToI420(image, width, height))
                                image.close()
                            }
                        }
                        decoder.releaseOutputBuffer(outIdx, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            outputDone = true
                        }
                    }
                }
            }
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }

        return if (frames.isEmpty()) null else DecodedSegment(frames, width, height)
    }

    // ---------------------------------------------------------------------
    // BLENDING
    // ---------------------------------------------------------------------

    /**
     * Blends two packed I420 frames [a] (outgoing) and [b] (incoming) according
     * to the transition [type]/[direction] at eased [p] (0 = fully outgoing,
     * 1 = fully incoming).
     */
    private fun blendFrame(
        a: ByteArray, b: ByteArray, w: Int, h: Int,
        p: Double, type: String, direction: String,
    ): ByteArray {
        val out = ByteArray(a.size)
        if (type == "dissolve") {
            // Linear per-component blend across all three planes.
            val inv = 1.0 - p
            for (i in a.indices) {
                val av = a[i].toInt() and 0xFF
                val bv = b[i].toInt() and 0xFF
                out[i] = (av * inv + bv * p).roundToInt().coerceIn(0, 255).toByte()
            }
            return out
        }

        val cw = w / 2
        val ch = h / 2
        val ySize = w * h
        val cSize = cw * ch

        // Y plane.
        composePlane(a, b, out, 0, w, h, p, type, direction)
        // U plane.
        composePlane(a, b, out, ySize, cw, ch, p, type, direction)
        // V plane.
        composePlane(a, b, out, ySize + cSize, cw, ch, p, type, direction)
        return out
    }

    /**
     * Composes a single plane for geometric transitions (wipe/slide/push) by
     * selecting, per output pixel, a source ([a] or [b]) and a source
     * coordinate.
     */
    private fun composePlane(
        a: ByteArray, b: ByteArray, out: ByteArray, offset: Int,
        pw: Int, ph: Int, p: Double, type: String, direction: String,
    ) {
        val shiftX = (p * pw).roundToInt()
        val shiftY = (p * ph).roundToInt()
        for (y in 0 until ph) {
            for (x in 0 until pw) {
                val o = offset + y * pw + x
                var useIncoming = false
                var sx = x
                var sy = y
                when (type) {
                    "wipe" -> {
                        useIncoming = when (direction) {
                            "right" -> x < shiftX
                            "left" -> x >= pw - shiftX
                            "down" -> y < shiftY
                            "up" -> y >= ph - shiftY
                            else -> x < shiftX
                        }
                    }
                    "slide" -> {
                        // Incoming slides in over a stationary outgoing.
                        when (direction) {
                            "left" -> {
                                val edge = pw - shiftX
                                if (x >= edge) { useIncoming = true; sx = x - edge }
                            }
                            "right" -> {
                                if (x < shiftX) { useIncoming = true; sx = x + (pw - shiftX) }
                            }
                            "up" -> {
                                val edge = ph - shiftY
                                if (y >= edge) { useIncoming = true; sy = y - edge }
                            }
                            "down" -> {
                                if (y < shiftY) { useIncoming = true; sy = y + (ph - shiftY) }
                            }
                        }
                    }
                    "push" -> {
                        // Both clips move together.
                        when (direction) {
                            "left" -> {
                                if (x < pw - shiftX) { sx = x + shiftX }
                                else { useIncoming = true; sx = x - (pw - shiftX) }
                            }
                            "right" -> {
                                if (x >= shiftX) { sx = x - shiftX }
                                else { useIncoming = true; sx = x + (pw - shiftX) }
                            }
                            "up" -> {
                                if (y < ph - shiftY) { sy = y + shiftY }
                                else { useIncoming = true; sy = y - (ph - shiftY) }
                            }
                            "down" -> {
                                if (y >= shiftY) { sy = y - shiftY }
                                else { useIncoming = true; sy = y + (ph - shiftY) }
                            }
                        }
                    }
                }
                sx = sx.coerceIn(0, pw - 1)
                sy = sy.coerceIn(0, ph - 1)
                val src = if (useIncoming) b else a
                out[o] = src[offset + sy * pw + sx]
            }
        }
    }

    // ---------------------------------------------------------------------
    // I420 <-> Image
    // ---------------------------------------------------------------------

    /** Converts a decoder [Image] (YUV420 flexible) to a packed I420 array. */
    private fun imageToI420(image: Image, width: Int, height: Int): ByteArray {
        val out = ByteArray(width * height * 3 / 2)
        val cw = width / 2
        val ch = height / 2
        readPlane(image.planes[0], out, 0, width, height)
        readPlane(image.planes[1], out, width * height, cw, ch)
        readPlane(image.planes[2], out, width * height + cw * ch, cw, ch)
        return out
    }

    private fun readPlane(
        plane: Image.Plane, dst: ByteArray, dstOffset: Int, pw: Int, ph: Int,
    ) {
        val buf = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val row = ByteArray(rowStride)
        for (r in 0 until ph) {
            val pos = r * rowStride
            if (pos >= buf.limit()) break
            buf.position(pos)
            val toRead = min(rowStride, buf.remaining())
            buf.get(row, 0, toRead)
            val base = dstOffset + r * pw
            if (pixelStride == 1) {
                System.arraycopy(row, 0, dst, base, min(pw, toRead))
            } else {
                var c = 0
                while (c < pw && c * pixelStride < toRead) {
                    dst[base + c] = row[c * pixelStride]
                    c++
                }
            }
        }
    }

    /** Writes a packed I420 array into an encoder input [Image]. */
    private fun i420ToImage(src: ByteArray, image: Image, width: Int, height: Int) {
        val cw = width / 2
        val ch = height / 2
        writePlane(src, 0, image.planes[0], width, height)
        writePlane(src, width * height, image.planes[1], cw, ch)
        writePlane(src, width * height + cw * ch, image.planes[2], cw, ch)
    }

    private fun writePlane(
        src: ByteArray, srcOffset: Int, plane: Image.Plane, pw: Int, ph: Int,
    ) {
        val buf = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        for (r in 0 until ph) {
            val pos = r * rowStride
            if (pos >= buf.limit()) break
            val base = srcOffset + r * pw
            if (pixelStride == 1) {
                buf.position(pos)
                buf.put(src, base, min(pw, buf.remaining()))
            } else {
                val rowLen = min(rowStride, buf.limit() - pos)
                val rowBytes = ByteArray(rowLen)
                buf.position(pos)
                buf.get(rowBytes)
                var c = 0
                while (c < pw && c * pixelStride < rowLen) {
                    rowBytes[c * pixelStride] = src[base + c]
                    c++
                }
                buf.position(pos)
                buf.put(rowBytes)
            }
        }
    }

    // ---------------------------------------------------------------------
    // ENCODER
    // ---------------------------------------------------------------------

    private fun createEncoder(width: Int, height: Int, frameDurationUs: Long): MediaCodec {
        val mime = "video/avc"
        val fps = if (frameDurationUs > 0) {
            (1_000_000.0 / frameDurationUs).roundToInt().coerceIn(1, 120)
        } else DEFAULT_FPS
        val range = avcBitrateRange()
        val candidates = listOf(width * height * 6, width * height * 4, width * height * 2)
            .map { if (range != null) it.coerceIn(range.lower, range.upper) else it }
            .filter { it > 0 }
            .distinct()
        var lastError: Exception? = null
        for (bitrate in candidates) {
            val format = MediaFormat.createVideoFormat(mime, width, height).apply {
                setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
                )
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val encoder = MediaCodec.createEncoderByType(mime)
            try {
                encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                encoder.start()
                return encoder
            } catch (e: Exception) {
                try { encoder.release() } catch (_: Exception) {}
                lastError = e
            }
        }
        throw IllegalStateException("Failed to configure transition encoder", lastError)
    }

    private fun avcBitrateRange(): android.util.Range<Int>? = try {
        MediaCodecList(MediaCodecList.REGULAR_CODECS)
            .codecInfos
            .firstOrNull { it.isEncoder && it.supportedTypes.any { t -> t.equals("video/avc", true) } }
            ?.getCapabilitiesForType("video/avc")
            ?.videoCapabilities
            ?.bitrateRange
    } catch (_: Exception) {
        null
    }

    // ---------------------------------------------------------------------
    // AUDIO CROSSFADE
    // ---------------------------------------------------------------------

    private data class AudioPreEncoded(val format: MediaFormat, val packetsFile: File)

    /**
     * Decodes both segments' audio to PCM, cross-fades them sample-by-sample
     * (outgoing gain 1→0, incoming gain 0→1, eased), and re-encodes AAC into a
     * packet file (so it can be muxed after the video track is known).
     */
    private fun preEncodeCrossfadeAudio(
        outgoingPath: String, outStartUs: Long, outEndUs: Long,
        incomingPath: String, inStartUs: Long, inEndUs: Long,
        curve: String, workDir: File,
    ): AudioPreEncoded? {
        val outPcm = decodePcm(outgoingPath, outStartUs, outEndUs) ?: return null
        val inPcm = decodePcm(incomingPath, inStartUs, inEndUs) ?: return null
        if (outPcm.sampleRate != inPcm.sampleRate || outPcm.channelCount != inPcm.channelCount) {
            Log.w(RENDER_TAG, "Transition audio format mismatch; skipping crossfade")
            return null
        }

        val sampleRate = outPcm.sampleRate
        val channelCount = outPcm.channelCount
        val frameSize = channelCount * 2
        val totalFrames = max(outPcm.pcm.size, inPcm.pcm.size) / frameSize
        if (totalFrames <= 0) return null

        // Mix into a single PCM buffer with an eased gain ramp.
        val mixed = ByteArray(totalFrames * frameSize)
        for (f in 0 until totalFrames) {
            val p = applyEasing(
                if (totalFrames > 1) f.toDouble() / (totalFrames - 1) else 1.0,
                curve
            )
            val gOut = (1.0 - p)
            val gIn = p
            for (c in 0 until channelCount) {
                val idx = (f * channelCount + c) * 2
                val aSample = readSample(outPcm.pcm, idx)
                val bSample = readSample(inPcm.pcm, idx)
                val mixedSample = (aSample * gOut + bSample * gIn)
                    .roundToInt().coerceIn(-32768, 32767)
                mixed[idx] = (mixedSample and 0xFF).toByte()
                mixed[idx + 1] = ((mixedSample shr 8) and 0xFF).toByte()
            }
        }

        return encodeAac(mixed, sampleRate, channelCount, workDir)
    }

    private fun readSample(pcm: ByteArray, idx: Int): Int {
        if (idx + 1 >= pcm.size) return 0
        val lo = pcm[idx].toInt() and 0xFF
        val hi = pcm[idx + 1].toInt()
        return (hi shl 8) or lo
    }

    private class DecodedPcm(val pcm: ByteArray, val sampleRate: Int, val channelCount: Int)

    private fun decodePcm(path: String, startUs: Long, endUs: Long): DecodedPcm? {
        val extractor = MediaExtractor().apply { setDataSource(path) }
        val trackIndex = findTrack(extractor, "audio/") ?: run {
            extractor.release(); return null
        }
        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: run {
            extractor.release(); return null
        }
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()

        val out = java.io.ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIdx = decoder.dequeueInputBuffer(DECODER_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val t = extractor.sampleTime
                        if (t < 0 || t >= endUs) {
                            decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val buf = decoder.getInputBuffer(inIdx)!!
                            buf.clear()
                            val size = extractor.readSampleData(buf, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(inIdx, 0, size, t, 0)
                                extractor.advance()
                            }
                        }
                    }
                }
                val outIdx = decoder.dequeueOutputBuffer(info, DECODER_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                    outIdx >= 0 -> {
                        if (info.size > 0 && info.presentationTimeUs in startUs until endUs) {
                            val buf = decoder.getOutputBuffer(outIdx)!!
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            val tmp = ByteArray(info.size)
                            buf.get(tmp)
                            out.write(tmp)
                        }
                        decoder.releaseOutputBuffer(outIdx, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
                    }
                }
            }
        } finally {
            try { decoder.stop() } catch (_: Exception) {}
            try { decoder.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
        val pcm = out.toByteArray()
        return if (pcm.isEmpty()) null else DecodedPcm(pcm, sampleRate, channelCount)
    }

    private fun encodeAac(
        pcm: ByteArray, sampleRate: Int, channelCount: Int, workDir: File,
    ): AudioPreEncoded? {
        val mime = "audio/mp4a-latm"
        val format = MediaFormat.createAudioFormat(mime, sampleRate, channelCount).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val encoder = MediaCodec.createEncoderByType(mime)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()

        val packetsFile = File(workDir, "transition_audio_packets.bin")
        val packetsOut = DataOutputStream(packetsFile.outputStream().buffered())
        var capturedFormat: MediaFormat? = null
        val info = MediaCodec.BufferInfo()
        val frameSize = channelCount * 2
        val sampleDurationUs = 1_000_000L / sampleRate

        fun drain(eos: Boolean) {
            while (true) {
                val idx = encoder.dequeueOutputBuffer(info, ENCODER_TIMEOUT_US)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!eos) return
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> capturedFormat = encoder.outputFormat
                    idx >= 0 -> {
                        val outBuf = encoder.getOutputBuffer(idx)!!
                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        if (!isConfig && info.size > 0) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            val bytes = ByteArray(info.size)
                            outBuf.get(bytes)
                            packetsOut.writeInt(info.size)
                            packetsOut.writeLong(info.presentationTimeUs)
                            packetsOut.writeInt(info.flags)
                            packetsOut.write(bytes)
                        }
                        encoder.releaseOutputBuffer(idx, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                    }
                }
            }
        }

        try {
            var offset = 0
            var framePos = 0L
            while (offset < pcm.size) {
                val inIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                if (inIdx < 0) { drain(false); continue }
                val buf = encoder.getInputBuffer(inIdx)!!
                buf.clear()
                val toWrite = min(buf.capacity(), pcm.size - offset)
                val aligned = (toWrite / frameSize) * frameSize
                if (aligned == 0) { encoder.queueInputBuffer(inIdx, 0, 0, 0, 0); break }
                buf.put(pcm, offset, aligned)
                encoder.queueInputBuffer(inIdx, 0, aligned, framePos * sampleDurationUs, 0)
                framePos += aligned / frameSize
                offset += aligned
                drain(false)
            }
            while (true) {
                val inIdx = encoder.dequeueInputBuffer(ENCODER_TIMEOUT_US)
                if (inIdx >= 0) {
                    encoder.queueInputBuffer(
                        inIdx, 0, 0, framePos * sampleDurationUs,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                    )
                    break
                }
                drain(false)
            }
            drain(true)
        } finally {
            try { encoder.stop() } catch (_: Exception) {}
            try { encoder.release() } catch (_: Exception) {}
            try { packetsOut.close() } catch (_: Exception) {}
        }

        val fmt = capturedFormat
        if (fmt == null || packetsFile.length() == 0L) {
            packetsFile.delete()
            return null
        }
        return AudioPreEncoded(fmt, packetsFile)
    }

    private fun writeBufferedAudio(muxer: MediaMuxer, audioTrackIndex: Int, packets: File) {
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
            }
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
}
