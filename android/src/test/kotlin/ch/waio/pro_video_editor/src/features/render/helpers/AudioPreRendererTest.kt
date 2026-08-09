package ch.waio.pro_video_editor.src.features.render.helpers

import java.io.File
import java.io.RandomAccessFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the byte accounting of the WAV body writer.
 *
 * The decoded source is spooled to a scratch file rather than held as one byte
 * array — a three-minute stereo track is ~30 MB of PCM, which is a large share
 * of Android's managed-heap limit during an export. The writer therefore streams
 * that file, replaying it for a looping track, and *reports* how much it wrote:
 * the WAV header declares exactly that number, and a header that disagrees with
 * the body by even one frame makes the file unreadable.
 *
 * Scope: a JVM unit test over plain file I/O. Decoding itself needs `MediaCodec`
 * and is covered on-device by the example integration tests.
 */
internal class AudioPreRendererTest {

    /** 16-bit stereo, i.e. one frame is four bytes. */
    private val bytesPerFrame = 4

    @Test
    fun aSourceShorterThanTheBodyPlaysOnceWhenNotLooping() {
        val source = pcmFile(size = 100)
        val (written, output) = writeBody(source, targetBytes = 400, loop = false)

        assertEquals(100L, written)
        assertEquals(100L, output.length())
    }

    @Test
    fun aLoopingSourceRepeatsUntilTheBodyIsCovered() {
        val source = pcmFile(size = 100)
        val (written, output) = writeBody(source, targetBytes = 250, loop = true)

        // 250 is not a whole number of frames; the body stops on the last one.
        assertEquals(248L, written)
        assertEquals(248L, output.length())

        // The replay starts the source over rather than continuing past its end.
        val bytes = output.readBytes()
        assertEquals(bytes[0], bytes[100])
        assertEquals(bytes[99], bytes[199])
    }

    @Test
    fun aSourceLongerThanTheBodyIsCutOnAFrameBoundary() {
        val source = pcmFile(size = 1000)
        val (written, _) = writeBody(source, targetBytes = 250, loop = true)

        assertEquals(248L, written)
    }

    /**
     * A source that yields nothing would spin forever in the replay loop if the
     * writer only watched the byte count.
     */
    @Test
    fun anEmptySourceWritesNothingInsteadOfLoopingForever() {
        val source = pcmFile(size = 0)
        val (written, output) = writeBody(source, targetBytes = 400, loop = true)

        assertEquals(0L, written)
        assertEquals(0L, output.length())
    }

    @Test
    fun aBodyOfZeroLengthWritesNothing() {
        val source = pcmFile(size = 100)
        val (written, _) = writeBody(source, targetBytes = 0, loop = true)

        assertEquals(0L, written)
    }

    /** A scratch PCM file of [size] bytes, each one distinct within a frame. */
    private fun pcmFile(size: Int): File {
        val file = File.createTempFile("prerender_pcm", ".raw")
        file.deleteOnExit()
        file.writeBytes(ByteArray(size) { (it % 251).toByte() })
        return file
    }

    private fun writeBody(
        source: File,
        targetBytes: Long,
        loop: Boolean,
    ): Pair<Long, File> {
        val output = File.createTempFile("prerender_body", ".wav")
        output.deleteOnExit()
        val written = RandomAccessFile(output, "rw").use { raf ->
            AudioPreRenderer.writeAudioBody(
                raf = raf,
                sourcePcm = source,
                targetBytes = targetBytes,
                loop = loop,
                bytesPerFrame = bytesPerFrame,
            )
        }
        assertTrue(output.exists())
        return written to output
    }
}
