package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

/**
 * Utility for pre-transcoding HEVC 10-bit HDR videos to H.264 8-bit.
 * 
 * This is necessary because GPU-based effect pipelines on Android have compatibility
 * issues with HEVC Main 10 Profile (hvc1.2.4.H120) videos. By transcoding to H.264 first,
 * we can then safely apply effects like ColorMatrix, Blur, or Overlay.
 */
@UnstableApi
object VideoTranscoder {

    /**
     * Result of a transcoding operation.
     */
    sealed class TranscodeResult {
        /** Transcoding succeeded, contains path to transcoded file */
        data class Success(val outputPath: String) : TranscodeResult()

        /** No transcoding needed, original file is compatible */
        data class NotNeeded(val originalPath: String) : TranscodeResult()

        /** Transcoding failed with error */
        data class Error(val exception: Throwable) : TranscodeResult()
    }

    /**
     * Checks if a video needs transcoding for effect compatibility.
     * 
     * @param videoPath Path to the video file
     * @return True if transcoding is needed
     */
    fun needsTranscoding(videoPath: String): Boolean {
        val formatInfo = MediaInfoExtractor.getVideoFormatInfo(videoPath)
        val needsTranscode = formatInfo.needsTranscodingForEffects()

        Log.d(
            RENDER_TAG, "Video transcoding check: path=$videoPath, " +
                    "isHevc=${formatInfo.isHevc}, bitDepth=${formatInfo.bitDepth}, " +
                    "isHdr=${formatInfo.isHdr}, needsTranscoding=$needsTranscode"
        )

        return needsTranscode
    }

    /**
     * Transcodes a video to H.264 8-bit SDR format for effect compatibility.
     * 
     * Uses HDR -> SDR tonemapping to convert 10-bit HDR to 8-bit SDR,
     * which then allows H.264 encoding.
     * 
     * This is a blocking operation that should be called from a background thread.
     * The transcoded file is saved to the app's cache directory.
     * 
     * @param context Android context
     * @param inputPath Path to the input video
     * @return TranscodeResult indicating success, not-needed, or error
     */
    fun transcodeToH264Sync(context: Context, inputPath: String): TranscodeResult {
        // Check if transcoding is needed
        if (!needsTranscoding(inputPath)) {
            Log.d(RENDER_TAG, "No transcoding needed for: $inputPath")
            return TranscodeResult.NotNeeded(inputPath)
        }

        Log.i(RENDER_TAG, "Starting HEVC 10-bit HDR -> H.264 8-bit SDR transcoding for: $inputPath")

        val outputFile = File(
            context.cacheDir,
            "transcoded_${System.currentTimeMillis()}.mp4"
        )

        val resultRef = AtomicReference<TranscodeResult>()
        val latch = CountDownLatch(1)
        val mainHandler = Handler(Looper.getMainLooper())

        mainHandler.post {
            try {
                // Create encoder factory that forces H.264
                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setEnableFallback(true)
                    .build()

                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)  // Force H.264 output
                    .setEncoderFactory(encoderFactory)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            Log.i(RENDER_TAG, "Transcoding completed: ${outputFile.absolutePath}")

                            // Verify the output is actually H.264
                            val outputInfo =
                                MediaInfoExtractor.getVideoFormatInfo(outputFile.absolutePath)
                            Log.i(
                                RENDER_TAG, "Transcoded output: isHevc=${outputInfo.isHevc}, " +
                                        "bitDepth=${outputInfo.bitDepth}, isHdr=${outputInfo.isHdr}"
                            )

                            resultRef.set(TranscodeResult.Success(outputFile.absolutePath))
                            latch.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            result: ExportResult,
                            exception: ExportException
                        ) {
                            Log.e(RENDER_TAG, "Transcoding failed: ${exception.message}")
                            outputFile.delete()
                            resultRef.set(TranscodeResult.Error(exception))
                            latch.countDown()
                        }
                    })
                    .build()

                // Create composition with HDR tonemapping to force SDR output
                val mediaItem = MediaItem.Builder()
                    .setUri(inputPath)
                    .build()

                // Use HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL to convert HDR to SDR
                // This forces 8-bit output which then allows H.264 encoding
                val editedMediaItem = EditedMediaItem.Builder(mediaItem)
                    .setRemoveAudio(false)
                    .setRemoveVideo(false)
                    .build()

                // Build composition with HDR tonemapping enabled
                val sequence = EditedMediaItemSequence.Builder(editedMediaItem).build()
                val composition = Composition.Builder(sequence)
                    // Force HDR to SDR conversion - this enables H.264 encoding
                    .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
                    .build()

                transformer.start(composition, outputFile.absolutePath)

            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Failed to start transcoding: ${e.message}")
                resultRef.set(TranscodeResult.Error(e))
                latch.countDown()
            }
        }

        // Wait for transcoding to complete
        try {
            latch.await()
        } catch (e: InterruptedException) {
            return TranscodeResult.Error(e)
        }

        return resultRef.get() ?: TranscodeResult.Error(
            IllegalStateException("Transcoding result not set")
        )
    }

    /**
     * Async version of transcoding.
     * 
     * @param context Android context
     * @param inputPath Path to the input video
     * @param onComplete Callback with result
     */
    fun transcodeToH264Async(
        context: Context,
        inputPath: String,
        onComplete: (TranscodeResult) -> Unit
    ) {
        Thread {
            val result = transcodeToH264Sync(context, inputPath)
            Handler(Looper.getMainLooper()).post {
                onComplete(result)
            }
        }.start()
    }

    /**
     * Transcodes multiple video clips if needed.
     * 
     * @param context Android context
     * @param inputPaths List of input video paths
     * @return Map of original path to transcoded path (or original if no transcoding needed)
     */
    fun transcodeClipsIfNeeded(
        context: Context,
        inputPaths: List<String>
    ): Map<String, String> {
        val result = mutableMapOf<String, String>()

        for (inputPath in inputPaths) {
            when (val transcodeResult = transcodeToH264Sync(context, inputPath)) {
                is TranscodeResult.Success -> {
                    result[inputPath] = transcodeResult.outputPath
                }

                is TranscodeResult.NotNeeded -> {
                    result[inputPath] = transcodeResult.originalPath
                }

                is TranscodeResult.Error -> {
                    Log.e(RENDER_TAG, "Transcoding failed for $inputPath, using original")
                    result[inputPath] = inputPath
                }
            }
        }

        return result
    }

    /**
     * Cleans up transcoded temporary files.
     * 
     * @param transcodedPaths List of transcoded file paths to delete
     */
    fun cleanupTranscodedFiles(transcodedPaths: Collection<String>) {
        for (path in transcodedPaths) {
            val file = File(path)
            if (file.exists() && file.absolutePath.contains("transcoded_")) {
                val deleted = file.delete()
                Log.d(RENDER_TAG, "Cleanup transcoded file: $path, deleted=$deleted")
            }
        }
    }
}
