package ch.waio.pro_video_editor.src.shared.media

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import java.io.File
import java.io.IOException
import java.io.InputStream

/*
 * Input paths handed over from Dart are either filesystem paths or Android
 * `content://` URIs (EditorVideo.content). These helpers open both kinds, so a
 * content URI is read in place through the ContentResolver instead of being
 * copied to a file first.
 */

/** Whether this input path is a `content://` URI rather than a filesystem path. */
fun String.isContentUri(): Boolean = startsWith("content://")

/**
 * Converts a path string (either a `content://` URI or a filesystem path) into an Android [Uri].
 * Content URIs are parsed directly, while filesystem paths are converted via [Uri.fromFile].
 */
fun String.toContentOrFileUri(): Uri =
    if (isContentUri()) toUri() else Uri.fromFile(File(this))

/**
 * Sets the URI on a [MediaItem.Builder] from a path string that can be either a `content://` URI
 * or a filesystem path.
 */
fun MediaItem.Builder.contentUri(path: String): MediaItem.Builder =
    setUri(path.toContentOrFileUri())

/**
 * Sets the data source on a [MediaExtractor] for either a content URI or a file path.
 */
@Throws(IOException::class)
fun MediaExtractor.contentDataSource(context: Context, path: String) {
    if (path.isContentUri()) {
        setDataSource(context, path.toUri(), null)
    } else {
        setDataSource(path)
    }
}

/**
 * Sets the data source on a [MediaMetadataRetriever] for either a content URI or a file path.
 */
@Throws(IllegalArgumentException::class, SecurityException::class)
fun MediaMetadataRetriever.contentDataSource(context: Context, path: String) {
    if (path.isContentUri()) {
        setDataSource(context, path.toUri())
    } else {
        setDataSource(path)
    }
}

/**
 * A [MediaExtractor] opened on [path] (file path or content URI). The
 * extractor is released again when opening fails, so a missing file or a
 * revoked URI permission does not leak a native extractor.
 */
@Throws(IOException::class)
fun openMediaExtractor(context: Context, path: String): MediaExtractor {
    val extractor = MediaExtractor()
    try {
        extractor.contentDataSource(context, path)
    } catch (e: Throwable) {
        extractor.release()
        throw e
    }
    return extractor
}

/**
 * Whether the media at [path] can be opened: the file exists, or the content
 * URI resolves and is readable by this app.
 */
fun mediaSourceExists(context: Context, path: String): Boolean {
    if (!path.isContentUri()) return File(path).exists()
    return try {
        context.contentResolver.openAssetFileDescriptor(path.toUri(), "r")
            ?.use { true } ?: false
    } catch (e: Exception) {
        false
    }
}

/**
 * Size in bytes of the media at [path] (file path or content URI), or 0 when
 * it cannot be determined.
 */
fun mediaSourceLength(context: Context, path: String): Long {
    if (!path.isContentUri()) return File(path).length()
    val uri = path.toUri()
    try {
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
            val length = if (afd.length != AssetFileDescriptor.UNKNOWN_LENGTH) {
                afd.length
            } else {
                afd.parcelFileDescriptor.statSize
            }
            if (length >= 0) return length
        }
    } catch (_: Exception) {
    }
    try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) {
                    return cursor.getLong(column).coerceAtLeast(0L)
                }
            }
    } catch (_: Exception) {
    }
    return 0L
}

/**
 * MIME type the provider reports for a content URI (e.g. `video/mp4`), or
 * null for a file path or when the provider does not know it.
 */
fun contentMimeType(context: Context, path: String): String? {
    if (!path.isContentUri()) return null
    return try {
        context.contentResolver.getType(path.toUri())
    } catch (e: Exception) {
        null
    }
}

/** Opens the media at [path] (file path or content URI) as a byte stream. */
@Throws(IOException::class)
fun openMediaInputStream(context: Context, path: String): InputStream {
    if (!path.isContentUri()) return File(path).inputStream()
    return context.contentResolver.openInputStream(path.toUri())
        ?: throw IOException("Cannot open $path")
}
