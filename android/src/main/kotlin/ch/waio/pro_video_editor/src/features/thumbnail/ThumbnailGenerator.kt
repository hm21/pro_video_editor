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
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit
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
                        getThumbnailsFromTimestamps(
                            config.inputPath,
                            config.outputFormat,
                            config.jpegQuality,
                            config.boxFit,
                            config.outputWidth,
                            config.outputHeight,
                            config.timestampsUs,
                            onProgress
                        )
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
     * Extracts frames from video at specific timestamp positions.
     *
     * Tries the fastest strategy first and falls back on failure:
     * 1. [extractFramesSinglePass]: one hardware decoder decodes forward
     *    through the stream once, collecting all requested frames (API 29+).
     * 2. [extractFramesWithFrameExtractor]: Media3 FrameExtractor with one
     *    reused hardware decoder session, one exact seek per frame. Also
     *    covers HDR input via GL tone-mapping.
     * 3. [getThumbnailsFromTimestampsLegacy]: MediaMetadataRetriever.
     *
     * @param inputPath Absolute path to the video file
     * @param outputFormat Image format (jpeg, png, webp)
     * @param boxFit Scaling mode (contain or cover)
     * @param outputWidth Target thumbnail width in pixels
     * @param outputHeight Target thumbnail height in pixels
     * @param timestampsUs List of timestamps in microseconds where frames should be extracted
     * @param onProgress Callback for progress updates
     * @return List of compressed image bytes, one per successful extraction
     */
    private suspend fun getThumbnailsFromTimestamps(
        inputPath: String,
        outputFormat: String,
        jpegQuality: Int,
        boxFit: String,
        outputWidth: Int,
        outputHeight: Int,
        timestampsUs: List<Long>,
        onProgress: (Double) -> Unit,
    ): List<ByteArray> = withContext(Dispatchers.IO) {
        try {
            return@withContext extractFramesSinglePass(
                inputPath, outputFormat, jpegQuality, boxFit,
                outputWidth, outputHeight, timestampsUs, onProgress
            )
        } catch (e: Exception) {
            Log.w(
                THUMBNAIL_TAG,
                "Single-pass decoder failed (${e.message}), trying FrameExtractor"
            )
        }
        try {
            extractFramesWithFrameExtractor(
                inputPath, outputFormat, jpegQuality, boxFit,
                outputWidth, outputHeight, timestampsUs, onProgress
            )
        } catch (e: Exception) {
            Log.w(
                THUMBNAIL_TAG,
                "FrameExtractor failed (${e.message}), falling back to MediaMetadataRetriever"
            )
            getThumbnailsFromTimestampsLegacy(
                inputPath, outputFormat, jpegQuality, boxFit,
                outputWidth, outputHeight, timestampsUs, onProgress
            )
        }
    }

    /**
     * Extracts all [timestampsUs] in forward decode passes with hardware
     * decoders via [SequentialFrameDecoder].
     *
     * The time-sorted timestamps are split into up to [MAX_PARALLEL_DECODERS]
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
        inputPath: String,
        outputFormat: String,
        jpegQuality: Int,
        boxFit: String,
        outputWidth: Int,
        outputHeight: Int,
        timestampsUs: List<Long>,
        onProgress: (Double) -> Unit,
    ): List<ByteArray> = coroutineScope {
        val thumbnails = MutableList<ByteArray?>(timestampsUs.size) { null }
        val completed = AtomicInteger(0)

        val scan = SequentialFrameDecoder.scan(inputPath)
        val sortedIndices = timestampsUs.indices.sortedBy { timestampsUs[it] }

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
            MAX_PARALLEL_DECODERS,
            gopGroups.size,
            maxOf(1, (timestampsUs.size + 2) / 3),
        )
        val chunks = partitionByDecodeCost(gopGroups, chunkCount, scan, timestampsUs)

        val jobs = chunks.map { chunkIndices ->
            async(Dispatchers.IO) {
                val chunkTimestamps = chunkIndices.map { timestampsUs[it] }
                SequentialFrameDecoder(inputPath).decode(
                    chunkTimestamps, outputWidth, outputHeight, boxFit, scan
                ) { localIndices, bitmap ->
                    try {
                        val bytes = compressBitmap(bitmap, outputFormat, jpegQuality)
                        localIndices.forEach { thumbnails[chunkIndices[it]] = bytes }
                        Log.d(
                            THUMBNAIL_TAG,
                            "✅ ${localIndices.map { chunkIndices[it] }} " +
                                    "Generated (${bytes.size} bytes)"
                        )
                    } finally {
                        bitmap.recycle()
                    }
                    val done = completed.addAndGet(localIndices.size)
                    onProgress(done.toDouble() / timestampsUs.size)
                }
            }
        }
        jobs.awaitAll()

        check(thumbnails.any { it != null } || timestampsUs.isEmpty()) {
            "No frames could be decoded"
        }
        thumbnails.filterNotNull()
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
     * Extraction of all [timestampsUs] with Media3's [FrameExtractor]: one
     * reused hardware decoder session, one exact seek per frame. Timestamps
     * are processed in ascending order while results keep the order of
     * [timestampsUs].
     *
     * @throws Exception when no frame could be extracted at all, so the
     *   caller can retry with the legacy path.
     */
    private fun extractFramesWithFrameExtractor(
        inputPath: String,
        outputFormat: String,
        jpegQuality: Int,
        boxFit: String,
        outputWidth: Int,
        outputHeight: Int,
        timestampsUs: List<Long>,
        onProgress: (Double) -> Unit,
    ): List<ByteArray> {
        val mediaItem = MediaItem.fromUri(Uri.fromFile(File(inputPath)))
        val thumbnails = MutableList<ByteArray?>(timestampsUs.size) { null }
        val sortedIndices = timestampsUs.indices.sortedBy { timestampsUs[it] }

        val extractor = FrameExtractor.Builder(context, mediaItem).build()
        try {
            var failures = 0
            sortedIndices.forEachIndexed { completed, index ->
                val timeUs = timestampsUs[index]
                val startTime = System.currentTimeMillis()
                try {
                    val frame = extractor
                        .getFrame((timeUs + 500) / 1000)
                        .get(30, TimeUnit.SECONDS)
                    val bitmap = frame.bitmap
                    val resized =
                        resizeBitmapKeepingAspect(bitmap, outputWidth, outputHeight, boxFit)
                    try {
                        val bytes = compressBitmap(resized, outputFormat, jpegQuality)
                        thumbnails[index] = bytes
                        val duration = System.currentTimeMillis() - startTime
                        Log.d(
                            THUMBNAIL_TAG,
                            "✅ [$index]  Generated in $duration ms (${bytes.size} bytes)"
                        )
                    } finally {
                        if (resized !== bitmap) bitmap.recycle()
                        resized.recycle()
                    }
                } catch (e: Exception) {
                    failures++
                    Log.w(
                        THUMBNAIL_TAG,
                        "[$index] ❌ Frame failed at ${timeUs / 1000} ms: ${e.message}"
                    )
                }
                onProgress((completed + 1).toDouble() / timestampsUs.size)
            }
            if (failures == timestampsUs.size && timestampsUs.isNotEmpty()) {
                throw IllegalStateException("All ${timestampsUs.size} frames failed to extract")
            }
        } finally {
            extractor.close()
        }
        return thumbnails.filterNotNull()
    }

    /**
     * Legacy timestamp extraction via MediaMetadataRetriever.
     *
     * Uses OPTION_CLOSEST to find the nearest frame to each timestamp, one
     * retriever per frame in parallel. Slower than [extractFramesSinglePass]
     * (software decoding, no decoder reuse) but kept as a fallback for videos
     * the Media3 pipeline cannot handle.
     */
    private suspend fun getThumbnailsFromTimestampsLegacy(
        inputPath: String,
        outputFormat: String,
        jpegQuality: Int,
        boxFit: String,
        outputWidth: Int,
        outputHeight: Int,
        timestampsUs: List<Long>,
        onProgress: (Double) -> Unit,
    ): List<ByteArray> = withContext(Dispatchers.IO) {
        val tempVideoFile = File(inputPath)
        val thumbnails = MutableList<ByteArray?>(timestampsUs.size) { null }
        val completed = AtomicInteger(0)

        // Process all timestamps in parallel
        val jobs = timestampsUs.mapIndexed { index, timeUs ->
            async {
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
                        val resized =
                            resizeBitmapKeepingAspect(bitmap, outputWidth, outputHeight, boxFit)
                        try {
                            val bytes = compressBitmap(resized, outputFormat, jpegQuality)
                            thumbnails[index] = bytes
                            val duration = System.currentTimeMillis() - startTime
                            Log.d(
                                THUMBNAIL_TAG,
                                "✅ [$index]  Generated in $duration ms (${bytes.size} bytes)"
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
                    val progress = completed.incrementAndGet().toDouble() / timestampsUs.size
                    onProgress(progress)
                }
            }
        }

        jobs.awaitAll()
        thumbnails.filterNotNull()
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
