package ch.waio.pro_video_editor.src.features.stopmotion.models

import ch.waio.pro_video_editor.src.shared.media.EncodedImage
import io.flutter.plugin.common.MethodCall
import java.io.File

/**
 * Configuration for a single stop-motion frame.
 *
 * @property image The encoded image (PNG/JPEG/etc.) for this frame. A frame the
 *   caller has on disk arrives as a path and is opened when it is encoded; only
 *   an in-memory source travels as bytes.
 * @property durationUs How long this frame is held on screen, in microseconds.
 *   When `null`, the default frame duration (`1 / frameRate`) is used.
 */
class StopMotionFrameConfig(
    val image: EncodedImage,
    val durationUs: Long?,
)

/**
 * Configuration for rendering a stop-motion video from a sequence of images.
 */
data class StopMotionConfig(
    val id: String,
    val frames: List<StopMotionFrameConfig>,
    val frameRate: Double,
    val width: Int?,
    val height: Int?,
    val fit: String,
    val outputFormat: String,
    val outputPath: String?,
    val bitrate: Int?,
) {
    companion object {
        /**
         * Parses a [StopMotionConfig] from a Flutter [MethodCall].
         *
         * @throws IllegalArgumentException when required arguments are missing
         *   or no valid frames are provided.
         */
        fun fromMethodCall(call: MethodCall): StopMotionConfig {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("Missing task id")

            val rawFrames = call.argument<List<Map<String, Any?>>>("frames")
                ?: throw IllegalArgumentException("Missing frames")

            val frames = rawFrames.mapNotNull { map ->
                val image = parseImage(map) ?: return@mapNotNull null
                val durationUs = (map["durationUs"] as? Number)?.toLong()
                StopMotionFrameConfig(image, durationUs)
            }

            if (frames.isEmpty()) {
                throw IllegalArgumentException("Frames cannot be empty")
            }

            return StopMotionConfig(
                id = id,
                frames = frames,
                frameRate = (call.argument<Number>("frameRate"))?.toDouble() ?: 12.0,
                width = (call.argument<Number>("width"))?.toInt(),
                height = (call.argument<Number>("height"))?.toInt(),
                fit = call.argument<String>("fit") ?: "contain",
                outputFormat = call.argument<String>("outputFormat") ?: "mp4",
                outputPath = call.argument<String>("outputPath"),
                bitrate = (call.argument<Number>("bitrate"))?.toInt(),
            )
        }

        /**
         * Reads a frame's image source, preferring the on-disk path Dart sends
         * for a file-backed frame. Returns null for a frame that carries
         * neither, so it is skipped instead of failing the whole render.
         */
        private fun parseImage(map: Map<String, Any?>): EncodedImage? {
            val path = (map["imagePath"] as? String)?.takeIf { it.isNotBlank() }
            if (path != null) return EncodedImage.OfFile(File(path))

            val data = (map["imageData"] as? ByteArray)?.takeIf { it.isNotEmpty() }
            return data?.let { EncodedImage.OfBytes(it) }
        }
    }
}
