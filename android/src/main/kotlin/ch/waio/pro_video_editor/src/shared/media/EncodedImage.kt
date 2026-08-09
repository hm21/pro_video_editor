package ch.waio.pro_video_editor.src.shared.media

import java.io.File
import java.io.InputStream

/**
 * Where a caller-supplied encoded image keeps its bytes.
 *
 * Bytes that arrive over the method channel are already in the managed heap and
 * stay there; a file is opened on demand and only the decoded bitmap is held.
 * A stop-motion sequence is the case that makes the difference matter — a few
 * hundred phone photos handed over as bytes at once exceed the heap's growth
 * limit long before any of them is decoded.
 */
sealed class EncodedImage {

    /** Encoded bytes already held in memory. */
    class OfBytes(val data: ByteArray) : EncodedImage()

    /** An encoded image on disk, read only while it is being decoded. */
    class OfFile(val file: File) : EncodedImage()

    /**
     * Opens the encoded bytes for reading. The caller closes the stream.
     */
    internal fun openStream(): InputStream = when (this) {
        is OfBytes -> data.inputStream()
        is OfFile -> file.inputStream()
    }
}
