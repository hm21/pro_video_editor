package ch.waio.pro_video_editor.src.features.render.utils

import android.content.Context
import android.media.MediaMetadataRetriever
import ch.waio.pro_video_editor.src.shared.media.contentDataSource

/**
 * Calculates the actual display dimensions of a video after rotation is applied.
 *
 * This function extracts the video's raw dimensions and rotation metadata, then
 * applies an additional rotation transformation to determine the final width and height.
 * This is crucial for correctly handling videos that need rotation correction or
 * user-applied rotation effects.
 *
 * The function accounts for the fact that 90° and 270° rotations swap width and height,
 * while 0° and 180° rotations maintain the original aspect ratio.
 *
 * Example:
 * - Original video: 1920x1080 (landscape)
 * - File rotation: 0°
 * - Applied rotation: 90°
 * - Result: 1080x1920 (portrait)
 *
 * @param path The path to video file to analyze
 * @param rotationDegrees Additional rotation to apply (in degrees, typically 0, 90, 180, or 270)
 * @return Triple containing (width, height, normalizedRotation)
 *         - width: Final display width after rotation
 *         - height: Final display height after rotation
 *         - normalizedRotation: Combined rotation value (file rotation + applied rotation) mod 360
 *         Returns (0, 0, 0) if metadata extraction fails
 */
fun getRotatedVideoDimensions(
    context: Context,
    path: String,
    rotationDegrees: Float
): Triple<Int, Int, Int> {
    val retriever = MediaMetadataRetriever()
    return try {
        retriever.contentDataSource(context, path)

        // Extract raw video dimensions from file metadata
        val widthRaw =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
        val heightRaw =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0

        // Get the video's embedded rotation metadata (0, 90, 180, or 270)
        val rotation =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0

        // Combine file rotation with additional applied rotation
        val normalizedRotation = (rotation + rotationDegrees.toInt()) % 360

        // Swap dimensions if rotation is 90° or 270°
        val (width, height) = if (normalizedRotation == 90 || normalizedRotation == 270) {
            heightRaw to widthRaw  // Portrait orientation
        } else {
            widthRaw to heightRaw  // Landscape orientation
        }

        Triple(width, height, normalizedRotation)
    } catch (e: Exception) {
        Triple(0, 0, 0)
    } finally {
        retriever.release()
    }
}
