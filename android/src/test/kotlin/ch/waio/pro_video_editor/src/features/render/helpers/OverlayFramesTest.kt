package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertEquals

internal class OverlayFramesTest {

    /** Frames named by index, recording what was decoded and released. */
    private class Recorder(private val broken: Set<Int> = emptySet()) {
        val decoded = mutableListOf<Int>()
        val released = mutableListOf<String>()

        fun frames(count: Int) = OnDemandFrames(
            count = count,
            first = "frame 0",
            decode = { index ->
                decoded += index
                if (index in broken) null else "frame $index"
            },
            release = { released += it },
        )
    }

    @Test
    fun onDemandFrames_decodeEachFrameOnceAsItComesOnScreen() {
        val recorder = Recorder()
        val frames = recorder.frames(4)

        // A render asks for every video frame, several per overlay frame.
        val shown = listOf(0, 0, 1, 1, 1, 2, 3, 3).map { frames.frameAt(it) }

        assertEquals(
            listOf(
                "frame 0", "frame 0", "frame 1", "frame 1",
                "frame 1", "frame 2", "frame 3", "frame 3",
            ),
            shown,
        )
        assertEquals(listOf(1, 2, 3), recorder.decoded)
    }

    @Test
    fun onDemandFrames_holdOnlyTheFrameOnScreen() {
        val recorder = Recorder()
        val frames = recorder.frames(3)

        frames.frameAt(1)
        frames.frameAt(2)

        assertEquals(listOf("frame 0", "frame 1"), recorder.released)
    }

    @Test
    fun onDemandFrames_keepTheFrameBeforeOneThatDoesNotDecode() {
        val recorder = Recorder(broken = setOf(2))
        val frames = recorder.frames(4)

        frames.frameAt(1)
        val broken = (0 until 3).map { frames.frameAt(2) }
        val after = frames.frameAt(3)

        assertEquals(List(3) { "frame 1" }, broken)
        assertEquals("frame 3", after)
        // Tried once, not on every video frame it covers.
        assertEquals(listOf(1, 2, 3), recorder.decoded)
        assertEquals(listOf("frame 0", "frame 1"), recorder.released)
    }

    @Test
    fun onDemandFrames_decodeTheFirstFrameAgainWhenALoopComesBack() {
        val recorder = Recorder()
        val frames = recorder.frames(2)

        frames.frameAt(1)
        val again = frames.frameAt(0)

        assertEquals("frame 0", again)
        assertEquals(listOf(1, 0), recorder.decoded)
    }

    @Test
    fun decodedFrames_returnTheFramesTheyWereGiven() {
        val frames = DecodedFrames(listOf("a", "b"))

        assertEquals(2, frames.count)
        assertEquals("b", frames.frameAt(1))
        assertEquals("a", frames.frameAt(0))
    }
}
