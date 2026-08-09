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
    class OfBytes(val data: ByteArray) : EncodedImage() {
        // Structural, so the configs holding an EncodedImage can stay plain
        // data classes instead of hand-writing equals around a ByteArray.
        override fun equals(other: Any?): Boolean =
            this === other || (other is OfBytes && data.contentEquals(other.data))

        override fun hashCode(): Int = data.contentHashCode()
    }

    /** An encoded image on disk, read only while it is being decoded. */
    class OfFile(val file: File) : EncodedImage() {
        override fun equals(other: Any?): Boolean =
            this === other || (other is OfFile && file == other.file)

        override fun hashCode(): Int = file.hashCode()
    }

    /**
     * Opens the encoded bytes for reading. The caller closes the stream.
     */
    internal fun openStream(): InputStream = when (this) {
        is OfBytes -> data.inputStream()
        is OfFile -> file.inputStream()
    }

    /**
     * The whole encoded image as one array, read from disk when it is a file,
     * or null when the file cannot be read.
     *
     * Only for a consumer that genuinely needs the encoded bytes in one piece —
     * an animated GIF, whose frames are decoded as a set. Anything that just
     * wants pixels goes through `ImageOrientation` instead and lets the decoder
     * stream the file, which is the whole point of holding a path.
     */
    internal fun readBytes(): ByteArray? = when (this) {
        is OfBytes -> data
        is OfFile -> runCatching { file.readBytes() }.getOrNull()
    }

    /**
     * The first [count] encoded bytes — enough to sniff a format without
     * reading a whole file. Shorter when the image is, null when it cannot be
     * read at all.
     */
    internal fun readHeader(count: Int): ByteArray? = runCatching {
        openStream().use { stream ->
            val buffer = ByteArray(count)
            var read = 0
            while (read < count) {
                val n = stream.read(buffer, read, count - read)
                if (n < 0) break
                read += n
            }
            if (read == count) buffer else buffer.copyOf(read)
        }
    }.getOrNull()

    /** Names this source for a log line or an error message. */
    internal fun describe(): String = when (this) {
        is OfBytes -> "${data.size} bytes"
        is OfFile -> file.absolutePath
    }

    companion object {
        /**
         * Reads an image source out of a channel map, preferring the on-disk
         * path Dart sends for a file-backed image over inline bytes.
         *
         * Returns null when the map carries neither, which every caller reads
         * as "no image here".
         */
        fun fromMap(
            map: Map<String, Any?>,
            pathKey: String,
            dataKey: String,
        ): EncodedImage? {
            val path = (map[pathKey] as? String)?.takeIf { it.isNotBlank() }
            if (path != null) return OfFile(File(path))

            val data = (map[dataKey] as? ByteArray)?.takeIf { it.isNotEmpty() }
            return data?.let { OfBytes(it) }
        }
    }
}
