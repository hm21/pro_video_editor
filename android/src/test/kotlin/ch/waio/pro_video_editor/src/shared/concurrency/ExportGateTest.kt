package ch.waio.pro_video_editor.src.shared.concurrency

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Deterministic single-thread coverage of the [ExportGate] serialization
 * primitive and its [ExportGateGuard] helper. The gate is only ever driven from
 * the main Looper in production, so these tests exercise it on one thread.
 */
internal class ExportGateTest {

    @AfterTest
    fun drainGate() {
        // Ensure a leaked slot from a failing test can't wedge the next one:
        // release a few times (release is a no-op once idle).
        repeat(4) { ExportGate.release() }
    }

    @Test
    fun firstAcquireRunsImmediately() {
        var ran = false
        ExportGate.acquire { ran = true }
        assertTrue(ran, "a free gate must run onGranted synchronously")
        ExportGate.release()
    }

    @Test
    fun secondAcquireQueuesUntilRelease() {
        val order = mutableListOf<String>()
        ExportGate.acquire { order.add("a") }      // granted now
        ExportGate.acquire { order.add("b") }      // queued
        assertEquals(listOf("a"), order, "b must wait until a releases")

        ExportGate.release()                        // hands slot to b
        assertEquals(listOf("a", "b"), order)
        ExportGate.release()
    }

    @Test
    fun waitersAreGrantedInFifoOrder() {
        val order = mutableListOf<Int>()
        ExportGate.acquire { order.add(0) }         // holder
        (1..3).forEach { i -> ExportGate.acquire { order.add(i) } }

        assertEquals(listOf(0), order)
        // Each release hands the slot to the next queued waiter, in order.
        ExportGate.release()
        ExportGate.release()
        ExportGate.release()
        assertEquals(listOf(0, 1, 2, 3), order)
        ExportGate.release()
    }

    @Test
    fun releaseWithoutWaitersMarksIdleAndNextRunsImmediately() {
        var first = false
        ExportGate.acquire { first = true }
        ExportGate.release()

        var second = false
        ExportGate.acquire { second = true }
        assertTrue(first && second, "an idle gate must grant the next acquire at once")
        ExportGate.release()
    }

    @Test
    fun guardReleasesExactlyOnceAndOnlyIfHeld() {
        // A guard that never held the slot must not release it.
        val neverHeld = ExportGateGuard()
        var ran = false
        ExportGate.acquire { ran = true }           // unrelated holder
        neverHeld.release()                          // no-op: not held
        assertTrue(ran)

        var queuedRan = false
        ExportGate.acquire { queuedRan = true }      // queued behind holder
        assertTrue(!queuedRan, "must still be queued (neverHeld.release did nothing)")

        ExportGate.release()                         // holder releases → queued runs
        assertTrue(queuedRan)
        ExportGate.release()
    }

    @Test
    fun guardDoubleReleaseFreesSlotOnlyOnce() {
        val guard = ExportGateGuard()
        ExportGate.acquire { guard.markHeld() }      // guard holds the only slot

        var laterRan = false
        ExportGate.acquire { laterRan = true }       // queued

        guard.release()                              // frees → laterRan
        assertTrue(laterRan)
        guard.release()                              // second release must be a no-op

        // If the double release had leaked an extra slot, this acquire would run
        // immediately even though `laterRan`'s holder never released.
        var shouldStayQueued = false
        ExportGate.acquire { shouldStayQueued = true }
        assertTrue(!shouldStayQueued, "double release must not leak an extra slot")

        ExportGate.release()                         // release laterRan's slot → queued runs
        assertTrue(shouldStayQueued)
        ExportGate.release()
    }
}
