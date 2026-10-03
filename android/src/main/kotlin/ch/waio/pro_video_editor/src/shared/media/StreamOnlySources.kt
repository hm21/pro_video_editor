package ch.waio.pro_video_editor.src.shared.media

import android.content.Context
import android.system.Os
import android.system.OsConstants
import androidx.core.net.toUri
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Local copies of content URIs whose provider only hands out a stream that
 * cannot be seeked, such as a pipe. Some cloud and archive providers do that.
 * MediaExtractor and MediaMetadataRetriever need random access, so such a
 * source is copied once into the cache, and every later open reads the copy.
 *
 * [prepare] checks and copies off the main thread before a method call is
 * dispatched. The openers in DataSourceExt only look the copy up, so they
 * never copy on the thread that calls them.
 */
object StreamOnlySources {
    private const val TAG = "StreamOnlySources"
    private const val COPY_DIR = "pro_video_editor_stream_sources"

    /**
     * Copies kept once a call is prepared; the least recently used ones are
     * deleted first, but never one the call itself reads.
     */
    private const val MAX_COPIES = 4

    /** Content URIs already checked and found seekable. */
    private val seekable = ConcurrentHashMap.newKeySet<String>()

    /** Copies of stream-only URIs, in access order. Guarded by itself. */
    private val copies = LinkedHashMap<String, File>(MAX_COPIES, 0.75f, true)

    private val clearedStaleCopies = AtomicBoolean(false)

    /** The local copy [path] is read from, or null when it is read in place. */
    fun copyOf(path: String): File? {
        if (!path.isContentUri()) return null
        return synchronized(copies) { copies[path]?.takeIf { it.exists() } }
    }

    /** Whether [path] is a content URI that [prepare] has not handled yet. */
    fun needsCheck(path: String): Boolean =
        path.isContentUri() && path !in seekable && copyOf(path) == null

    /**
     * Checks every content URI in [paths] and copies the stream-only ones.
     * Blocks while copying, so it must run off the main thread.
     */
    fun prepare(context: Context, paths: Collection<String>) {
        for (path in paths) {
            if (needsCheck(path)) prepareOne(context, path)
        }
        synchronized(copies) {
            val iterator = copies.entries.iterator()
            while (copies.size > MAX_COPIES && iterator.hasNext()) {
                val (path, copy) = iterator.next()
                if (path in paths) continue
                copy.delete()
                iterator.remove()
            }
        }
    }

    /**
     * Deletes copies a previous process left behind. Runs once per process,
     * so a second engine does not delete the copies the first one uses.
     */
    fun clearStaleCopies(context: Context) {
        if (!clearedStaleCopies.compareAndSet(false, true)) return
        File(context.cacheDir, COPY_DIR).listFiles()?.forEach { it.delete() }
    }

    private fun prepareOne(context: Context, path: String) {
        val streamOnly = try {
            context.contentResolver.openAssetFileDescriptor(path.toUri(), "r")?.use { afd ->
                !OsConstants.S_ISREG(Os.fstat(afd.fileDescriptor).st_mode)
            }
        } catch (e: Exception) {
            // Unreadable: the feature opens it again and reports the error.
            null
        } ?: return

        if (!streamOnly) {
            seekable.add(path)
            return
        }

        val dir = File(context.cacheDir, COPY_DIR).apply { mkdirs() }
        val copy = try {
            copyContentToFile(context, path, File(dir, "${System.nanoTime()}").path)
        } catch (e: Exception) {
            Log.w(TAG, "Could not copy the stream-only source $path: ${e.message}")
            return
        }
        Log.d(TAG, "Copied the stream-only source $path (${copy.length()} bytes)")

        synchronized(copies) { copies.put(path, copy)?.delete() }
    }
}
