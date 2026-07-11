package ch.waio.pro_video_editor.src.shared.concurrency

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide gate that serializes hardware-encoder-heavy exports across the
 * split and render pipelines so a second concurrent Media3 [androidx.media3
 * .transformer.Transformer] can't wedge at `progress == 0` while the device's
 * limited [android.media.MediaCodec] encoder pool is exhausted (the reported
 * split "freeze"). It mirrors the Darwin `ExportGate`.
 *
 * Unlike a lock this **never blocks a thread**: both pipelines drive their
 * `Transformer` on the main [android.os.Looper], so a blocking acquire would
 * deadlock the UI thread. Instead a caller enqueues an [onGranted] action and is
 * called back — on the thread that frees the slot, i.e. the main Looper for both
 * pipelines — when a slot is available. The wait therefore happens *before* a
 * job arms its stall watchdog, so queueing never counts as a stall.
 *
 * Contract: every [onGranted] that runs must be paired with exactly one
 * [release]. Cancellation while still queued is handled by the caller (it checks
 * its own finished flag inside [onGranted] and releases immediately), so a
 * cancelled job that later reaches the head of the queue takes one turn and
 * hands the slot straight on — the gate itself needs no cancellation support.
 *
 * **Threading contract:** [acquire]/[release] must be called on the main
 * [android.os.Looper], because [release] runs the next waiter's [onGranted]
 * synchronously on the calling thread and that callback drives a Media3
 * `Transformer` (which requires its Looper). This holds throughout the plugin:
 * every export terminal runs on the main Looper (Media3 listeners, the progress
 * poll loop; the split's off-thread diagnostics probe posts delivery back), and
 * cancellation arrives via the MethodChannel handler, which is the main thread.
 * The gate stays framework-agnostic (no `Handler`) so it remains JVM-unit-
 * testable; the main-Looper guarantee is the caller's responsibility.
 */
object ExportGate {
    private val lock = Any()
    private var busy = false
    private val waiters = ArrayDeque<() -> Unit>()

    /**
     * Acquires a slot. Runs [onGranted] synchronously (on the calling thread) if
     * the gate is free, otherwise queues it FIFO to run when a slot is released.
     */
    fun acquire(onGranted: () -> Unit) {
        val runNow: Boolean
        synchronized(lock) {
            if (!busy) {
                busy = true
                runNow = true
            } else {
                waiters.addLast(onGranted)
                runNow = false
            }
        }
        // Invoke outside the lock so the granted body can itself call release()
        // (e.g. a job cancelled while queued) without re-entering under the lock.
        if (runNow) onGranted()
    }

    /**
     * Releases the held slot: hands it directly to the next waiter (FIFO) or, if
     * none is queued, marks the gate idle. Must be called exactly once per
     * granted slot.
     */
    fun release() {
        val next: (() -> Unit)?
        synchronized(lock) {
            next = if (waiters.isEmpty()) null else waiters.removeFirst()
            if (next == null) busy = false
            // else: the slot stays busy, handed straight to `next`.
        }
        next?.invoke()
    }
}

/**
 * Per-job helper that pairs a single [ExportGate] slot with idempotent release.
 *
 * A job acquires the shared gate, calls [markHeld] from its granted callback,
 * and calls [release] from *every* terminal path (success, error, stall,
 * cancel). The slot is returned exactly once, and only if it was ever actually
 * held — so a job cancelled while still queued (which never called [markHeld])
 * releases nothing, and its queued waiter simply takes one turn and hands the
 * slot on when it later reaches the head.
 *
 * All calls happen on the main [android.os.Looper], so the flags need no
 * ordering beyond their own atomicity.
 */
class ExportGateGuard {
    private val held = AtomicBoolean(false)
    private val released = AtomicBoolean(false)

    /** Marks that the shared slot was granted to this job. */
    fun markHeld() {
        held.set(true)
    }

    /** Releases the slot once, iff it was held and not yet released. */
    fun release() {
        if (held.get() && released.compareAndSet(false, true)) ExportGate.release()
    }
}
