package ch.waio.pro_video_editor.video

import android.content.Context
import android.media.MediaMetadataRetriever
import android.os.Environment
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

class VideoProcessor(private val context: Context) {

    fun processVideo(videoData: ByteArray): Map<String, Any> {
        val tempFile = createTempFile(videoData, "tmp")
            ?: return mapOf("error" to "Failed to create temp file")

        val fileSize = tempFile.length()
        val metadataRetriever = MediaMetadataRetriever()

        var durationMs = 0.0
        var width = 0
        var height = 0
        var mimeType = "unknown"

        try {
            metadataRetriever.setDataSource(tempFile.absolutePath)

            mimeType =
                metadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                    ?: "unknown"

            val durationStr =
                metadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            durationMs = durationStr?.toDoubleOrNull() ?: 0.0

            val widthStr =
                metadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            width = widthStr?.toIntOrNull() ?: 0

            val heightStr =
                metadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            height = heightStr?.toIntOrNull() ?: 0

        } catch (e: Exception) {
            return mapOf("error" to "Failed to retrieve metadata: ${e.message}")
        } finally {
            metadataRetriever.release()
        }

        return mapOf(
            "fileSize" to fileSize,
            "duration" to durationMs,
            "format" to mimeType.substringAfter("/"),
            "width" to width,
            "height" to height
        )
    }

    private fun createTempFile(videoData: ByteArray, extension: String): File? {
        return try {
            val tempDir = context.getExternalFilesDir(Environment.DIRECTORY_MOVIES)
            val tempFile = File.createTempFile("vid", ".$extension", tempDir)
            FileOutputStream(tempFile).use { it.write(videoData) }
            tempFile
        } catch (e: IOException) {
            null
        }
    }

    @Suppress("unused")
    private fun getExtensionFromMimeType(mimeType: String): String {
        return when (mimeType) {
            "video/mp4" -> "mp4"
            "video/webm" -> "webm"
            "video/3gpp" -> "3gp"
            "video/quicktime" -> "mov"
            "video/x-msvideo" -> "avi"
            "video/x-matroska" -> "mkv"
            "video/x-ms-wmv" -> "wmv"
            "video/x-flv" -> "flv"
            "video/mpeg" -> "mpg"
            else -> "mp4"
        }
    }
}
