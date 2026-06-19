package ch.waio.pro_video_editor.src.features.stopmotion.models

import io.flutter.plugin.common.MethodCall

/**
 * Configuration for a single stop-motion frame.
 *
 * @property imageData Encoded image bytes (PNG/JPEG/etc.) for this frame.
 * @property durationUs How long this frame is held on screen, in microseconds.
 *   When `null`, the default frame duration (`1 / frameRate`) is used.
 */
class StopMotionFrameConfig(
    val imageData: ByteArray,
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
                val data = map["imageData"] as? ByteArray ?: return@mapNotNull null
                if (data.isEmpty()) return@mapNotNull null
                val durationUs = (map["durationUs"] as? Number)?.toLong()
                StopMotionFrameConfig(data, durationUs)
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
    }
}
