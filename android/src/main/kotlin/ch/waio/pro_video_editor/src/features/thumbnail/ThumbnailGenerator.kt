package ch.waio.pro_video_editor.src.features.thumbnail

import THUMBNAIL_TAG
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

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
class ThumbnailGenerator(private val context: Context) {

    // Create a dedicated coroutine scope for this service
    // SupervisorJob ensures that failures don't cancel sibling coroutines
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /**
     * Asynchronously generates thumbnails from a video file.
     *
     * This method determines the extraction mode based on the configuration:
     * - If timestampsUs is provided, extracts frames at specified timestamps
     * - If maxOutputFrames is provided, extracts evenly distributed keyframes
     * - Returns empty list if neither is specified
     *
     * All thumbnails are generated in parallel for optimal performance.
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
     * This method uses MediaMetadataRetriever with OPTION_CLOSEST to find the nearest
     * frame to each specified timestamp. All frames are processed in parallel using
     * coroutines for maximum throughput.
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
                        retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (bitmap != null) {
                        val resized =
                            resizeBitmapKeepingAspect(bitmap, outputWidth, outputHeight, boxFit)
                        val bytes = compressBitmap(resized, outputFormat, jpegQuality)
                        thumbnails[index] = bytes
                        val duration = System.currentTimeMillis() - startTime
                        Log.d(
                            THUMBNAIL_TAG,
                            "✅ [$index]  Generated in $duration ms (${bytes.size} bytes)"
                        )
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
                        retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (bitmap != null) {
                        val resized =
                            resizeBitmapKeepingAspect(bitmap, outputWidth, outputHeight, boxFit)
                        val bytes = compressBitmap(resized, outputFormat, jpegQuality)
                        thumbnails[index] = bytes
                        val duration = System.currentTimeMillis() - startTime
                        Log.d(
                            THUMBNAIL_TAG,
                            "[$index] ✅ ${timeUs / 1000} ms in $duration ms (${bytes.size} bytes)"
                        )
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

        return Bitmap.createScaledBitmap(original, resizedWidth, resizedHeight, true)
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
