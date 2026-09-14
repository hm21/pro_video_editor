package ch.waio.pro_video_editor.src.shared

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

internal class JobRegistryTest {
    private class Job {
        var canceled = false
    }

    private val started = mutableListOf<String>()
    private val registry = JobRegistry<Job> { it.canceled = true }

    // A cancel answers at once, but the pipeline behind the cancelled job is
    // still unwinding and may yet delete the output it was writing. A job
    // restarted under the same id must not run into that.
    @Test
    fun aJobRestartedUnderACancelledId_waitsForItsPredecessorToUnwind() {
        val first = Job()
        registry.start("x", first) { started += "first" }
        assertEquals(listOf("first"), started)

        assertSame(first, registry.cancel("x"))
        assertTrue(first.canceled)
        assertFalse(registry.isRunning("x"), "the cancel frees the id at once")

        val second = Job()
        registry.start("x", second) { started += "second" }
        assertTrue(registry.isRunning("x"))
        assertEquals(listOf("first"), started, "the restart waits for the cancelled pipeline")

        assertNull(registry.settle("x", first), "the cancel has already answered the first job")
        assertEquals(listOf("first", "second"), started)
        assertTrue(registry.isRunning("x"), "the cancelled job's report leaves the restart alone")

        assertNull(registry.settle("x", first))
        assertEquals(listOf("first", "second"), started, "a duplicate report starts nothing twice")

        assertSame(second, registry.settle("x", second))
        assertFalse(registry.isRunning("x"))
    }

    @Test
    fun aJobCancelledWhileWaiting_neverStartsAndDoesNotBlockTheNext() {
        val first = Job()
        registry.start("x", first) { started += "first" }
        registry.cancel("x")

        val second = Job()
        registry.start("x", second) { started += "second" }
        assertSame(second, registry.cancel("x"))
        assertTrue(second.canceled)

        val third = Job()
        registry.start("x", third) { started += "third" }
        assertEquals(listOf("first"), started, "the first job is still unwinding")

        registry.settle("x", first)
        assertEquals(listOf("first", "third"), started, "the cancelled second job never starts")
    }

    @Test
    fun aJobThatWasNeverCancelled_settlesAsItself() {
        val job = Job()
        registry.start("x", job) { started += "job" }

        assertSame(job, registry.settle("x", job))
        assertFalse(registry.isRunning("x"))
        assertNull(registry.cancel("x"))
    }
}
