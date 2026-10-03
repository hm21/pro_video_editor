package ch.waio.pro_video_editor.src.features.metadata

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import ch.waio.pro_video_editor.src.features.metadata.models.MetadataConfig
import ch.waio.pro_video_editor.src.shared.media.contentDataSource
import ch.waio.pro_video_editor.src.shared.media.contentMimeType
import ch.waio.pro_video_editor.src.shared.media.isContentUri
import ch.waio.pro_video_editor.src.shared.media.mediaSourceLength
import ch.waio.pro_video_editor.src.shared.media.openMediaInputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.InputStream

/**
 * Service for extracting metadata from video files.
 *
 * This class provides functionality to retrieve comprehensive metadata information
 * from video files, including technical properties (dimensions, duration, bitrate)
 * and descriptive metadata (title, artist, album).
 */
class Metadata(private val context: Context) {

    // Create a dedicated coroutine scope for this service
    // SupervisorJob ensures that failures don't cancel sibling coroutines
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /**
     * Asynchronously retrieves metadata from a video file.
     *
     * This method runs on a background thread and extracts all available metadata
     * from the video file specified in the configuration. The operation is non-blocking
     * and results are delivered via callbacks.
     *
     * @param config Configuration containing the video file path and extraction parameters
     * @param onComplete Callback invoked with extracted metadata map on success
     * @param onError Callback invoked with exception if extraction fails
     */
    fun getMetadata(
        config: MetadataConfig,
        onComplete: (Map<String, Any>) -> Unit,
        onError: (Exception) -> Unit
    ) {
        scope.launch {
            try {
                val result = processVideo(config)
                onComplete(result)
            } catch (e: Exception) {
                onError(e)
            }
        }
    }

    /**
     * Asynchronously checks if a video file has an audio track.
     *
     * This method runs on a background thread and quickly inspects the video
     * to determine if it contains at least one audio track. This is useful to
     * check before attempting audio extraction operations.
     *
     * @param config Configuration containing the video file path
     * @param onComplete Callback invoked with result: true if audio track exists, false otherwise
     * @param onError Callback invoked with exception if check fails
     */
    fun hasAudioTrack(
        config: MetadataConfig,
        onComplete: (Boolean) -> Unit,
        onError: (Exception) -> Unit
    ) {
        scope.launch {
            try {
                val result = checkAudioTrack(config)
                onComplete(result)
            } catch (e: Exception) {
                onError(e)
            }
        }
    }

    /**
     * Internal method that performs the actual metadata extraction.
     *
     * Uses Android's MediaMetadataRetriever to extract both numeric and text-based
     * metadata from the video file. The extraction process is organized into categories:
     * - File properties (file size)
     * - Numeric metadata (duration, dimensions, rotation, bitrate)
     * - Text metadata (title, artist, author, album information)
     *
     * @param config Configuration containing the video file path
     * @return Map containing all extracted metadata with string keys and typed values
     * @throws Exception if the file cannot be accessed or metadata extraction fails
     */
    private fun processVideo(config: MetadataConfig): Map<String, Any> {
        val retriever = MediaMetadataRetriever()

        try {
            retriever.contentDataSource(context, config.inputPath)

            // Initialize metadata map with file size
            val metadata = mutableMapOf<String, Any>(
                "fileSize" to mediaSourceLength(context, config.inputPath)
            )

            // A content URI carries no file extension for Dart to derive the
            // format from, so report the subtype of its MIME type instead
            // (e.g. "mp4", "quicktime"), matching what Dart derives for files.
            if (config.inputPath.isContentUri()) {
                val mimeType = contentMimeType(context, config.inputPath)
                    ?: retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                mimeType?.substringAfter('/', "")?.takeIf { it.isNotEmpty() }?.let {
                    metadata["extension"] = it
                }
            }

            // Extract duration and bitrate
            metadata["duration"] =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toDoubleOrNull() ?: 0.0
            metadata["bitrate"] =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                    ?.toIntOrNull() ?: 0

            // Extract rotation
            val rotation =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull() ?: 0
            metadata["rotation"] = rotation

            // Extract raw dimensions
            val rawWidth =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull() ?: 0
            val rawHeight =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull() ?: 0

            // Apply rotation to get display dimensions (consistent with iOS/macOS)
            // For 90° or 270° rotation, swap width and height
            val isRotated90Or270 = rotation == 90 || rotation == 270
            if (isRotated90Or270) {
                metadata["width"] = rawHeight
                metadata["height"] = rawWidth
            } else {
                metadata["width"] = rawWidth
                metadata["height"] = rawHeight
            }

            // Extract audio track duration if audio track exists
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            if (hasAudio == "yes") {
                // Extract actual audio track duration using MediaExtractor
                val audioDuration = extractAudioDuration(config.inputPath)
                if (audioDuration != null) {
                    metadata["audioDuration"] = audioDuration
                }
            }

            // Define text metadata keys mapping
            // These values are returned as-is (String)
            val textMetadata = mapOf(
                "title" to MediaMetadataRetriever.METADATA_KEY_TITLE,
                "artist" to MediaMetadataRetriever.METADATA_KEY_ARTIST,
                "author" to MediaMetadataRetriever.METADATA_KEY_AUTHOR,
                "album" to MediaMetadataRetriever.METADATA_KEY_ALBUM,
                "albumArtist" to MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
                "date" to MediaMetadataRetriever.METADATA_KEY_DATE
            )

            // Extract text metadata, default to empty string if not present
            textMetadata.forEach { (key, metadataKey) ->
                metadata[key] = retriever.extractMetadata(metadataKey) ?: ""
            }

            // Extract GPS location (format: "+47.3769+008.5417/")
            val locationString =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
            if (locationString != null) {
                val (latitude, longitude) = parseLocationString(locationString)
                if (latitude != null) {
                    metadata["latitude"] = latitude
                }
                if (longitude != null) {
                    metadata["longitude"] = longitude
                }
            }

            // Extract frame rate (capture framerate, available from API 23+)
            val captureFrameRate =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
            if (captureFrameRate != null) {
                val frameRate = captureFrameRate.toDoubleOrNull()
                if (frameRate != null && frameRate > 0) {
                    metadata["frameRate"] = frameRate
                }
            }

            // Camera make and model are not directly available in MediaMetadataRetriever
            // They would need to be extracted from EXIF data, which is typically for images.
            // For videos, these are often stored in proprietary formats.
            // We set empty strings to maintain API consistency across platforms.
            metadata["cameraMake"] = ""
            metadata["cameraModel"] = ""

            // Check if video is optimized for streaming (moov before mdat)
            // Only perform this check if explicitly requested (performance optimization)
            if (config.checkStreamingOptimization) {
                val isOptimizedForStreaming = checkStreamingOptimization(config.inputPath)
                if (isOptimizedForStreaming != null) {
                    metadata["isOptimizedForStreaming"] = isOptimizedForStreaming
                }
            }

            return metadata
        } finally {
            // Always release the retriever to free native resources
            retriever.release()
        }
    }

    /**
     * Internal method that checks if a video file has an audio track.
     *
     * Uses Android's MediaMetadataRetriever to check if the video contains
     * at least one audio track by inspecting the "has-audio" metadata key.
     *
     * @param config Configuration containing the video file path
     * @return true if the video has an audio track, false otherwise
     * @throws Exception if the file cannot be accessed or check fails
     */
    private fun checkAudioTrack(config: MetadataConfig): Boolean {
        val retriever = MediaMetadataRetriever()

        try {
            retriever.contentDataSource(context, config.inputPath)

            // Check if video has audio track
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            return hasAudio == "yes"
        } finally {
            // Always release the retriever to free native resources
            retriever.release()
        }
    }

    /**
     * Parses a GPS location string into latitude and longitude coordinates.
     *
     * The location string format from video metadata is typically:
     * "+47.3769+008.5417/" (ISO 6709 format) or similar variations.
     *
     * @param locationString The raw location string from video metadata
     * @return A Pair containing the parsed latitude and longitude, or null values if parsing fails
     */
    private fun parseLocationString(locationString: String): Pair<Double?, Double?> {
        // Remove trailing slash and whitespace
        val cleaned = locationString.trim().trimEnd('/')

        // Pattern: +/-DD.DDDD+/-DDD.DDDD (ISO 6709 format)
        // First coordinate is latitude, second is longitude
        val signPositions = mutableListOf<Int>()
        for ((index, char) in cleaned.withIndex()) {
            if (char == '+' || char == '-') {
                signPositions.add(index)
            }
        }

        if (signPositions.size >= 2) {
            val latString = cleaned.substring(signPositions[0], signPositions[1])
            val lonString = cleaned.substring(signPositions[1])

            val latitude = latString.toDoubleOrNull()
            val longitude = lonString.toDoubleOrNull()

            return Pair(latitude, longitude)
        }

        return Pair(null, null)
    }

    /**
     * Extracts the actual audio track duration using MediaExtractor.
     *
     * This method provides more accurate audio duration compared to the overall
     * video duration, especially when the audio track is shorter than the video.
     *
     * @param path A path to the video file
     * @return Audio duration in milliseconds, or null if no audio track is found
     */
    private fun extractAudioDuration(path: String): Double? {
        val extractor = MediaExtractor()
        try {
            extractor.contentDataSource(context, path)

            // Find the audio track
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue

                if (mime.startsWith("audio/")) {
                    // Extract duration from audio track format
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        val durationUs = format.getLong(MediaFormat.KEY_DURATION)
                        // Convert microseconds to milliseconds
                        return durationUs / 1000.0
                    }
                }
            }

            return null
        } catch (e: Exception) {
            return null
        } finally {
            extractor.release()
        }
    }

    /**
     * Checks if the video file is optimized for progressive streaming.
     *
     * For MP4/MOV files, this checks if the moov atom appears before the mdat atom.
     * When moov comes first, browsers can start playback before downloading the
     * entire file (progressive streaming / fast start).
     *
     * @param path The video file path or content URI to check
     * @return true if optimized for streaming (moov before mdat), false if not,
     *         null if the format doesn't support this check or an error occurred
     */
    private fun checkStreamingOptimization(path: String): Boolean? {
        // Only check MP4/MOV/M4V files
        if (path.isContentUri()) {
            // An unknown type is scanned anyway; a non-MP4 stream finds neither atom.
            val mimeType = contentMimeType(context, path)?.lowercase()
            if (mimeType != null && mimeType !in STREAMING_CHECK_MIME_TYPES) return null
        } else {
            val extension = File(path).extension.lowercase()
            if (extension !in listOf("mp4", "mov", "m4v", "m4a")) {
                return null
            }
        }

        try {
            return openMediaInputStream(context, path).use { inputStream ->
                val buffer = ByteArray(8)
                var moovPosition: Long = -1
                var mdatPosition: Long = -1
                var position: Long = 0

                while (true) {
                    // Read atom header (4 bytes size + 4 bytes type)
                    if (!inputStream.readFully(buffer)) break

                    // Parse atom size (big-endian)
                    val atomSize = ((buffer[0].toLong() and 0xFF) shl 24) or
                            ((buffer[1].toLong() and 0xFF) shl 16) or
                            ((buffer[2].toLong() and 0xFF) shl 8) or
                            (buffer[3].toLong() and 0xFF)

                    // Parse atom type
                    val atomType = String(buffer, 4, 4, Charsets.US_ASCII)

                    // Track positions of moov and mdat atoms
                    when (atomType) {
                        "moov" -> moovPosition = position
                        "mdat" -> mdatPosition = position
                    }

                    // If we found both, we can determine the result
                    if (moovPosition >= 0 && mdatPosition >= 0) {
                        return moovPosition < mdatPosition
                    }

                    // Handle extended size (atomSize == 1 means 64-bit size follows)
                    val actualSize = if (atomSize == 1L) {
                        // Read 64-bit size
                        val extBuffer = ByteArray(8)
                        if (!inputStream.readFully(extBuffer)) break
                        ((extBuffer[0].toLong() and 0xFF) shl 56) or
                                ((extBuffer[1].toLong() and 0xFF) shl 48) or
                                ((extBuffer[2].toLong() and 0xFF) shl 40) or
                                ((extBuffer[3].toLong() and 0xFF) shl 32) or
                                ((extBuffer[4].toLong() and 0xFF) shl 24) or
                                ((extBuffer[5].toLong() and 0xFF) shl 16) or
                                ((extBuffer[6].toLong() and 0xFF) shl 8) or
                                (extBuffer[7].toLong() and 0xFF)
                    } else if (atomSize == 0L) {
                        // Atom extends to end of file
                        break
                    } else {
                        atomSize
                    }

                    // Skip to next atom
                    val skipBytes = actualSize - 8 - (if (atomSize == 1L) 8 else 0)
                    if (skipBytes > 0 && !inputStream.skipFully(skipBytes)) break
                    position += actualSize
                }

                // If we only found one of them, determine based on what we found
                return when {
                    moovPosition >= 0 && mdatPosition < 0 -> true  // moov found, no mdat yet
                    moovPosition < 0 && mdatPosition >= 0 -> false // mdat found first, no moov
                    else -> null // Neither found or couldn't determine
                }
            }
        } catch (e: Exception) {
            return null
        }
    }

    /**
     * Fills [buffer] completely; false when the stream ends first. A single
     * read() may return fewer bytes on a pipe-backed content stream.
     */
    private fun InputStream.readFully(buffer: ByteArray): Boolean {
        var offset = 0
        while (offset < buffer.size) {
            val read = read(buffer, offset, buffer.size - offset)
            if (read < 0) return false
            offset += read
        }
        return true
    }

    /**
     * Skips exactly [count] bytes; false when the stream ends first. skip()
     * may skip fewer bytes than asked on a pipe-backed content stream.
     */
    private fun InputStream.skipFully(count: Long): Boolean {
        var remaining = count
        while (remaining > 0) {
            val skipped = skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                // skip() made no progress: read one byte to tell EOF apart.
                if (read() < 0) return false
                remaining--
            }
        }
        return true
    }

    private companion object {
        /** Content MIME types of the MP4 family the moov/mdat check applies to. */
        val STREAMING_CHECK_MIME_TYPES = setOf(
            "video/mp4", "video/quicktime", "video/x-m4v", "audio/mp4", "audio/x-m4a"
        )
    }
}
