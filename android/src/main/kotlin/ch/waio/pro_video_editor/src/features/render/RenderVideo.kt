package ch.waio.pro_video_editor.src.features.render

import PACKAGE_TAG
import RENDER_TAG
import android.content.Context
import android.media.MediaCodecInfo
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import applyAudio
import applyBitrate
import applyBlur
import applyColorMatrix
import applyCrop
import applyFlip
import applyImageLayer
import applyPlaybackSpeed
import applyRotation
import applyScale
import applyTrim
import mapFormatToMimeType
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

@UnstableApi
class RenderVideo(private val context: Context) {
    fun render(
        imageBytes: ByteArray?,
        inputFormat: String,
        outputFormat: String,
        inputPath: String,
        outputPath: String?,
        rotateTurns: Int?,
        flipX: Boolean = false,
        flipY: Boolean = false,
        cropWidth: Int?,
        cropHeight: Int?,
        cropX: Int?,
        cropY: Int?,
        scaleX: Float?,
        scaleY: Float?,
        bitrate: Int?,
        enableAudio: Boolean = true,
        playbackSpeed: Float? = null,
        startUs: Long? = null,
        endUs: Long? = null,
        colorMatrixList: List<List<Double>>,
        blur: Double?,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        val inputFile = File(inputPath)
        val outputFile =
            if (outputPath != null) {
                File(outputPath)
            } else {
                File(
                    context.cacheDir,
                    "video_output_${System.currentTimeMillis()}.$outputFormat"
                )
            }

        val videoEffects = mutableListOf<Effect>()
        val audioEffects = mutableListOf<AudioProcessor>()
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(inputFile))

        val rotationDegrees = (4 - (rotateTurns ?: 0)) * 90f

        applyRotation(videoEffects, rotationDegrees)
        applyFlip(videoEffects, flipX, flipY)
        applyCrop(
            videoEffects, inputFile, rotationDegrees,
            flipX, flipY, cropWidth, cropHeight, cropX, cropY,
        )
        applyScale(videoEffects, scaleX, scaleY)
        applyTrim(mediaItemBuilder, startUs, endUs)
        applyColorMatrix(videoEffects, colorMatrixList)
        applyBlur(videoEffects, blur)
        applyImageLayer(
            videoEffects, inputFile, imageBytes, rotationDegrees,
            cropWidth, cropHeight, scaleX, scaleY
        )
        applyPlaybackSpeed(videoEffects, audioEffects, playbackSpeed)

        val mediaItem = mediaItemBuilder.build()
        val effects = Effects(audioEffects, videoEffects)

        val editedMediaItemBuilder = EditedMediaItem.Builder(mediaItem).setEffects(effects)

        applyAudio(editedMediaItemBuilder, enableAudio)

        val shouldStopPolling = AtomicBoolean(false)
        val outputMimeType = mapFormatToMimeType(outputFormat)
        var editedMediaItem = editedMediaItemBuilder.build()
        val encoderFactoryBuilder = DefaultEncoderFactory.Builder(context)

        applyBitrate(encoderFactoryBuilder, outputMimeType, bitrate)


        val mainHandler = Handler(Looper.getMainLooper())

        // Declare it before so it's visible in the listener
        lateinit var transformer: Transformer

        transformer = Transformer.Builder(context)
            .setEncoderFactory(encoderFactoryBuilder.build())
            .setVideoMimeType(outputMimeType)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
                    shouldStopPolling.set(true)
                    try {
                        if (outputPath != null) {
                            onComplete(null)
                        } else {
                            val resultBytes = outputFile.readBytes()
                            onComplete(resultBytes)
                        }
                    } catch (e: Exception) {
                        onError(e)
                    } finally {
                        mainHandler.removeCallbacksAndMessages(null) // stop progress polling
                        if (outputPath == null) outputFile.delete()
                    }
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException
                ) {
                    shouldStopPolling.set(true)
                    onError(exception)
                    if (outputPath == null) outputFile.delete()
                }
            })
            .build()

        // Start transformation
        transformer.start(editedMediaItem, outputFile.absolutePath)

        // Progress tracking setup
        val progressHolder = ProgressHolder()

        mainHandler.post(object : Runnable {
            override fun run() {
                if (shouldStopPolling.get()) return

                val progressState = transformer.getProgress(progressHolder)
                if (progressHolder.progress >= 0) {
                    onProgress(progressHolder.progress / 100.0)
                }

                // Continue polling if transformer started
                if (!shouldStopPolling.get() && progressState != Transformer.PROGRESS_STATE_NOT_STARTED) {
                    mainHandler.postDelayed(this, 200)
                }
            }
        })

        val cancelHandle = RenderJobHandle {
            shouldStopPolling.set(true)
            mainHandler.removeCallbacksAndMessages(null)
            transformer.cancel()
            if (outputPath == null && outputFile.exists()) {
                outputFile.delete()
            }
        }

        return cancelHandle
    }
}

class RenderJobHandle(private val cancelAction: () -> Unit) {
    private val isCanceled = AtomicBoolean(false)

    fun cancel() {
        if (isCanceled.compareAndSet(false, true)) {
            cancelAction()
        }
    }
}
