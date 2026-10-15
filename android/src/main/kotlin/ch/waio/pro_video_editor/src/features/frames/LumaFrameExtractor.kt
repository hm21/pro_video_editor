package ch.waio.pro_video_editor.src.features.frames

import android.content.Context
import ch.waio.pro_video_editor.src.features.frames.models.FrameStreamConfig
import ch.waio.pro_video_editor.src.features.thumbnail.SequentialFrameDecoder
import ch.waio.pro_video_editor.src.features.thumbnail.ThumbnailGenerator
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailConfig
import ch.waio.pro_video_editor.src.features.thumbnail.models.ThumbnailJobHandle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.TreeMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Streams every frame of a video range as small upright 8-bit luma images
 * with their source timestamps, in presentation order.
 *
 * The sample timestamps of the range are read up front without decoding,
 * thinned to [FrameStreamConfig.maxFrameRate], and decoded through
 * [ThumbnailGenerator]'s extraction chain (parallel forward passes, then the
 * slower fallbacks) with raw luma output instead of an encoded image. The
 * parallel passes finish out of order, so frames are held back until every
 * earlier one has been delivered, and all of them come in the first one's
 * size.
 */
class LumaFrameExtractor(
    context: Context,
    private val thumbnailGenerator: ThumbnailGenerator,
) {
    private val decoder = SequentialFrameDecoder(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Starts streaming the frames of [config]'s range.
     *
     * [onFrame] receives each frame's presentation time in microseconds, its
     * size, its luma bytes and the overall progress (0.0 to 1.0), in
     * presentation order. [onComplete] fires after the last frame; [onError]
     * fires instead on failure or after a cancel through the returned handle
     * (with a [CancellationException]).
     */
    fun streamFrames(
        config: FrameStreamConfig,
        onFrame: (ptsUs: Long, width: Int, height: Int, luma: ByteArray, progress: Double) -> Unit,
        onComplete: () -> Unit,
        onError: (Exception) -> Unit,
    ): ThumbnailJobHandle {
        val cancelled = AtomicBoolean(false)
        val inner = AtomicReference<ThumbnailJobHandle?>(null)
        val reported = AtomicBoolean(false)
        fun fail(e: Exception) {
            if (reported.compareAndSet(false, true)) onError(e)
        }

        val job = scope.launch {
            try {
                val timestamps = selectTimestamps(config)
                if (cancelled.get()) throw CancellationException("Frame stream was canceled")
                // The extraction strategies scale with slightly different
                // rounding, so a frame a fallback extracted can be a pixel off.
                // Every frame takes the first one's size: motion analysis
                // compares them pixel by pixel.
                var size: Pair<Int, Int>? = null
                val ordered = Reorderer(timestamps.size) { index, payload ->
                    val (width, height) = size
                        ?: (payload.width to payload.height).also { size = it }
                    val frame = payload.resized(width, height)
                    val progress = (index + 1).toDouble() / timestamps.size
                    onFrame(timestamps[index], width, height, frame.luma, progress)
                }
                val handle = thumbnailGenerator.streamThumbnails(
                    config = ThumbnailConfig(
                        id = config.id,
                        inputPath = config.inputPath,
                        extension = config.extension,
                        boxFit = "contain",
                        outputFormat = LUMA_FORMAT,
                        jpegQuality = 0,
                        outputWidth = config.outputWidth,
                        outputHeight = config.outputHeight,
                        timestampsUs = timestamps,
                        maxOutputFrames = null,
                        maxParallelDecoders = config.maxParallelDecoders,
                    ),
                    onFrame = { indices, bytes, _ ->
                        ordered.add(indices, parseLumaPayload(bytes))
                    },
                    onComplete = {
                        ordered.flush()
                        if (reported.compareAndSet(false, true)) onComplete()
                    },
                    onError = ::fail,
                )
                inner.set(handle)
                // A cancel that raced the start above has nothing to stop yet.
                if (cancelled.get()) handle.cancel()
            } catch (e: Exception) {
                fail(e)
            }
        }
        job.invokeOnCompletion { cause ->
            if (cause != null) fail(cause as? Exception ?: IllegalStateException(cause))
        }
        return ThumbnailJobHandle {
            cancelled.set(true)
            job.cancel()
            inner.get()?.cancel?.invoke()
        }
    }

    /** The sample timestamps of the range, at most one per frame period. */
    private fun selectTimestamps(config: FrameStreamConfig): List<Long> {
        val scan = decoder.scan(config.inputPath)
        val start = config.startUs ?: Long.MIN_VALUE
        val end = config.endUs ?: Long.MAX_VALUE
        // A millisecond of slack keeps a 30 fps cap from dropping frames of a
        // 30 fps video whose timestamps jitter.
        val minSpacing = config.maxFrameRate?.let { (1_000_000 / it).toLong() - 1_000 }
        val selected = ArrayList<Long>()
        for (pts in scan.samplePts) {
            if (pts < start || pts >= end) continue
            val last = selected.lastOrNull()
            // A repeated timestamp is no new frame.
            if (last != null && pts <= last) continue
            if (minSpacing != null && last != null && pts - last < minSpacing) continue
            selected.add(pts)
        }
        require(selected.isNotEmpty()) { "The frame range holds no frames" }
        return selected
    }

    /**
     * Delivers frames in index order: a frame waits until every frame before
     * it was delivered or given up on. One decoded frame can stand for several
     * indices (a frame the decoder skipped resolves to its neighbour); it is
     * delivered once, at the first of them.
     */
    private class Reorderer(
        private val count: Int,
        private val deliver: (index: Int, payload: LumaPayload) -> Unit,
    ) {
        /** Index -> its frame, or null for an index resolved by another one. */
        private val pending = TreeMap<Int, LumaPayload?>()
        private var next = 0

        @Synchronized
        fun add(indices: List<Int>, payload: LumaPayload) {
            val sorted = indices.sorted()
            pending[sorted.first()] = payload
            for (index in sorted.drop(1)) pending[index] = null
            drain()
        }

        /** Delivers what is left once extraction ended, skipping lost frames. */
        @Synchronized
        fun flush() {
            while (next < count) {
                pending.remove(next)?.let { deliver(next, it) }
                next++
            }
        }

        private fun drain() {
            while (pending.containsKey(next)) {
                pending.remove(next)?.let { deliver(next, it) }
                next++
            }
        }
    }
}
