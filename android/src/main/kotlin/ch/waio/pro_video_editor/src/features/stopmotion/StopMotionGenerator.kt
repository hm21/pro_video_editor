package ch.waio.pro_video_editor.src.features.stopmotion

import RENDER_TAG
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import applyBitrate
import ch.waio.pro_video_editor.src.features.render.models.RenderJobHandle
import ch.waio.pro_video_editor.src.features.stopmotion.models.StopMotionConfig
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import ch.waio.pro_video_editor.src.shared.media.ImageOrientation
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.exp
import kotlin.math.roundToInt

/**
 * Service for rendering a stop-motion video from a sequence of still images.
 *
 * Each image is held for a fixed duration and encoded into a single (silent)
 * video using AndroidX Media3 Transformer's image input. Audio can be added
 * afterwards via the regular render pipeline.
 */
@UnstableApi
class StopMotionGenerator(private val context: Context) {

    private class PreparedFrame(val file: File, val durationUs: Long)

    /**
     * Starts an asynchronous stop-motion render job.
     *
     * @param config Complete stop-motion render configuration.
     * @param onProgress Callback invoked with progress updates (0.0 to 1.0).
     * @param onComplete Callback invoked on success with output bytes (null if
     *   saved directly to [StopMotionConfig.outputPath]).
     * @param onError Callback invoked if rendering fails or is cancelled.
     * @return A [RenderJobHandle] used to cancel the job.
     */
    fun render(
        config: StopMotionConfig,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        val mainHandler = Handler(Looper.getMainLooper())
        val shouldStopPolling = AtomicBoolean(false)
        val transformerRef = AtomicReference<Transformer?>(null)
        val tempFiles = mutableListOf<File>()

        // Determine output file location.
        val outputFile = if (config.outputPath != null) {
            File(config.outputPath)
        } else {
            File(context.cacheDir, "stopmotion_${System.currentTimeMillis()}.mp4")
        }

        val cleanupTempFrames: () -> Unit = {
            synchronized(tempFiles) {
                tempFiles.forEach { runCatching { it.delete() } }
                tempFiles.clear()
            }
        }

        // Frame preparation owns the first 20% of the progress bar, the
        // transformer the remaining 80%. Preparing (decode + re-encode) can take
        // a noticeable amount of time for many high-resolution photos, so it must
        // report progress instead of sitting at 0%.
        val prepShare = 0.2
        val transformProgress: (Double) -> Unit = { p ->
            onProgress((prepShare + p.coerceIn(0.0, 1.0) * (1.0 - prepShare)))
        }

        // Prepare frames (decode + write normalized JPEGs) off the main thread,
        // then build and start the transformer on the main thread.
        Thread {
            try {
                val frameRate = config.frameRate.roundToInt().coerceAtLeast(1)
                val defaultDurationUs = (1_000_000.0 / frameRate).roundToInt().toLong()

                // Determine the (orientation-corrected) target size up front so
                // frames can be decoded downscaled instead of at full resolution.
                var targetWidth = config.width ?: 0
                var targetHeight = config.height ?: 0
                // Kept so the first frame's decode does not re-read the EXIF
                // this probe has already parsed.
                var firstProbe: ImageOrientation.Probe? = null
                if (targetWidth <= 0 || targetHeight <= 0) {
                    val probe = ImageOrientation.probe(config.frames[0].image)
                    firstProbe = probe
                    targetWidth = probe?.width ?: 2
                    targetHeight = probe?.height ?: 2
                }
                targetWidth = evenize(targetWidth)
                targetHeight = evenize(targetHeight)

                val count = config.frames.size
                val prepared = mutableListOf<PreparedFrame>()
                config.frames.forEachIndexed { index, frame ->
                    if (shouldStopPolling.get()) return@Thread

                    val bitmap = ImageOrientation.decode(
                        frame.image,
                        reqWidth = targetWidth,
                        reqHeight = targetHeight,
                        knownOrientation = if (index == 0) firstProbe?.orientation else null,
                    ) ?: throw IllegalStateException(
                        // Name the source: a path-backed frame fails here rather
                        // than at the call, so without it there is nothing to
                        // tell the caller which photo went missing.
                        "Failed to decode frame $index (${frame.image.describe()})"
                    )

                    val file = File(
                        context.cacheDir,
                        "stopmotion_frame_${System.currentTimeMillis()}_$index.jpg"
                    )
                    file.outputStream().use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                    }
                    bitmap.recycle()
                    synchronized(tempFiles) { tempFiles.add(file) }
                    prepared.add(PreparedFrame(file, frame.durationUs ?: defaultDurationUs))

                    onProgress((index + 1).toDouble() / count * prepShare)
                }

                // Normalize all frames to an even target size with the chosen fit.
                val presentation = Presentation.createForWidthAndHeight(
                    targetWidth, targetHeight, layoutForFit(config.fit)
                )
                val effects = Effects(emptyList<AudioProcessor>(), listOf<Effect>(presentation))

                val editedItems = prepared.map { prep ->
                    // Mark the item as an image via setImageDurationMs — this is
                    // the field the Media3 image asset loader reads. Setting only
                    // EditedMediaItem.durationUs makes Transformer treat the image
                    // as a media file and fail with "Asset loader error".
                    val mediaItem = MediaItem.Builder()
                        .setUri(Uri.fromFile(prep.file))
                        .setMimeType(MimeTypes.IMAGE_JPEG)
                        .setImageDurationMs((prep.durationUs / 1000).coerceAtLeast(1))
                        .build()
                    EditedMediaItem.Builder(mediaItem)
                        .setFrameRate(frameRate)
                        .setEffects(effects)
                        .build()
                }

                val trackTypes = mutableSetOf<@C.TrackType Int>(C.TRACK_TYPE_VIDEO)
                val sequence = EditedMediaItemSequence.Builder(trackTypes)
                    .addItems(editedItems)
                    .setIsLooping(false)
                    .build()
                val composition = Composition.Builder(listOf(sequence)).build()

                mainHandler.post {
                    if (shouldStopPolling.get()) {
                        cleanupTempFrames()
                        return@post
                    }
                    startTransformer(
                        config = config,
                        composition = composition,
                        outputFile = outputFile,
                        mainHandler = mainHandler,
                        shouldStopPolling = shouldStopPolling,
                        transformerRef = transformerRef,
                        cleanupTempFrames = cleanupTempFrames,
                        onProgress = transformProgress,
                        onComplete = onComplete,
                        onError = onError
                    )
                }
            } catch (e: Exception) {
                Log.e(RENDER_TAG, "Stop-motion preparation failed: ${e.message}")
                cleanupTempFrames()
                mainHandler.post { onError(e) }
            }
        }.start()

        return RenderJobHandle {
            shouldStopPolling.set(true)
            mainHandler.post {
                runCatching { transformerRef.get()?.cancel() }
                cleanupTempFrames()
                if (config.outputPath == null) runCatching { outputFile.delete() }
            }
        }
    }

    private fun startTransformer(
        config: StopMotionConfig,
        composition: Composition,
        outputFile: File,
        mainHandler: Handler,
        shouldStopPolling: AtomicBoolean,
        transformerRef: AtomicReference<Transformer?>,
        cleanupTempFrames: () -> Unit,
        onProgress: (Double) -> Unit,
        onComplete: (ByteArray?) -> Unit,
        onError: (Throwable) -> Unit
    ) {
        val encoderFactoryBuilder = DefaultEncoderFactory.Builder(context)
            .setEnableFallback(true)
        applyBitrate(encoderFactoryBuilder, MimeTypes.VIDEO_H264, config.bitrate)

        val transformer = Transformer.Builder(context)
            .setEncoderFactory(encoderFactoryBuilder.build())
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
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
                        cleanupTempFrames()
                        if (config.outputPath == null) outputFile.delete()
                    }
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException
                ) {
                    shouldStopPolling.set(true)
                    cleanupTempFrames()
                    if (config.outputPath == null) outputFile.delete()
                    onError(exception)
                }
            })
            .build()
        transformerRef.set(transformer)

        transformer.start(composition, outputFile.absolutePath)

        // Media3's image-to-video export usually can't report intra-export
        // progress (getProgress returns PROGRESS_STATE_UNAVAILABLE for image
        // input), and the previous loop also stopped polling on the initial
        // PROGRESS_STATE_NOT_STARTED. Together that froze the bar for the whole
        // encode and then snapped it to 100% via onCompleted.
        //
        // Drive a smooth, monotonic time-based estimate that eases toward — but
        // never reaches — 100% while polling, and prefer the real Media3 value
        // whenever it becomes available. Completion (1.0) is owned by the
        // listener's onCompleted.
        val progressHolder = ProgressHolder()
        val encodeStartMs = SystemClock.elapsedRealtime()
        // More frames → longer expected encode → slower easing, so the estimate
        // stays roughly in step with the real work instead of racing ahead.
        val easingTauMs = (config.frames.size * 50L).coerceIn(1_500L, 20_000L)
        mainHandler.post(object : Runnable {
            private var lastReported = 0.0

            override fun run() {
                if (shouldStopPolling.get()) return

                val state = transformer.getProgress(progressHolder)
                val realProgress =
                    if (state == Transformer.PROGRESS_STATE_AVAILABLE &&
                        progressHolder.progress >= 0
                    ) {
                        progressHolder.progress / 100.0
                    } else {
                        null
                    }

                val elapsedMs = (SystemClock.elapsedRealtime() - encodeStartMs).toDouble()
                val estimated = 1.0 - exp(-elapsedMs / easingTauMs)

                // Never regress and never claim completion — onCompleted owns 1.0.
                val next = maxOf(lastReported, realProgress ?: estimated)
                    .coerceAtMost(0.99)
                lastReported = next
                onProgress(next)

                if (!shouldStopPolling.get()) {
                    mainHandler.postDelayed(this, 100)
                }
            }
        })
    }

    /** Rounds a dimension down to the nearest even value, minimum 2. */
    private fun evenize(value: Int): Int {
        val v = if (value <= 0) 2 else value
        return maxOf(2, v - (v % 2))
    }

    /** Maps the Dart `StopMotionFit` name to a Media3 [Presentation] layout. */
    private fun layoutForFit(fit: String): Int = when (fit) {
        "stretch" -> Presentation.LAYOUT_STRETCH_TO_FIT
        "cover" -> Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP
        else -> Presentation.LAYOUT_SCALE_TO_FIT // "contain"
    }
}
