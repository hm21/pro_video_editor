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

    /**
     * `render` documents that a non-looping track "plays once and any remaining
     * composition time is filled with silence". Returning only the audio would
     * end the WAV early and finish the export short of the video.
     */
    @Test
    fun aSourceShorterThanTheBodyPlaysOnceThenGoesSilent() {
        val source = pcmFile(size = 100)
        val (written, output) = writeBody(source, targetBytes = 400, loop = false)

        assertEquals(400L, written)
        assertEquals(400L, output.length())

        val bytes = output.readBytes()
        assertEquals(0, bytes[99].compareTo((99 % 251).toByte()))
        assertTrue(
            bytes.drop(100).all { it == 0.toByte() },
            "the uncovered tail of the body must be silence",
        )
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
     * writer only watched the byte count. It still owes the body its full
     * length, so the slot comes out silent rather than missing.
     */
    @Test
    fun anEmptySourceGoesSilentInsteadOfLoopingForever() {
        val source = pcmFile(size = 0)
        val (written, output) = writeBody(source, targetBytes = 400, loop = true)

        assertEquals(400L, written)
        assertTrue(output.readBytes().all { it == 0.toByte() })
    }

    @Test
    fun aBodyOfZeroLengthWritesNothing() {
        val source = pcmFile(size = 100)
        val (written, _) = writeBody(source, targetBytes = 0, loop = true)

        assertEquals(0L, written)
    }

    /**
     * RIFF sizes are *unsigned* 32-bit. Clamping the data size at
     * [Int.MAX_VALUE] — half the format's range — let `36 + dataSize` wrap into
     * a negative number and write a size no reader accepts, which is the
     * corrupt-file case the measured byte count exists to prevent. About 3.4 h
     * of 48 kHz 16-bit stereo reaches it.
     */
    @Test
    fun theHeaderSizesNeverWrapNegative() {
        val atSignedLimit = updateSizes(dataSize = Int.MAX_VALUE.toLong())
        assertEquals(2_147_483_683L, readUInt32(atSignedLimit, 4))
        assertEquals(2_147_483_647L, readUInt32(atSignedLimit, 40))

        // Past the format's own ceiling both fields saturate, as WavFileWriter
        // does, rather than truncating to something smaller than the body.
        val pastRiffLimit = updateSizes(dataSize = 0x1_0000_0000L)
        assertEquals(0xFFFF_FFFFL, readUInt32(pastRiffLimit, 4))
        assertEquals(0xFFFF_FFFFL, readUInt32(pastRiffLimit, 40))
    }

    /** The 44-byte header after [AudioPreRenderer.updateWavSizes]. */
    private fun updateSizes(dataSize: Long): ByteArray {
        val output = File.createTempFile("prerender_header", ".wav")
        output.deleteOnExit()
        RandomAccessFile(output, "rw").use { raf ->
            raf.setLength(44)
            AudioPreRenderer.updateWavSizes(raf, dataSize)
        }
        return output.readBytes()
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 0 until 4) {
            value = value or ((bytes[offset + i].toLong() and 0xFF) shl (8 * i))
        }
        return value
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
