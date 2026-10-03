package ch.waio.pro_video_editor.src.shared.media

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.core.net.toUri
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap

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
     * deleted first, but never one that a call in flight reads (see
     * [acquire]).
     */
    private const val MAX_COPIES = 4

    /** Content URIs already checked and found seekable. */
    private val seekable = ConcurrentHashMap.newKeySet<String>()

    /** Copies of stream-only URIs, in access order. Guarded by itself. */
    private val copies = LinkedHashMap<String, File>(MAX_COPIES, 0.75f, true)

    /** How many calls in flight read each content URI. Guarded by [copies]. */
    private val inUse = HashMap<String, Int>()

    /** Guarded by this object. */
    private var clearedStaleCopies = false

    /** The local copy [path] is read from, or null when it is read in place. */
    fun copyOf(path: String): File? {
        if (!path.isContentUri()) return null
        return synchronized(copies) { copies[path]?.takeIf { it.exists() } }
    }

    /** Whether [path] is a content URI that [prepare] has not handled yet. */
    fun needsCheck(path: String): Boolean =
        path.isContentUri() && path !in seekable && copyOf(path) == null

    /**
     * Marks [paths] as read by a call in flight, so their copies are not
     * deleted until [release] is called with the same paths.
     */
    fun acquire(paths: Collection<String>) = synchronized(copies) {
        for (path in paths) inUse[path] = (inUse[path] ?: 0) + 1
    }

    /** Ends one [acquire] of [paths]. */
    fun release(paths: Collection<String>) = synchronized(copies) {
        for (path in paths) {
            val count = (inUse[path] ?: continue) - 1
            if (count > 0) inUse[path] = count else inUse.remove(path)
        }
    }

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
                if (path in inUse) continue
                copy.delete()
                iterator.remove()
            }
        }
    }

    /**
     * Deletes copies a previous process left behind. Blocks while deleting,
     * so it must run off the main thread.
     */
    fun clearStaleCopies(context: Context) {
        copyDir(context)
    }

    /**
     * The directory copies are written to. The first call per process deletes
     * the copies an earlier process left behind, before this process writes
     * any, so a second engine never deletes the copies of the first one.
     */
    private fun copyDir(context: Context): File = synchronized(this) {
        val dir = File(context.cacheDir, COPY_DIR)
        if (!clearedStaleCopies) {
            clearedStaleCopies = true
            dir.listFiles()?.forEach { it.delete() }
        }
        dir.apply { mkdirs() }
    }

    private fun prepareOne(context: Context, path: String) {
        val afd = try {
            context.contentResolver.openAssetFileDescriptor(path.toUri(), "r")
        } catch (e: Exception) {
            null
        } ?: return // Unreadable: the feature opens it again and reports the error.

        afd.use {
            val streamOnly = try {
                !OsConstants.S_ISREG(Os.fstat(afd.fileDescriptor).st_mode)
            } catch (e: ErrnoException) {
                return
            }
            if (!streamOnly) {
                seekable.add(path)
                return
            }

            // Copied from the stream opened for the check, so the provider
            // does not have to serve the source a second time.
            val copy = try {
                afd.createInputStream().use { input ->
                    writeMediaFile(
                        context, path, input,
                        File(copyDir(context), "${System.nanoTime()}").path
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not copy the stream-only source $path: ${e.message}")
                return
            }
            Log.d(TAG, "Copied the stream-only source $path (${copy.length()} bytes)")

            synchronized(copies) { copies.put(path, copy)?.delete() }
        }
    }
}
