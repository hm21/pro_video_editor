package ch.waio.pro_video_editor.src.features.split

import mapFormatToMimeType
import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.SystemClock
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
import ch.waio.pro_video_editor.src.shared.concurrency.ExportGate
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
 * guarded by two watchdogs: an inner stall bound (no forward progress for
 * `stallTimeoutMs`) and an outer hard bound (`exportTimeoutMs`). Either one
 * force-cancels the [Transformer] and fails with a diagnostic context (which
 * half, last progress, segment/total durations, mime, audio). Crucially,
 * [Transformer.cancel] does not invoke the listener, so cancellation, stall and
 * timeout deliver the terminal result explicitly through a single job-level
 * guard. The job therefore always terminates — success, error, cancellation,
 * stall or timeout — and never leaves the method-channel result pending.
 *
 * Note on stalls: a genuine hang here is almost always contention for the
 * device's limited hardware [android.media.MediaCodec] encoder pool — split and
 * concurrent speed renders both drive their [Transformer] on the main [Looper]
 * with no global cap on live encoder sessions. A second concurrent encoder can
 * block at `progress == 0`, which the stall bound now catches.
 */
@UnstableApi
class SplitVideo(private val context: Context) {
    companion object {
        private const val TAG = "SplitVideo"

        /** Default hard upper bound before a half is force-cancelled. */
        const val DEFAULT_EXPORT_TIMEOUT_MS = 120_000L

        /** Default stall bound: no forward progress for this long → stalled. */
        const val DEFAULT_STALL_TIMEOUT_MS = 12_000L

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
        exportTimeoutMs: Long = DEFAULT_EXPORT_TIMEOUT_MS,
        stallTimeoutMs: Long = DEFAULT_STALL_TIMEOUT_MS,
        onProgress: (Double) -> Unit,
        onComplete: (List<String>) -> Unit,
        onError: (Throwable) -> Unit
    ): RenderJobHandle {
        val finished = AtomicBoolean(false)
        val pollStop = AtomicBoolean(false)
        val transformerRef = AtomicReference<Transformer?>(null)
        val timeoutRef = AtomicReference<Runnable?>(null)
        // True once this job holds the process-wide encoder slot. Both halves
        // run under a single slot; it is released exactly once at job end.
        val gateHeld = AtomicBoolean(false)

        fun releaseGateIfHeld() {
            if (gateHeld.compareAndSet(true, false)) ExportGate.release()
        }

        fun disarmTimeout() {
            timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
        }

        fun finishSuccess(paths: List<String>) {
            if (!finished.compareAndSet(false, true)) return
            pollStop.set(true)
            disarmTimeout()
            releaseGateIfHeld()
            onProgress(1.0)
            onComplete(paths)
        }

        fun finishError(error: Throwable) {
            if (!finished.compareAndSet(false, true)) return
            pollStop.set(true)
            disarmTimeout()
            // Tear down the active encoder *before* releasing the gate, so the
            // next queued job can't start a second encoder while this one is
            // still live. finishError always runs on the main Looper (the thread
            // the Transformer was created on), so cancel synchronously.
            try {
                transformerRef.getAndSet(null)?.cancel()
            } catch (_: Exception) {
            }
            releaseGateIfHeld()
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

        mainHandler.post {
            if (finished.get()) return@post
            // Serialize against other encodes (concurrent renders/splits) so
            // they don't starve each other on the hardware encoder. The wait is
            // *before* exportHalf arms its stall watchdog, so queueing never
            // counts as a stall — a split behind a running render waits instead
            // of failing fast. onGranted always runs on the main Looper (either
            // synchronously here, or from another job's release()).
            ExportGate.acquire {
                gateHeld.set(true)
                // Cancelled/failed while queued: hand the slot straight back.
                if (finished.get()) {
                    releaseGateIfHeld()
                    return@acquire
                }
                // Half 1: 0 → split. On success, chain Half 2: split → end.
                exportHalf(
                    inputPath = inputPath,
                    half = "start",
                    startUs = 0L,
                    endUs = splitUs,
                    splitUs = splitUs,
                    outputPath = startOutputPath,
                    outputFormat = outputFormat,
                    bitrate = bitrate,
                    enableAudio = enableAudio,
                    mainHandler = mainHandler,
                    exportTimeoutMs = exportTimeoutMs,
                    stallTimeoutMs = stallTimeoutMs,
                    pollStop = pollStop,
                    transformerRef = transformerRef,
                    timeoutRef = timeoutRef,
                    onProgress = { onProgress(it * 0.5) },
                    onHalfComplete = {
                        if (!finished.get()) {
                            pollStop.set(false)
                            exportHalf(
                                inputPath = inputPath,
                                half = "end",
                                startUs = splitUs,
                                endUs = null,
                                splitUs = splitUs,
                                outputPath = endOutputPath,
                                outputFormat = outputFormat,
                                bitrate = bitrate,
                                enableAudio = enableAudio,
                                mainHandler = mainHandler,
                                exportTimeoutMs = exportTimeoutMs,
                                stallTimeoutMs = stallTimeoutMs,
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
        }

        return handle
    }

    /**
     * Re-encodes a single clipped range to [outputPath]. Must be called on the
     * [mainHandler] thread (Media3 [Transformer] requires a Looper).
     *
     * [half] is `"start"` or `"end"` and [splitUs] the absolute split position;
     * both are used only to build the diagnostic context of a stall/timeout
     * failure. The source duration is probed lazily on the failure path so a
     * successful split incurs no extra work.
     */
    private fun exportHalf(
        inputPath: String,
        half: String,
        startUs: Long,
        endUs: Long?,
        splitUs: Long,
        outputPath: String,
        outputFormat: String,
        bitrate: Int?,
        enableAudio: Boolean,
        mainHandler: Handler,
        exportTimeoutMs: Long,
        stallTimeoutMs: Long,
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
        // Last progress percentage (0..100) reported by the encoder, or -1 if
        // none yet. Read by the watchdogs to enrich the failure message.
        val lastPercent = java.util.concurrent.atomic.AtomicInteger(-1)

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

        // Diagnostics are built only when a watchdog fires, so the source
        // duration probe never runs on a successful split.
        fun diagnostics(): SplitExportDiagnostics {
            val totalUs = probeDurationUs(inputPath)
            val segmentUs = when {
                endUs != null -> endUs - startUs
                totalUs > 0 -> totalUs - startUs
                else -> -1L
            }
            return SplitExportDiagnostics(
                half = half,
                segmentUs = segmentUs,
                splitUs = splitUs,
                totalUs = totalUs,
                mimeType = mimeType,
                enableAudio = enableAudio,
            )
        }

        fun lastFraction(): Double = lastPercent.get().coerceAtLeast(0) / 100.0

        // Single terminal path: force-cancel the (listener-silent) transformer,
        // clean up and surface [cause] exactly once. Used for a synchronous
        // start() failure whose cause is already known.
        fun failHalf(cause: Throwable) {
            if (!halfDone.compareAndSet(false, true)) return
            pollStop.set(true)
            timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
            try {
                transformer.cancel()
            } catch (_: Exception) {
            }
            outputFile.delete()
            onHalfError(cause)
        }

        // Watchdog terminal path: claim the terminal and tear the encoder down
        // synchronously (fast, main thread), then build the diagnostic message —
        // whose duration probe (MediaMetadataRetriever) is blocking file I/O — on
        // a background thread so it never stalls the UI thread on the already-
        // stressed failure path.
        fun failHalfDiagnosed(stall: Boolean, seconds: Long) {
            if (!halfDone.compareAndSet(false, true)) return
            pollStop.set(true)
            timeoutRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
            try {
                transformer.cancel()
            } catch (_: Exception) {
            }
            outputFile.delete()
            val progress = lastFraction()
            Thread {
                val diag = diagnostics()
                val message =
                    if (stall) diag.stallMessage(seconds, progress)
                    else diag.timeoutMessage(seconds, progress)
                Log.e(TAG, message)
                // Deliver back on the main Looper: onHalfError chains into the
                // job-level finish, which releases the encoder gate and may hand
                // the slot to the next queued job — that job's export must start
                // on the Looper thread, not this probe thread.
                mainHandler.post { onHalfError(IllegalStateException(message)) }
            }.start()
        }

        // Outer hard watchdog: a still-progressing but never-finishing export is
        // force-cancelled and surfaced as an error instead of hanging.
        val timeout = Runnable {
            if (halfDone.get()) return@Runnable
            failHalfDiagnosed(stall = false, seconds = Math.round(exportTimeoutMs / 1000.0))
        }
        timeoutRef.set(timeout)
        mainHandler.postDelayed(timeout, exportTimeoutMs)

        try {
            transformer.start(editedMediaItem, outputPath)
        } catch (e: Exception) {
            failHalf(e)
            return
        }

        // Progress polling + inner stall watchdog. `lastAdvanceAt` marks the
        // last time progress moved forward; if it never does for stallTimeoutMs
        // (the reported "stuck at 0%" case) the half is failed early.
        val progressHolder = ProgressHolder()
        mainHandler.post(object : Runnable {
            private var lastProgress = -1
            private var lastAdvanceAt = SystemClock.uptimeMillis()

            override fun run() {
                if (pollStop.get() || halfDone.get()) return
                transformer.getProgress(progressHolder)
                val now = SystemClock.uptimeMillis()
                val percent = progressHolder.progress
                if (percent >= 0) {
                    lastPercent.set(percent)
                    onProgress(percent / 100.0)
                    if (percent > lastProgress) {
                        lastProgress = percent
                        lastAdvanceAt = now
                    }
                }
                // Media3 reports progress in whole percent, so "forward
                // progress" only ticks per 1%. A healthy encode that advances
                // slower than 1% per stallTimeout would be misread as stalled;
                // in practice that means a single encode longer than ~100×
                // stallTimeout, which the outer hard bound already caps and
                // which the ExportGate now keeps free of pool contention.
                if (stallTimeoutMs > 0 && now - lastAdvanceAt >= stallTimeoutMs) {
                    failHalfDiagnosed(
                        stall = true,
                        seconds = Math.round(stallTimeoutMs / 1000.0),
                    )
                    return
                }
                mainHandler.postDelayed(this, POLL_INTERVAL_MS)
            }
        })
    }

    /** Best-effort source duration in microseconds, or -1 if it cannot be read. */
    private fun probeDurationUs(path: String): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val ms = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            if (ms > 0L) ms * 1000L else -1L
        } catch (e: Exception) {
            Log.w(TAG, "Failed to probe duration for split diagnostics: ${e.message}")
            -1L
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }
}
