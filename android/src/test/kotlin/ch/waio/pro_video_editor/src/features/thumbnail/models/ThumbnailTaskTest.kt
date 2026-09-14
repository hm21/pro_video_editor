package ch.waio.pro_video_editor.src.features.thumbnail.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class ThumbnailTaskTest {

    @Test
    fun cancel_invokesAttachedHandleOnce() {
        var cancels = 0
        val task = ThumbnailTask()
        task.attach(ThumbnailJobHandle { cancels++ })

        task.cancel()

        assertTrue(task.isCanceled)
        assertEquals(1, cancels)
    }

    @Test
    fun cancelBeforeAttach_cancelsTheHandleWhenItLands() {
        var cancels = 0
        val task = ThumbnailTask()

        task.cancel()
        assertEquals(0, cancels)

        task.attach(ThumbnailJobHandle { cancels++ })
        assertEquals(1, cancels)
    }

    @Test
    fun attachWithoutCancel_leavesTheHandleAlone() {
        var cancels = 0
        val task = ThumbnailTask()

        task.attach(ThumbnailJobHandle { cancels++ })

        assertFalse(task.isCanceled)
        assertEquals(0, cancels)
    }
}
