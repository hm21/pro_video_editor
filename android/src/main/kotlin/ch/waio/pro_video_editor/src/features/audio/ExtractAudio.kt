package ch.waio.pro_video_editor.src.features.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractConfig
import ch.waio.pro_video_editor.src.features.audio.models.AudioExtractJobHandle
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Exception thrown when no audio track is found in the video file.
 */
class NoAudioTrackException(message: String) : Exception(message)

/**
 * Service for extracting audio from video files.
 *
 * This class handles the audio extraction pipeline:
 * - Extracts audio track from video file
 * - Supports trimming (start/end time)
 * - Supports multiple output formats (MP3, AAC, WAV, M4A, OGG)
 * - Provides progress tracking during extraction
 * - Supports cancellation of active extraction jobs
 *
 * For WAV format, uses custom WAV file writer with PCM encoding.
 * For other formats, uses Android MediaExtractor and MediaMuxer.
 *
 * When a playback speed other than 1.0 is requested, compressed formats are
 * re-encoded through a Media3 [Transformer] (with [SonicAudioProcessor] for a
 * pitch-preserving time-stretch), while WAV applies the speed change directly
 * on the decoded PCM in [WavFileWriter].
 */
@UnstableApi
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
        val applySpeed = config.speed > 0f && config.speed != 1.0f
        return when {
            // WAV applies the speed change on the decoded PCM (see WavFileWriter).
            config.format.lowercase() == "wav" ->
                extractToWav(config, onProgress, onComplete, onError)
            // Compressed formats can't be re-timed by copying samples, so a
            // speed change requires re-encoding through Media3 Transformer.
            applySpeed ->
                extractWithSpeed(config, onProgress, onComplete, onError)
            // Fast path: copy the compressed audio samples unchanged.
            else ->
                extractWithMuxer(config, onProgress, onComplete, onError)
        }
    }

    /**
     * Extracts audio to WAV format using custom WAV file writer.
     *
     * This method properly handles both compressed and PCM audio formats:
     * - Compressed formats (AAC, MP3): Uses MediaCodec to decode to PCM
     * - PCM formats: Writes directly to WAV file
     */
    private fun extractToWav(
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
                "audio_output_${System.currentTimeMillis()}.wav"
            )
        }

        // Run extraction in background thread
        Thread {
            var extractor: MediaExtractor? = null
            var wavWriter: WavFileWriter? = null

            try {
                // Initialize extractor
                extractor = MediaExtractor()
                extractor.setDataSource(config.inputPath)

                // Find audio track
                val audioTrackIndex = findAudioTrack(extractor)
                if (audioTrackIndex < 0) {
                    throw NoAudioTrackException("No audio track found in video file")
                }

                val audioFormat = extractor.getTrackFormat(audioTrackIndex)

                // Get the audio track's actual time range
                // Audio tracks may not start at timestamp 0 due to encoder delays
                val durationUs = audioFormat.getLong(MediaFormat.KEY_DURATION)
                
                // Determine the actual start and end timestamps for extraction
                val actualStartUs: Long
                val actualEndUs: Long
                
                if (config.startUs != null || config.endUs != null) {
                    // User specified trim parameters - use them as-is
                    actualStartUs = config.startUs ?: 0L
                    actualEndUs = config.endUs ?: (actualStartUs + durationUs)
                } else {
                    // Full extraction - need to detect the audio track's actual start time
                    // Use a temporary extractor to avoid track selection conflicts!
                    // WavFileWriter will call selectTrack() on the main extractor, 
                    // so we must not pre-select it here
                    var tempExtractor: MediaExtractor? = null
                    try {
                        tempExtractor = MediaExtractor()
                        tempExtractor.setDataSource(config.inputPath)
                        tempExtractor.selectTrack(audioTrackIndex)
                        val firstSampleTimeUs = tempExtractor.sampleTime
                        
                        if (firstSampleTimeUs > 0) {
                            // Audio track has an offset (e.g., AAC encoder delay)
                            actualStartUs = firstSampleTimeUs
                            actualEndUs = firstSampleTimeUs + durationUs
                        } else {
                            // Audio track starts at or near zero
                            actualStartUs = 0L
                            actualEndUs = durationUs
                        }
                    } finally {
                        tempExtractor?.release()
                    }
                }

                // Validate end time
                if (actualEndUs <= actualStartUs) {
                    throw IllegalArgumentException("endUs must be greater than startUs")
                }

                // Create WAV writer (handles both compressed and PCM audio,
                // and applies a pitch-preserving speed change when requested)
                wavWriter = WavFileWriter(outputFile, config.speed)

                mainHandler.post { onProgress(0.0) }
                
                wavWriter.extractAndWrite(
                    extractor = extractor,
                    audioTrackIndex = audioTrackIndex,
                    startUs = actualStartUs,
                    endUs = actualEndUs,
                    onProgress = { progress ->
                        if (!shouldStop.get()) {
                            mainHandler.post { onProgress(progress) }
                        }
                    },
                    shouldStop = { shouldStop.get() }
                )

                // Check if cancelled
                if (shouldStop.get()) {
                    outputFile.delete()
                    throw InterruptedException("Extraction cancelled by user")
                }

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
                Log.e(TAG, "Error extracting WAV audio: ${e.message}", e)
                mainHandler.post {
                    onError(e)
                }
                // Clean up output file on error
                if (outputFile.exists()) {
                    outputFile.delete()
                }
            } finally {
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
            // File cleanup is handled by the background thread once it detects shouldStop
        }
    }

    /**
     * Extracts audio using MediaMuxer for non-WAV formats.
     */
    private fun extractWithMuxer(
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

                // Get the audio track's actual time range
                // Audio tracks may not start at timestamp 0 due to encoder delays
                val durationUs = audioFormat.getLong(MediaFormat.KEY_DURATION)
                
                // Determine the actual start and end timestamps for extraction
                val actualStartUs: Long
                val actualEndUs: Long
                
                if (config.startUs != null || config.endUs != null) {
                    // User specified trim parameters - use them as-is
                    actualStartUs = config.startUs ?: 0L
                    actualEndUs = config.endUs ?: (actualStartUs + durationUs)
                } else {
                    // Full extraction - need to detect the audio track's actual start time
                    // Read the first sample to get the actual start timestamp
                    val firstSampleTimeUs = extractor.sampleTime
                    
                    if (firstSampleTimeUs > 0) {
                        // Audio track has an offset (e.g., AAC encoder delay)
                        actualStartUs = firstSampleTimeUs
                        actualEndUs = firstSampleTimeUs + durationUs
                    } else {
                        // Audio track starts at or near zero
                        actualStartUs = 0L
                        actualEndUs = durationUs
                    }
                }

                if (actualStartUs > 0) {
                    extractor.seekTo(actualStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                }

                // Extract and write audio samples
                val buffer = ByteBuffer.allocate(BUFFER_SIZE)
                val bufferInfo = MediaCodec.BufferInfo()
                var extractedUs = actualStartUs
                val totalDurationUs = actualEndUs - actualStartUs

                mainHandler.post { onProgress(0.0) }

                while (!shouldStop.get()) {
                    val sampleSize = extractor.readSampleData(buffer, 0)

                    if (sampleSize < 0) {
                        // End of stream
                        break
                    }

                    val presentationTimeUs = extractor.sampleTime

                    // Check if we've reached the end time
                    if (presentationTimeUs > actualEndUs) {
                        break
                    }

                    // Adjust presentation time to start at zero in the output
                    // This ensures extracted audio always has timestamps starting at 0
                    bufferInfo.presentationTimeUs = presentationTimeUs - actualStartUs
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
                    val progress = ((extractedUs - actualStartUs).toDouble() / totalDurationUs).coerceIn(0.0, 1.0)
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
            // File cleanup is handled by the background thread once it detects shouldStop
        }
    }

    /**
     * Extracts audio while applying a pitch-preserving playback speed change.
     *
     * Compressed output formats (AAC/M4A/MP3) can't be re-timed by simply
     * copying samples, so the audio is re-encoded with a Media3 [Transformer].
     * A [SonicAudioProcessor] performs the time-stretch and the result is muxed
     * into an MP4/M4A container (matching the muxer path's output container).
     */
    private fun extractWithSpeed(
        config: AudioExtractConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): AudioExtractJobHandle {
        val mainHandler = Handler(Looper.getMainLooper())
        val shouldStopPolling = AtomicBoolean(false)
        val canceled = AtomicBoolean(false)
        val transformerRef = AtomicReference<Transformer?>(null)

        val outputFile = if (config.outputPath != null) {
            File(config.outputPath)
        } else {
            File(
                context.cacheDir,
                "audio_output_${System.currentTimeMillis()}.${config.getExtension()}"
            )
        }

        fun cleanupOnFailure() {
            if (config.outputPath == null && outputFile.exists()) {
                outputFile.delete()
            }
        }

        // Run the audio-track pre-check off the main thread, then start the
        // Transformer (which must run on a thread with a Looper) on the main
        // thread, mirroring the render pipeline.
        Thread {
            var probe: MediaExtractor? = null
            val hasAudio: Boolean
            try {
                probe = MediaExtractor()
                probe.setDataSource(config.inputPath)
                hasAudio = findAudioTrack(probe) >= 0
            } catch (e: Exception) {
                mainHandler.post { onError(e) }
                return@Thread
            } finally {
                try {
                    probe?.release()
                } catch (e: Exception) {
                    Log.w(TAG, "Error releasing probe extractor: ${e.message}")
                }
            }

            if (!hasAudio) {
                mainHandler.post {
                    onError(NoAudioTrackException("No audio track found in video file"))
                }
                return@Thread
            }

            mainHandler.post {
                if (canceled.get()) return@post
                try {
                    val mediaItemBuilder = MediaItem.Builder()
                        .setUri(Uri.fromFile(File(config.inputPath)))

                    if (config.startUs != null || config.endUs != null) {
                        val clipping = MediaItem.ClippingConfiguration.Builder().apply {
                            config.startUs?.let { setStartPositionUs(it) }
                            config.endUs?.let { setEndPositionUs(it) }
                        }.build()
                        mediaItemBuilder.setClippingConfiguration(clipping)
                    }

                    val sonic = SonicAudioProcessor().apply { setSpeed(config.speed) }
                    val editedMediaItem = EditedMediaItem.Builder(mediaItemBuilder.build())
                        .setRemoveVideo(true)
                        .setEffects(Effects(listOf<AudioProcessor>(sonic), emptyList()))
                        .build()

                    val transformer = Transformer.Builder(context)
                        .setAudioMimeType(MimeTypes.AUDIO_AAC)
                        .addListener(object : Transformer.Listener {
                            override fun onCompleted(
                                composition: Composition,
                                result: ExportResult
                            ) {
                                shouldStopPolling.set(true)
                                onProgress(1.0)
                                try {
                                    if (config.outputPath != null) {
                                        onComplete(null)
                                    } else {
                                        onComplete(outputFile.readBytes())
                                    }
                                } catch (e: Exception) {
                                    onError(e)
                                } finally {
                                    if (config.outputPath == null) outputFile.delete()
                                }
                            }

                            override fun onError(
                                composition: Composition,
                                result: ExportResult,
                                exception: ExportException
                            ) {
                                shouldStopPolling.set(true)
                                cleanupOnFailure()
                                onError(exception)
                            }
                        })
                        .build()

                    transformerRef.set(transformer)
                    if (canceled.get()) {
                        transformer.cancel()
                        cleanupOnFailure()
                        return@post
                    }

                    // Transformer fails if the destination already exists.
                    if (outputFile.exists()) outputFile.delete()

                    onProgress(0.0)
                    transformer.start(editedMediaItem, outputFile.absolutePath)

                    // Poll for progress until the export finishes.
                    val progressHolder = ProgressHolder()
                    mainHandler.post(object : Runnable {
                        override fun run() {
                            if (shouldStopPolling.get()) return
                            val progressState = transformer.getProgress(progressHolder)
                            if (progressHolder.progress >= 0) {
                                onProgress(progressHolder.progress / 100.0)
                            }
                            if (!shouldStopPolling.get() &&
                                progressState != Transformer.PROGRESS_STATE_NOT_STARTED
                            ) {
                                mainHandler.postDelayed(this, 200)
                            }
                        }
                    })
                } catch (e: Exception) {
                    Log.e(TAG, "Error extracting audio with speed: ${e.message}", e)
                    cleanupOnFailure()
                    onError(e)
                }
            }
        }.start()

        return AudioExtractJobHandle {
            canceled.set(true)
            shouldStopPolling.set(true)
            mainHandler.post {
                transformerRef.get()?.cancel()
                cleanupOnFailure()
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
     * @param format Audio format string (mp3, aac, m4a, ogg)
     * @return MediaMuxer output format constant
     */
    private fun determineOutputFormat(format: String): Int {
        return when (format.lowercase()) {
            "mp3" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "aac" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "m4a" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            "wav" -> throw IllegalArgumentException("WAV format should be handled by extractToWav()")
            "ogg" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG
            "webm" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
            else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 // Default to MP4 container
        }
    }
}
