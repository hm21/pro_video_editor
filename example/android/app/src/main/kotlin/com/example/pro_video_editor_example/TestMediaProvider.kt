package com.example.pro_video_editor_example

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Used by integration_test/content_uri_test.dart only: serves files from the
 * app's cache directory under content URIs of a provider other than
 * MediaStore, the way a document or cloud provider does.
 *
 * - `content://<authority>/file/<name>` opens the file itself, so it is
 *   seekable.
 * - `content://<authority>/pipe/<name>` streams it through a pipe, which
 *   cannot be seeked, like some cloud providers return for remote files.
 */
class TestMediaProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File {
        val segments = uri.pathSegments
        if (segments.size != 2) throw FileNotFoundException("Unknown URI $uri")
        val dir = context!!.cacheDir
        val file = File(dir, segments[1])
        if (file.parentFile != dir || !file.isFile) {
            throw FileNotFoundException("No file for $uri")
        }
        return file
    }

    override fun getType(uri: Uri): String? {
        val extension = uri.lastPathSegment?.substringAfterLast('.', "") ?: return null
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val file = fileFor(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        }
        return MatrixCursor(columns, 1).apply { addRow(row) }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = fileFor(uri)
        if (uri.pathSegments[0] != "pipe") {
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        val (read, write) = ParcelFileDescriptor.createReliablePipe()
        Thread {
            ParcelFileDescriptor.AutoCloseOutputStream(write).use { output ->
                try {
                    file.inputStream().use { it.copyTo(output) }
                } catch (_: IOException) {
                    // The reader closed the pipe early.
                }
            }
        }.start()
        return read
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
