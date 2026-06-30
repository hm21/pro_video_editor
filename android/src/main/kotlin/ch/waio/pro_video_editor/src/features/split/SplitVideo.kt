package ch.waio.pro_video_editor.src.features.split

import mapFormatToMimeType
import android.content.Context
import android.net.Uri
import android.os.Handler
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import ch.waio.pro_video_editor.src.features.render.helpers.ResilientVideoEncoderFactory
import ch.waio.pro_video_editor.src.features.render.models.RenderJobHandle
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Frame-accurate splitting of a single video into two files.
 *
 * Each half is re-encoded from the exact split frame using a Media3
 * [Transformer] with a [MediaItem.ClippingConfiguration]. Because clipping at an
 * arbitrary (non-keyframe) position forces a transcode, the cut is
 * frame-accurate — unlike a transmux, which would snap to a keyframe.
 *
 * The two halves run sequentially (one encoder at a time) and every half is
 * guarded by a watchdog ([EXPORT_TIMEOUT_MS]). Crucially, [Transformer.cancel]
 * does not invoke the listener, so cancellation and timeout deliver the terminal
 * result explicitly through a single job-level guard. The job therefore always
 * terminates — success, error, cancellation or timeout — and never leaves the
 * method-channel result pending.
 */
@UnstableApi
class SplitVideo(private val context: Context) {
    companion object {
        private const val TAG = "SplitVideo"

        /** Max time a single half may export before it is force-cancelled. */
        private const val EXPORT_TIMEOUT_MS = 120_000L

        private const val POLL_INTERVAL_MS = 200L
    }

    /**
     * Starts a frame-accurate split. Writes `0 → splitUs` to [startOutputPath]
     * and `splitUs → end` to [endOutputPath], reporting both paths via
     * [onComplete].
     */
    fun split(
        inputPath: String,
        splitUs: Long,
        startOutputPath: String,
        endOutputPath: String,
        outputFormat: String,
        bitrate: Int?,
        enableAudio: Boolean,
        mainHandler: Handler,
        onProgress: (Double) -> Unit,
        onComplete: (List<String>) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        val finished = AtomicBoolean(false)
        val pollStop = AtomicBoolean(false)
        val transformerRef = AtomicReference<Transformer?>(null)
        val timeoutRef = AtomicReference<Runnable?>(null)

        fun disarmTimeout() {
            timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
        }

        fun finishSuccess(paths: List<String>) {
            if (!finished.compareAndSet(false, true)) return
            pollStop.set(true)
            disarmTimeout()
            onProgress(1.0)
            onComplete(paths)
        }

        fun finishError(error: Throwable) {
            if (!finished.compareAndSet(false, true)) return
            pollStop.set(true)
            disarmTimeout()
            // Release the active encoder if a half is still running.
            mainHandler.post { transformerRef.getAndSet(null)?.cancel() }
            onError(error)
        }

        val handle = RenderJobHandle {
            finishError(CancellationException("Split canceled"))
        }

        if (splitUs <= 0L) {
            finishError(IllegalArgumentException("splitUs must be greater than 0"))
            return handle
        }

        val inputFile = File(inputPath)
        if (!inputFile.exists()) {
            finishError(IllegalArgumentException("Input file not found: $inputPath"))
            return handle
        }

        // Half 1: 0 → split. On success, chain Half 2: split → end.
        mainHandler.post {
            if (finished.get()) return@post
            exportHalf(
                inputPath = inputPath,
                startUs = 0L,
                endUs = splitUs,
                outputPath = startOutputPath,
                outputFormat = outputFormat,
                bitrate = bitrate,
                enableAudio = enableAudio,
                mainHandler = mainHandler,
                pollStop = pollStop,
                transformerRef = transformerRef,
                timeoutRef = timeoutRef,
                onProgress = { onProgress(it * 0.5) },
                onHalfComplete = {
                    if (!finished.get()) {
                        pollStop.set(false)
                        exportHalf(
                            inputPath = inputPath,
                            startUs = splitUs,
                            endUs = null,
                            outputPath = endOutputPath,
                            outputFormat = outputFormat,
                            bitrate = bitrate,
                            enableAudio = enableAudio,
                            mainHandler = mainHandler,
                            pollStop = pollStop,
                            transformerRef = transformerRef,
                            timeoutRef = timeoutRef,
                            onProgress = { onProgress(0.5 + it * 0.5) },
                            onHalfComplete = {
                                finishSuccess(listOf(startOutputPath, endOutputPath))
                            },
                            onHalfError = { finishError(it) }
                        )
                    }
                },
                onHalfError = { finishError(it) }
            )
        }

        return handle
    }

    /**
     * Re-encodes a single clipped range to [outputPath]. Must be called on the
     * [mainHandler] thread (Media3 [Transformer] requires a Looper).
     */
    private fun exportHalf(
        inputPath: String,
        startUs: Long,
        endUs: Long?,
        outputPath: String,
        outputFormat: String,
        bitrate: Int?,
        enableAudio: Boolean,
        mainHandler: Handler,
        pollStop: AtomicBoolean,
        transformerRef: AtomicReference<Transformer?>,
        timeoutRef: AtomicReference<Runnable?>,
        onProgress: (Double) -> Unit,
        onHalfComplete: () -> Unit,
        onHalfError: (Throwable) -> Unit
    ) {
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) outputFile.delete()

        val mimeType = mapFormatToMimeType(outputFormat)
        val encoderFactory = ResilientVideoEncoderFactory(
            context = context,
            mimeType = mimeType,
            bitrate = bitrate,
        )

        // Frame-accurate clipping: a non-keyframe start forces Media3 to
        // transcode, cutting at the exact requested microsecond.
        val clipping = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionUs(startUs)
        if (endUs != null) clipping.setEndPositionUs(endUs)

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(File(inputPath)))
            .setClippingConfiguration(clipping.build())
            .build()
        val editedMediaItem = EditedMediaItem.Builder(mediaItem)
            .setRemoveAudio(!enableAudio)
            .build()

        val halfDone = AtomicBoolean(false)

        val transformer = Transformer.Builder(context)
            .setEncoderFactory(encoderFactory)
            .setVideoMimeType(mimeType)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, result: ExportResult) {
                    if (!halfDone.compareAndSet(false, true)) return
                    pollStop.set(true)
                    timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
                    onProgress(1.0)
                    onHalfComplete()
                }

                override fun onError(
                    composition: Composition,
                    result: ExportResult,
                    exception: ExportException
                ) {
                    if (!halfDone.compareAndSet(false, true)) return
                    pollStop.set(true)
                    timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
                    outputFile.delete()
                    onHalfError(exception)
                }
            })
            .build()
        transformerRef.set(transformer)

        // Watchdog: a stalled export is force-cancelled and surfaced as an error
        // instead of hanging (Transformer.cancel does not call the listener).
        val timeout = Runnable {
            if (!halfDone.compareAndSet(false, true)) return@Runnable
            pollStop.set(true)
            Log.e(TAG, "Split half timed out after ${EXPORT_TIMEOUT_MS}ms")
            try {
                transformer.cancel()
            } catch (_: Exception) {
            }
            outputFile.delete()
            onHalfError(
                IllegalStateException("Split export timed out after ${EXPORT_TIMEOUT_MS}ms")
            )
        }
        timeoutRef.set(timeout)
        mainHandler.postDelayed(timeout, EXPORT_TIMEOUT_MS)

        try {
            transformer.start(editedMediaItem, outputPath)
        } catch (e: Exception) {
            if (halfDone.compareAndSet(false, true)) {
                pollStop.set(true)
                timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
                outputFile.delete()
                onHalfError(e)
            }
            return
        }

        // Progress polling.
        val progressHolder = ProgressHolder()
        mainHandler.post(object : Runnable {
            override fun run() {
                if (pollStop.get() || halfDone.get()) return
                transformer.getProgress(progressHolder)
                if (progressHolder.progress >= 0) {
                    onProgress(progressHolder.progress / 100.0)
                }
                mainHandler.postDelayed(this, POLL_INTERVAL_MS)
            }
        })
    }
}
