package ch.waio.pro_video_editor.src.features.render

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import applyBitrate
import mapFormatToMimeType
import ch.waio.pro_video_editor.src.features.render.helpers.applyComposition
import ch.waio.pro_video_editor.src.features.render.helpers.VolumeControlAudioMixerFactory
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.RenderJobHandle

/**
 * Service for rendering video with applied effects and transformations.
 *
 * This class handles the complete video rendering pipeline using AndroidX Media3 Transformer:
 * - Applies visual and audio effects based on configuration
 * - Manages output file handling (both temporary and permanent)
 * - Provides progress tracking during rendering
 * - Supports cancellation of active render jobs
 */
@UnstableApi
class RenderVideo(private val context: Context) {

    private val effectsProcessor = EffectsProcessor()

    /**
     * Starts an asynchronous video render job.
     *
     * This method configures and starts a Media3 Transformer to process the video
     * with the specified effects. The operation runs asynchronously and provides
     * callbacks for progress updates, completion, and errors.
     *
     * @param config Complete render configuration including input, output, and effects
     * @param onProgress Callback invoked with progress updates (0.0 to 1.0)
     * @param onComplete Callback invoked on success with output bytes (null if saved to file)
     * @param onError Callback invoked if rendering fails
     * @return RenderJobHandle that can be used to cancel the render job
     */
    fun render(
        config: RenderConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        // Determine output file location
        val outputFile =
            if (config.outputPath != null) {
                File(config.outputPath)
            } else {
                File(
                    context.cacheDir,
                    "video_output_${System.currentTimeMillis()}.${config.outputFormat}"
                )
            }

        // Process effects from configuration
        val (videoEffects, audioEffects) = effectsProcessor.process(config)
        val rotationDegrees = (4 - (config.rotateTurns ?: 0)) * 90f

        val shouldStopPolling = AtomicBoolean(false)
        val outputMimeType = mapFormatToMimeType(config.outputFormat)
        val encoderFactoryBuilder = DefaultEncoderFactory.Builder(context)

        applyBitrate(encoderFactoryBuilder, outputMimeType, config.bitrate)

        val mainHandler = Handler(Looper.getMainLooper())

        // Declare transformer before listener to make it accessible
        lateinit var transformer: Transformer

        // Check if we need custom audio mixing with volume control
        val hasCustomAudio = config.customAudioPath != null && config.customAudioPath.isNotEmpty()
        val videoAudioVolume = config.originalAudioVolume ?: 1.0f
        val customAudioVolume = config.customAudioVolume ?: 1.0f
        
        // Determine if video audio will be present in the mix
        // Video audio is removed when volume is 0 or audio is disabled
        val videoAudioPresent = config.enableAudio && videoAudioVolume > 0.0f

        // Build transformer with callbacks
        val transformerBuilder = Transformer.Builder(context)
            .setEncoderFactory(encoderFactoryBuilder.build())
            .setVideoMimeType(outputMimeType)

        // Use custom audio mixer ONLY when mixing video audio with custom audio
        // For video-only volume adjustment, VolumeAudioProcessor is used instead
        // (AudioProcessors don't work with parallel sequences, but work fine with single sequence)
        if (hasCustomAudio) {
            transformerBuilder.setAudioMixerFactory(
                VolumeControlAudioMixerFactory(
                    videoAudioVolume = videoAudioVolume,
                    customAudioVolume = customAudioVolume,
                    videoAudioPresent = videoAudioPresent
                )
            )
        }

        transformer = transformerBuilder
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
                    shouldStopPolling.set(true)
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
                        mainHandler.removeCallbacksAndMessages(null)
                        if (config.outputPath == null) outputFile.delete()
                    }
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException
                ) {
                    shouldStopPolling.set(true)
                    onError(exception)
                    if (config.outputPath == null) outputFile.delete()
                }
            })
            .build()
        
        // Create composition (now fast - no manual audio mixing needed, Media3 handles it natively)
        Thread {
            try {
                val composition = applyComposition(
                    context = context,
                    config = config,
                    videoEffects = videoEffects,
                    audioEffects = audioEffects
                )

                mainHandler.post {
                    if (composition != null) {
                        transformer.start(composition, outputFile.absolutePath)
                        
                        // Start progress tracking loop
                        val progressHolder = ProgressHolder()
                        mainHandler.post(object : Runnable {
                            override fun run() {
                                if (shouldStopPolling.get()) return

                                val progressState = transformer.getProgress(progressHolder)
                                if (progressHolder.progress >= 0) {
                                    onProgress(progressHolder.progress / 100.0)
                                }

                                // Continue polling if transformation is active
                                if (!shouldStopPolling.get() && progressState != Transformer.PROGRESS_STATE_NOT_STARTED) {
                                    mainHandler.postDelayed(this, 200)
                                }
                            }
                        })
                    } else {
                        onError(IllegalStateException("Failed to create composition"))
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    onError(e)
                }
            }
        }.start()

        // Return cancellation handle
        return RenderJobHandle {
            shouldStopPolling.set(true)
            mainHandler.removeCallbacksAndMessages(null)
            transformer.cancel()
            if (config.outputPath == null && outputFile.exists()) {
                outputFile.delete()
            }
        }
    }
}
