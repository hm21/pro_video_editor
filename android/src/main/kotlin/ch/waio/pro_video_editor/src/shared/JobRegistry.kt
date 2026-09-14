package ch.waio.pro_video_editor.src.shared

/**
 * The jobs of one kind the plugin is tracking, by id.
 *
 * A cancel answers at once and frees the id, but the pipeline behind the job
 * may still be unwinding — an extraction thread notices its stop flag on its
 * own time — and on its way out it may still delete the output it was
 * writing. A job started under that id in the meantime (a retry, at the same
 * path) would find its own output deleted from under it. So a job whose
 * predecessor is still unwinding is registered — the id is taken, its call
 * pending — but its pipeline starts only once the predecessor has reported
 * back.
 *
 * That holds only as long as every pipeline reports its end after a cancel —
 * Media3's `Transformer.cancel()` is listener-silent, so a pipeline built on
 * it has to say so itself once its teardown is through. One that stays quiet
 * keeps the id's next start waiting for good.
 *
 * Everything here runs on the main thread, like every other access to the
 * task maps. [cancelJob] is what cancelling one job of this kind means.
 */
class JobRegistry<T : Any>(private val cancelJob: (T) -> Unit) {
    /** Jobs that answer to `cancelTask`, by id. */
    private val active = HashMap<String, T>()

    /** Cancelled jobs whose pipeline has yet to report, by the id they held. */
    private val unwinding = HashMap<String, T>()

    /** Pipeline starts held back behind an unwinding job, by id. */
    private val pending = HashMap<String, () -> Unit>()

    /** Whether a job holds [id]. */
    fun isRunning(id: String): Boolean = active.containsKey(id)

    /**
     * Registers [job] under [id] and runs [start] — now, or once the job
     * cancelled under the same id has finished unwinding.
     */
    fun start(id: String, job: T, start: () -> Unit) {
        active[id] = job
        if (unwinding.containsKey(id)) {
            pending[id] = start
        } else {
            start()
        }
    }

    /**
     * Cancels the job under [id] and frees the id, returning the job so the
     * caller can answer it. A job that never started is simply dropped; one
     * that did keeps the id's next start waiting until its pipeline reports.
     */
    fun cancel(id: String): T? {
        val job = active.remove(id) ?: return null
        cancelJob(job)
        if (pending.remove(id) == null) {
            unwinding[id] = job
        }
        return job
    }

    /**
     * Records that [job]'s pipeline has reported. Returns the job when it
     * still held [id], now freed; null when it was cancelled — the cancel has
     * already answered its call — in which case the start waiting behind it,
     * if any, runs now.
     */
    fun settle(id: String, job: T): T? {
        if (active[id] === job) {
            active.remove(id)
            return job
        }
        if (unwinding[id] === job) {
            unwinding.remove(id)
            pending.remove(id)?.invoke()
        }
        return null
    }
}
