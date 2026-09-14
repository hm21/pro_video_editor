package ch.waio.pro_video_editor.src.features.thumbnail

import THUMBNAIL_TAG
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.frame.FrameExtractor
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailConfig
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailJobHandle
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import androidx.core.graphics.scale

/**
 * Service for generating video thumbnail images.
 *
 * This class provides functionality to extract frames from video files and convert
 * them into compressed image thumbnails. It supports two extraction modes:
 * - Timestamp-based: Extract frames at specific time positions
 * - Keyframe-based: Extract evenly distributed keyframes (I-frames)
 *
 * All operations are performed asynchronously with progress reporting.
 */
@UnstableApi
class ThumbnailGenerator(private val context: Context) {

    // Create a dedicated coroutine scope for this service
    // SupervisorJob ensures that failures don't cancel sibling coroutines
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private companion object {
        /** Upper bound of concurrent hardware decoder sessions. */
        const val MAX_PARALLEL_DECODERS = 3
    }

    /**
     * Asynchronously generates thumbnails from a video file.
     *
     * This method determines the extraction mode based on the configuration:
     * - If timestampsUs is provided, extracts frames at specified timestamps
     *   with a single reused hardware decoder session
     * - If maxOutputFrames is provided, extracts evenly distributed keyframes
     *   in parallel
     * - Returns empty list if neither is specified
     *
     * @param config Configuration specifying extraction mode, dimensions, and format
     * @param onProgress Callback invoked with progress updates (0.0 to 1.0)
     * @param onComplete Callback invoked with list of compressed image bytes on success
     * @param onError Callback invoked with exception if generation fails
     */
    fun getThumbnails(
        config: ThumbnailConfig,
        onProgress: (Double) -> Unit,
        onComplete: (List<ByteArray>) -> Unit,
        onError: (Exception) -> Unit
    ) {
        scope.launch {
            try {
                val result = when {
                    config.timestampsUs.isNotEmpty() -> {
                        // Collected in request order; a timestamp no strategy
                        // could decode leaves its slot empty and is dropped
                        // from the returned list.
                        val frames = arrayOfNulls<ByteArray>(config.timestampsUs.size)
                        extractTimestamps(config, isCancelled = { false }) { indices, bytes, progress ->
                            indices.forEach { frames[it] = bytes }
                            onProgress(progress)
                        }
                        frames.filterNotNull()
                    }

                    config.maxOutputFrames != null -> {
                        getKeyFrames(
                            config.inputPath,
                            config.outputFormat,
                            config.jpegQuality,
                            config.boxFit,
                            config.outputWidth,
                            config.outputHeight,
                            config.maxOutputFrames,
                            onProgress
                        )
                    }

                    else -> emptyList()
                }
                onComplete(result)
            } catch (e: Exception) {
                onError(e)
            }
        }
    }

    /**
     * Streams thumbnails for every timestamp in [config] as they are decoded.
     *
     * Unlike [getThumbnails], which hands over the whole set once the last
     * frame is compressed, [onFrame] is invoked on the decoding thread for
     * each frame the moment it is ready — with the indices into
     * [ThumbnailConfig.timestampsUs] that resolve to it (several requested
     * timestamps can map to the same frame), the compressed bytes, and the
     * overall progress (0.0 to 1.0). Delivery order follows decode order, not
     * request order.
     *
     * [onComplete] fires once every timestamp has been attempted; [onError]
     * fires instead when extraction fails or the job is cancelled through the
     * returned handle (with a [CancellationException]).
     *
     * @throws IllegalArgumentException via [onError] when [config] carries no
     *   timestamps — the keyframe mode is not streamable.
     */
    fun streamThumbnails(
        config: ThumbnailConfig,
        onFrame: (indices: List<Int>, bytes: ByteArray, progress: Double) -> Unit,
        onComplete: () -> Unit,
        onError: (Exception) -> Unit,
    ): ThumbnailJobHandle {
        val cancelled = AtomicBoolean(false)
        val job = scope.launch {
            try {
                require(config.timestampsUs.isNotEmpty()) {
                    "Streaming thumbnails need at least one timestamp"
                }
                extractTimestamps(config, isCancelled = { cancelled.get() }, onFrame)
                if (cancelled.get()) {
                    throw CancellationException("Thumbnail task was canceled")
                }
                onComplete()
            } catch (e: Exception) {
                onError(e)
            }
        }
        return ThumbnailJobHandle {
            cancelled.set(true)
            job.cancel()
        }
    }

    /**
     * Extracts frames from video at every timestamp in [config], delivering
     * each one through [onFrame] as soon as it is compressed.
     *
     * Tries the fastest strategy first and falls back on failure — but only
     * for the timestamps that have not been delivered yet, so a strategy that
     * fails halfway never re-decodes (or re-delivers) the frames it already
     * produced:
     * 1. [extractFramesSinglePass]: hardware decoders decode forward through
     *    the stream once, collecting all requested frames (API 29+).
     * 2. [extractFramesWithFrameExtractor]: Media3 FrameExtractor with one
     *    reused hardware decoder session, one exact seek per frame. Also
     *    covers HDR input via GL tone-mapping.
     * 3. [extractFramesLegacy]: MediaMetadataRetriever.
     *
     * [isCancelled] is polled between frames by every strategy; a true result
     * ends extraction with a [CancellationException].
     *
     * [onFrame] receives the indices into [ThumbnailConfig.timestampsUs] that
     * resolve to the frame, the compressed bytes, and the overall progress.
     * It is invoked on a decoding thread.
     */
    private suspend fun extractTimestamps(
        config: ThumbnailConfig,
        isCancelled: () -> Boolean,
        onFrame: (indices: List<Int>, bytes: ByteArray, progress: Double) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val total = config.timestampsUs.size
        val delivered = BooleanArray(total)
        var completed = 0
        // A cancelled coroutine must stop the blocking decode loops too.
        val cancelled = { isCancelled() || !isActive }
        // Counting and delivering happen under one lock so the progress a
        // listener sees never runs backwards: parallel decoder sessions would
        // otherwise hand over frame N+1 before frame N.
        val deliver: (List<Int>, ByteArray) -> Unit = { indices, bytes ->
            synchronized(delivered) {
                indices.forEach { delivered[it] = true }
                completed += indices.size
                onFrame(indices, bytes, completed.toDouble() / total)
            }
        }

        try {
            extractFramesSinglePass(config, config.timestampsUs.indices.toList(), cancelled, deliver)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(
                THUMBNAIL_TAG,
                "Single-pass decoder failed (${e.message}), trying FrameExtractor"
            )
        }
        var remaining = undeliveredIndices(delivered)
        if (remaining.isEmpty()) return@withContext
        throwIfCancelled(cancelled)
        try {
            extractFramesWithFrameExtractor(config, remaining, cancelled, deliver)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(
                THUMBNAIL_TAG,
                "FrameExtractor failed (${e.message}), falling back to MediaMetadataRetriever"
            )
        }
        remaining = undeliveredIndices(delivered)
        if (remaining.isEmpty()) return@withContext
        throwIfCancelled(cancelled)
        extractFramesLegacy(config, remaining, cancelled, deliver)
    }

    private fun undeliveredIndices(delivered: BooleanArray): List<Int> =
        synchronized(delivered) { delivered.indices.filter { !delivered[it] } }

    private fun throwIfCancelled(isCancelled: () -> Boolean) {
        if (isCancelled()) throw CancellationException("Thumbnail task was canceled")
    }

    /**
     * Extracts the timestamps at [targetIndices] in forward decode passes with
     * hardware decoders via [SequentialFrameDecoder].
     *
     * The time-sorted targets are split into up to
     * [ThumbnailConfig.maxParallelDecoders] (default [MAX_PARALLEL_DECODERS])
     * contiguous chunks, each decoded by its own hardware session in
     * parallel: contiguous ranges keep every session decoding forward
     * without GOP re-decodes, while parallel sessions overlap decode work
     * (important for dense 60 fps / 4K sources). The decoder delivers
     * bitmaps already at the final thumbnail size, so no CPU resize is
     * needed here.
     *
     * @throws Exception when the video cannot be decoded this way, so the
     *   caller can fall back to another strategy.
     */
    private suspend fun extractFramesSinglePass(
        config: ThumbnailConfig,
        targetIndices: List<Int>,
        isCancelled: () -> Boolean,
        onFrame: (indices: List<Int>, bytes: ByteArray) -> Unit,
    ) = coroutineScope {
        val timestampsUs = config.timestampsUs
        val scan = SequentialFrameDecoder.scan(config.inputPath)
        val sortedIndices = targetIndices.sortedBy { timestampsUs[it] }

        // Group the time-sorted targets by the GOP their decode starts in.
        // Chunks are split only at GOP boundaries so no two decoder sessions
        // ever decode the same frames.
        val gopGroups = mutableListOf<MutableList<Int>>()
        var lastSync = Long.MIN_VALUE
        for (index in sortedIndices) {
            val sync = scan.syncBefore(scan.closestPts(timestampsUs[index]))
            if (gopGroups.isEmpty() || sync != lastSync) {
                gopGroups.add(mutableListOf())
                lastSync = sync
            }
            gopGroups.last().add(index)
        }

        val chunkCount = minOf(
            config.maxParallelDecoders ?: MAX_PARALLEL_DECODERS,
            gopGroups.size,
            maxOf(1, (sortedIndices.size + 2) / 3),
        )
        val chunks = partitionByDecodeCost(gopGroups, chunkCount, scan, timestampsUs)
        val decodedAny = AtomicBoolean(false)

        val jobs = chunks.map { chunkIndices ->
            async(Dispatchers.IO) {
                val chunkTimestamps = chunkIndices.map { timestampsUs[it] }
                SequentialFrameDecoder(config.inputPath).decode(
                    chunkTimestamps,
                    config.outputWidth,
                    config.outputHeight,
                    config.boxFit,
                    scan,
                    // A failing sibling chunk cancels this one through the
                    // enclosing scope; the decode loop only notices via this
                    // poll.
                    isCancelled = { isCancelled() || !isActive },
                ) { localIndices, bitmap ->
                    val bytes = try {
                        compressBitmap(bitmap, config.outputFormat, config.jpegQuality)
                    } finally {
                        bitmap.recycle()
                    }
                    val indices = localIndices.map { chunkIndices[it] }
                    Log.d(THUMBNAIL_TAG, "✅ $indices Generated (${bytes.size} bytes)")
                    decodedAny.set(true)
                    onFrame(indices, bytes)
                }
            }
        }
        jobs.awaitAll()

        check(decodedAny.get() || targetIndices.isEmpty()) { "No frames could be decoded" }
    }

    /**
     * Splits [gopGroups] (time-ordered target indices grouped per GOP) into
     * [chunkCount] contiguous chunks minimizing the largest per-chunk decode
     * cost, i.e. the frames decoded from the chunk's first GOP sync sample
     * to its last target. Brute-force is fine for at most three chunks.
     */
    private fun partitionByDecodeCost(
        gopGroups: List<List<Int>>,
        chunkCount: Int,
        scan: SequentialFrameDecoder.MediaScan,
        timestampsUs: List<Long>,
    ): List<List<Int>> {
        fun cost(fromGroup: Int, toGroup: Int): Int {
            val firstPts = scan.closestPts(timestampsUs[gopGroups[fromGroup].first()])
            val lastPts = scan.closestPts(timestampsUs[gopGroups[toGroup].last()])
            return scan.frameCount(scan.syncBefore(firstPts), lastPts)
        }

        val count = gopGroups.size
        var bestSplits = emptyList<Int>()
        var bestMax = Int.MAX_VALUE
        when {
            chunkCount <= 1 -> Unit
            chunkCount == 2 -> for (s in 1 until count) {
                val c = maxOf(cost(0, s - 1), cost(s, count - 1))
                if (c < bestMax) {
                    bestMax = c
                    bestSplits = listOf(s)
                }
            }

            else -> for (s1 in 1 until count) {
                for (s2 in s1 + 1 until count) {
                    val c = maxOf(cost(0, s1 - 1), cost(s1, s2 - 1), cost(s2, count - 1))
                    if (c < bestMax) {
                        bestMax = c
                        bestSplits = listOf(s1, s2)
                    }
                }
            }
        }

        val bounds = listOf(0) + bestSplits + listOf(count)
        return (0 until bounds.size - 1).map { chunk ->
            (bounds[chunk] until bounds[chunk + 1]).flatMap { gopGroups[it] }
        }
    }

    /**
     * Extraction of the timestamps at [targetIndices] with Media3's
     * [FrameExtractor]: one reused hardware decoder session, one exact seek
     * per frame. Timestamps are processed in ascending order.
     *
     * @throws CancellationException when [isCancelled] reports true between
     *   frames.
     * @throws Exception when no frame could be extracted at all, so the
     *   caller can retry with the legacy path.
     */
    private fun extractFramesWithFrameExtractor(
        config: ThumbnailConfig,
        targetIndices: List<Int>,
        isCancelled: () -> Boolean,
        onFrame: (indices: List<Int>, bytes: ByteArray) -> Unit,
    ) {
        val timestampsUs = config.timestampsUs
        val mediaItem = MediaItem.fromUri(Uri.fromFile(File(config.inputPath)))
        val sortedIndices = targetIndices.sortedBy { timestampsUs[it] }

        val extractor = FrameExtractor.Builder(context, mediaItem).build()
        try {
            var failures = 0
            for (index in sortedIndices) {
                throwIfCancelled(isCancelled)
                val timeUs = timestampsUs[index]
                val startTime = System.currentTimeMillis()
                try {
                    val frame = extractor
                        .getFrame((timeUs + 500) / 1000)
                        .get(30, TimeUnit.SECONDS)
                    val bitmap = frame.bitmap
                    val resized = resizeBitmapKeepingAspect(
                        bitmap, config.outputWidth, config.outputHeight, config.boxFit
                    )
                    val bytes = try {
                        compressBitmap(resized, config.outputFormat, config.jpegQuality)
                    } finally {
                        if (resized !== bitmap) bitmap.recycle()
                        resized.recycle()
                    }
                    val duration = System.currentTimeMillis() - startTime
                    Log.d(
                        THUMBNAIL_TAG,
                        "✅ [$index]  Generated in $duration ms (${bytes.size} bytes)"
                    )
                    onFrame(listOf(index), bytes)
                } catch (e: Exception) {
                    failures++
                    Log.w(
                        THUMBNAIL_TAG,
                        "[$index] ❌ Frame failed at ${timeUs / 1000} ms: ${e.message}"
                    )
                }
            }
            if (failures == sortedIndices.size && sortedIndices.isNotEmpty()) {
                throw IllegalStateException("All ${sortedIndices.size} frames failed to extract")
            }
        } finally {
            extractor.close()
        }
    }

    /**
     * Legacy extraction of the timestamps at [targetIndices] via
     * MediaMetadataRetriever.
     *
     * Uses OPTION_CLOSEST to find the nearest frame to each timestamp, one
     * retriever per frame in parallel. Slower than [extractFramesSinglePass]
     * (software decoding, no decoder reuse) but kept as a fallback for videos
     * the Media3 pipeline cannot handle. A frame that fails here is dropped.
     */
    private suspend fun extractFramesLegacy(
        config: ThumbnailConfig,
        targetIndices: List<Int>,
        isCancelled: () -> Boolean,
        onFrame: (indices: List<Int>, bytes: ByteArray) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val tempVideoFile = File(config.inputPath)

        // Process all timestamps in parallel
        val jobs = targetIndices.map { index ->
            async {
                if (isCancelled()) return@async
                val timeUs = config.timestampsUs[index]
                val startTime = System.currentTimeMillis()
                var retriever: MediaMetadataRetriever? = null
                try {
                    retriever = MediaMetadataRetriever().apply {
                        setDataSource(tempVideoFile.absolutePath)
                    }

                    // Extract frame at specified timestamp (closest frame)
                    val bitmap =
                        extractFrame(retriever, timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (bitmap != null) {
                        val resized = resizeBitmapKeepingAspect(
                            bitmap, config.outputWidth, config.outputHeight, config.boxFit
                        )
                        val bytes = try {
                            compressBitmap(resized, config.outputFormat, config.jpegQuality)
                        } finally {
                            if (resized !== bitmap) bitmap.recycle()
                            resized.recycle()
                        }
                        val duration = System.currentTimeMillis() - startTime
                        Log.d(
                            THUMBNAIL_TAG,
                            "✅ [$index]  Generated in $duration ms (${bytes.size} bytes)"
                        )
                        onFrame(listOf(index), bytes)
                    } else {
                        Log.w(THUMBNAIL_TAG, "[$index] ❌ Null frame at ${timeUs / 1000} ms")
                    }
                } catch (e: Exception) {
                    Log.e(
                        THUMBNAIL_TAG,
                        "[$index] ❌ Exception at ${timeUs / 1000} ms: ${e.message}"
                    )
                } finally {
                    retriever?.release()
                }
            }
        }

        jobs.awaitAll()
        throwIfCancelled(isCancelled)
    }

    /**
     * Extracts evenly distributed keyframes from video.
     *
     * This method first scans the entire video to identify all keyframes (I-frames),
     * then selects an evenly distributed subset up to maxOutputFrames. Using keyframes
     * ensures fast and accurate frame extraction with OPTION_CLOSEST_SYNC.
     *
     * @param inputPath Absolute path to the video file
     * @param outputFormat Image format (jpeg, png, webp)
     * @param boxFit Scaling mode (contain or cover)
     * @param outputWidth Target thumbnail width in pixels
     * @param outputHeight Target thumbnail height in pixels
     * @param maxOutputFrames Maximum number of thumbnails to generate
     * @param onProgress Callback for progress updates
     * @return List of compressed image bytes, one per extracted keyframe
     */
    private suspend fun getKeyFrames(
        inputPath: String,
        outputFormat: String,
        jpegQuality: Int,
        boxFit: String,
        outputWidth: Int,
        outputHeight: Int,
        maxOutputFrames: Int = 10,
        onProgress: (Double) -> Unit,
    ): List<ByteArray> = withContext(Dispatchers.IO) {
        val tempVideoFile = File(inputPath)

        // First, identify all keyframes in the video
        val keyframeTimestamps =
            extractKeyframeTimestamps(tempVideoFile.absolutePath, maxOutputFrames)
        val thumbnails = MutableList<ByteArray?>(keyframeTimestamps.size) { null }
        val completed = AtomicInteger(0)

        // Process all keyframes in parallel
        val jobs = keyframeTimestamps.mapIndexed { index, timeUs ->
            async {
                val startTime = System.currentTimeMillis()
                var retriever: MediaMetadataRetriever? = null
                try {
                    retriever = MediaMetadataRetriever().apply {
                        setDataSource(tempVideoFile.absolutePath)
                    }

                    // Extract keyframe (OPTION_CLOSEST_SYNC ensures we get exact keyframe)
                    val bitmap =
                        extractFrame(
                            retriever,
                            timeUs,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                        )
                    if (bitmap != null) {
                        val resized =
                            resizeBitmapKeepingAspect(bitmap, outputWidth, outputHeight, boxFit)
                        try {
                            val bytes = compressBitmap(resized, outputFormat, jpegQuality)
                            thumbnails[index] = bytes
                            val duration = System.currentTimeMillis() - startTime
                            Log.d(
                                THUMBNAIL_TAG,
                                "[$index] ✅ ${timeUs / 1000} ms in $duration ms (${bytes.size} bytes)"
                            )
                        } finally {
                            if (resized !== bitmap) bitmap.recycle()
                            resized.recycle()
                        }
                    } else {
                        Log.w(THUMBNAIL_TAG, "[$index] ❌ Null frame at ${timeUs / 1000} ms")
                    }
                } catch (e: Exception) {
                    Log.e(
                        THUMBNAIL_TAG,
                        "[$index] ❌ Exception at ${timeUs / 1000} ms: ${e.message}"
                    )
                } finally {
                    retriever?.release()
                    val progress = completed.incrementAndGet().toDouble() / keyframeTimestamps.size
                    onProgress(progress)
                }
            }
        }

        jobs.awaitAll()
        thumbnails.filterNotNull()
    }

    /**
     * Extracts timestamps of all keyframes (sync samples) from a video.
     *
     * This method uses MediaExtractor to scan through the video and identify all
     * frames marked with SAMPLE_FLAG_SYNC (I-frames/keyframes). If the total number
     * of keyframes exceeds maxOutputFrames, it returns an evenly distributed subset.
     *
     * @param videoPath Absolute path to the video file
     * @param maxOutputFrames Maximum number of keyframe timestamps to return
     * @return List of keyframe timestamps in microseconds, evenly distributed
     */
    private fun extractKeyframeTimestamps(videoPath: String, maxOutputFrames: Int): List<Long> {
        val extractor = MediaExtractor()
        val allKeyframes = mutableListOf<Long>()

        try {
            extractor.setDataSource(videoPath)

            // Find the video track
            val videoTrackIndex = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("video/") == true
            }
            extractor.selectTrack(videoTrackIndex)

            // Scan through all samples and collect keyframe timestamps
            while (true) {
                val flags = extractor.sampleFlags
                if (flags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    allKeyframes.add(extractor.sampleTime)
                }
                if (!extractor.advance()) break
            }
        } catch (e: Exception) {
            Log.e(THUMBNAIL_TAG, "Error extracting keyframes: ${e.message}")
        } finally {
            extractor.release()
        }

        // If we have fewer keyframes than requested, return them all
        if (allKeyframes.size <= maxOutputFrames) return allKeyframes

        // Sample evenly spaced keyframes across the video duration
        val step = allKeyframes.size.toFloat() / maxOutputFrames
        return List(maxOutputFrames) { i ->
            allKeyframes[(i * step).toInt()]
        }
    }

    /**
     * Extracts a frame at [timeUs], falling back through alternative seek
     * options when the preferred [primaryOption] returns null.
     *
     * Some devices return a null frame for 10-bit HDR HEVC at non-sync
     * timestamps with OPTION_CLOSEST, so we retry at the nearest sync frames
     * before giving up. Any frame is normalized to a software ARGB_8888 bitmap
     * so the downstream resize/compress path can read its pixels.
     */
    private fun extractFrame(
        retriever: MediaMetadataRetriever,
        timeUs: Long,
        primaryOption: Int,
    ): Bitmap? {
        val options = linkedSetOf(
            primaryOption,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            MediaMetadataRetriever.OPTION_PREVIOUS_SYNC,
            MediaMetadataRetriever.OPTION_NEXT_SYNC,
        )
        for (option in options) {
            val frame = try {
                retriever.getFrameAtTime(timeUs, option)
            } catch (e: Exception) {
                null
            }
            if (frame != null) return normalizeBitmap(frame)
        }
        // Last resort: a representative frame near the start of the video.
        return try {
            retriever.getFrameAtTime()?.let { normalizeBitmap(it) }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Converts a frame to a software ARGB_8888 bitmap when needed (e.g. HDR
     * frames decoded as RGBA_1010102 or hardware bitmaps can't be read
     * directly by the resize/compress path).
     */
    private fun normalizeBitmap(bitmap: Bitmap): Bitmap {
        if (bitmap.config == Bitmap.Config.ARGB_8888) return bitmap
        val converted = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return bitmap
        if (converted !== bitmap) bitmap.recycle()
        return converted
    }

    /**
     * Resizes a bitmap while maintaining aspect ratio.
     *
     * This method supports two scaling modes:
     * - "contain": Scales the image to fit entirely within target dimensions
     * - "cover": Scales the image to completely fill target dimensions
     *
     * @param original Source bitmap to resize
     * @param targetWidth Target width in pixels
     * @param targetHeight Target height in pixels
     * @param scaleType Scaling mode: "contain" or "cover"
     * @return Resized bitmap maintaining original aspect ratio
     * @throws IllegalArgumentException if scaleType is invalid
     */
    private fun resizeBitmapKeepingAspect(
        original: Bitmap,
        targetWidth: Int,
        targetHeight: Int,
        scaleType: String = "contain"
    ): Bitmap {
        val originalWidth = original.width
        val originalHeight = original.height
        val widthRatio = targetWidth.toFloat() / originalWidth
        val heightRatio = targetHeight.toFloat() / originalHeight

        // Calculate scale factor based on mode
        val scale = when (scaleType.lowercase()) {
            "cover" -> maxOf(widthRatio, heightRatio)  // Fill entire area
            "contain" -> minOf(widthRatio, heightRatio)  // Fit within area
            else -> throw IllegalArgumentException("scaleType must be 'cover' or 'contain'")
        }

        val resizedWidth = (originalWidth * scale).toInt()
        val resizedHeight = (originalHeight * scale).toInt()

        return original.scale(resizedWidth, resizedHeight)
    }

    /**
     * Compresses a bitmap to a byte array in the specified format.
     *
     * Supported formats:
     * - "png": Lossless compression, larger file size
     * - "webp": Modern format, good compression
     * - "jpeg" (default): Lossy compression, smallest file size
     *
     * @param bitmap Source bitmap to compress
     * @param format Output format: "png", "webp", or "jpeg"
     * @param jpegQuality JPEG compression quality (0-100). Only affects JPEG format.
     * @return Compressed image as byte array
     */
    private fun compressBitmap(bitmap: Bitmap, format: String, jpegQuality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        val compressFormat = when (format.lowercase()) {
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> Bitmap.CompressFormat.WEBP
            else -> Bitmap.CompressFormat.JPEG
        }
        bitmap.compress(compressFormat, jpegQuality, stream)
        return stream.toByteArray()
    }
}
