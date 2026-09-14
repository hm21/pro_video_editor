package ch.waio.pro_video_editor.src.features.thumbnail.models

/**
 * Handle for cancelling an active streaming thumbnail job.
 *
 * @property cancel Function to invoke when cancellation is requested
 */
data class ThumbnailJobHandle(
    val cancel: () -> Unit
)

/**
 * Task wrapper for a streaming thumbnail job.
 *
 * Tracks the job state and provides thread-safe cancellation. A cancel that
 * arrives before the job handle is attached is remembered, so the handle is
 * cancelled the moment it lands.
 */
class ThumbnailTask {
    @Volatile
    var isCanceled: Boolean = false
        private set

    @Volatile
    private var job: ThumbnailJobHandle? = null

    /** Attaches the running job; cancels it right away if [cancel] already ran. */
    fun attach(handle: ThumbnailJobHandle) {
        job = handle
        if (isCanceled) handle.cancel()
    }

    /** Marks this task as canceled and invokes the job's cancel handler. */
    fun cancel() {
        isCanceled = true
        job?.cancel?.invoke()
    }
}
