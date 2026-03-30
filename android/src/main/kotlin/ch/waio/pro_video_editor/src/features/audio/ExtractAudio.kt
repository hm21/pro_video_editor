package ch.waio.pro_video_editor.src.features.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.util.Log
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractConfig
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractJobHandle
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Exception thrown when no audio track is found in the video file.
 */
class NoAudioTrackException(message: String) : Exception(message)

/**
 * Service for extracting audio from video files.
 *
 * This class handles the audio extraction pipeline using Android MediaExtractor and MediaMuxer:
 * - Extracts audio track from video file
 * - Supports trimming (start/end time)
 * - Supports multiple output formats (MP3, AAC, WAV, M4A, OGG)
 * - Provides progress tracking during extraction
 * - Supports cancellation of active extraction jobs
 */
class ExtractAudio(private val context: Context) {

    companion object {
        private const val TAG = "ExtractAudio"
        private const val BUFFER_SIZE = 1024 * 1024 // 1MB buffer
    }

    /**
     * Starts an asynchronous audio extraction job.
     *
     * This method extracts the audio track from a video file and optionally
     * trims it to the specified time range. The operation runs asynchronously
     * and provides callbacks for progress updates, completion, and errors.
     *
     * @param config Complete extraction configuration including input, output, and format
     * @param onProgress Callback invoked with progress updates (0.0 to 1.0)
     * @param onComplete Callback invoked on success with output bytes (null if saved to file)
     * @param onError Callback invoked if extraction fails
     * @return AudioExtractJobHandle that can be used to cancel the extraction job
     */
    fun extract(
        config: AudioExtractConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): AudioExtractJobHandle {
        val shouldStop = AtomicBoolean(false)
        val mainHandler = Handler(Looper.getMainLooper())

        // Determine output file location
        val outputFile = if (config.outputPath != null) {
            File(config.outputPath)
        } else {
            File(
                context.cacheDir,
                "audio_output_${System.currentTimeMillis()}.${config.getExtension()}"
            )
        }

        // Run extraction in background thread
        Thread {
            var extractor: MediaExtractor? = null
            var muxer: MediaMuxer? = null

            try {
                // Initialize extractor
                extractor = MediaExtractor()
                extractor.setDataSource(config.inputPath)

                // Find audio track
                val audioTrackIndex = findAudioTrack(extractor)
                if (audioTrackIndex < 0) {
                    throw NoAudioTrackException("No audio track found in video file")
                }

                extractor.selectTrack(audioTrackIndex)
                val audioFormat = extractor.getTrackFormat(audioTrackIndex)

                // Determine output format based on config
                val outputFormat = determineOutputFormat(config.format)

                // Initialize muxer
                muxer = MediaMuxer(
                    outputFile.absolutePath,
                    outputFormat
                )

                // Add audio track to muxer
                val muxerTrackIndex = muxer.addTrack(audioFormat)
                muxer.start()

                // Calculate duration and seek to start if needed
                val durationUs = audioFormat.getLong(MediaFormat.KEY_DURATION)
                val startUs = config.startUs ?: 0L
                val endUs = config.endUs ?: durationUs

                if (startUs > 0) {
                    extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                }

                // Extract and write audio samples
                val buffer = ByteBuffer.allocate(BUFFER_SIZE)
                val bufferInfo = MediaCodec.BufferInfo()
                var extractedUs = startUs
                val totalDurationUs = endUs - startUs

                mainHandler.post { onProgress(0.0) }

                while (!shouldStop.get()) {
                    val sampleSize = extractor.readSampleData(buffer, 0)

                    if (sampleSize < 0) {
                        // End of stream
                        break
                    }

                    val presentationTimeUs = extractor.sampleTime

                    // Check if we've reached the end time
                    if (presentationTimeUs > endUs) {
                        break
                    }

                    // Adjust presentation time if we're trimming from start
                    bufferInfo.presentationTimeUs = presentationTimeUs - startUs
                    bufferInfo.size = sampleSize
                    bufferInfo.offset = 0

                    // Convert MediaExtractor flags to MediaCodec flags
                    bufferInfo.flags =
                        if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                            MediaCodec.BUFFER_FLAG_KEY_FRAME
                        } else {
                            0
                        }

                    // Write sample to muxer
                    muxer.writeSampleData(muxerTrackIndex, buffer, bufferInfo)

                    // Update progress
                    extractedUs = presentationTimeUs
                    val progress =
                        ((extractedUs - startUs).toDouble() / totalDurationUs).coerceIn(0.0, 1.0)
                    mainHandler.post { onProgress(progress) }

                    // Advance to next sample
                    extractor.advance()
                    buffer.clear()
                }

                // Check if cancelled
                if (shouldStop.get()) {
                    throw InterruptedException("Extraction cancelled by user")
                }

                // Finalize muxer
                muxer.stop()
                muxer.release()
                muxer = null

                extractor.release()
                extractor = null

                // Read output and invoke completion callback
                mainHandler.post {
                    try {
                        if (config.outputPath != null) {
                            // Output saved to file, return null
                            onComplete(null)
                        } else {
                            // Read temporary file and return bytes
                            val resultBytes = outputFile.readBytes()
                            onComplete(resultBytes)
                        }
                    } catch (e: Exception) {
                        onError(e)
                    } finally {
                        if (config.outputPath == null) {
                            outputFile.delete()
                        }
                    }
                }

            } catch (e: Exception) {
                Log.e(TAG, "Error extracting audio: ${e.message}", e)
                mainHandler.post {
                    onError(e)
                }
                // Clean up output file on error
                if (config.outputPath == null && outputFile.exists()) {
                    outputFile.delete()
                }
            } finally {
                // Clean up resources
                try {
                    muxer?.stop()
                    muxer?.release()
                } catch (e: Exception) {
                    Log.w(TAG, "Error releasing muxer: ${e.message}")
                }

                try {
                    extractor?.release()
                } catch (e: Exception) {
                    Log.w(TAG, "Error releasing extractor: ${e.message}")
                }
            }
        }.start()

        // Return cancellation handle
        return AudioExtractJobHandle {
            shouldStop.set(true)
            mainHandler.removeCallbacksAndMessages(null)
            if (config.outputPath == null && outputFile.exists()) {
                outputFile.delete()
            }
        }
    }

    /**
     * Finds the first audio track in the media file.
     *
     * @return Track index if found, -1 otherwise
     */
    private fun findAudioTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                return i
            }
        }
        return -1
    }

    /**
     * Determines the MediaMuxer output format based on the requested audio format.
     *
     * @param format Audio format string (mp3, aac, wav, m4a, ogg)
     * @return MediaMuxer output format constant
     */
    private fun determineOutputFormat(format: String): Int {
        return when (format.lowercase()) {
            "mp3" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "aac" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "m4a" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "wav" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "ogg" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG
            "webm" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
            else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // Default to MP4 container
        }
    }
}
