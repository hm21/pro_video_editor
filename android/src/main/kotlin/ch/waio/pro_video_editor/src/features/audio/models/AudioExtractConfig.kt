package ch.waio.pro_video_editor.src.features.audio.models

import io.flutter.plugin.common.MethodCall

/**
 * Configuration for audio extraction from video files.
 *
 * @property id Unique task identifier for progress tracking and cancellation
 * @property inputPath Absolute path to the source video file
 * @property format Output audio format (mp3, aac, wav, m4a, ogg)
 * @property startUs Optional start time in microseconds for trimming
 * @property endUs Optional end time in microseconds for trimming
 * @property speed Playback speed multiplier (1.0 = original speed, pitch preserved)
 * @property outputPath Optional output file path (null = return bytes)
 */
data class AudioExtractConfig(
    val id: String,
    val inputPath: String,
    val format: String,
    val startUs: Long?,
    val endUs: Long?,
    val speed: Float,
    val outputPath: String?
) {
    companion object {
        /**
         * Creates an AudioExtractConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing extraction parameters
         * @throws IllegalArgumentException if required parameters are missing
         */
        fun fromMethodCall(call: MethodCall): AudioExtractConfig {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")
            
            val inputPath = call.argument<String>("inputPath")
                ?: throw IllegalArgumentException("inputPath is required")
            
            val format = call.argument<String>("format") ?: "mp3"
            val startUs = call.argument<Number>("startTime")?.toLong()
            val endUs = call.argument<Number>("endTime")?.toLong()
            val speed = call.argument<Number>("speed")?.toFloat()?.takeIf { it > 0f } ?: 1.0f
            val outputPath = call.argument<String>("outputPath")

            return AudioExtractConfig(
                id = id,
                inputPath = inputPath,
                format = format,
                startUs = startUs,
                endUs = endUs,
                speed = speed,
                outputPath = outputPath
            )
        }
    }

    /**
     * Returns the MIME type for the configured audio format.
     */
    fun getMimeType(): String {
        return when (format.lowercase()) {
            "mp3" -> "audio/mpeg"
            "aac" -> "audio/mp4"
            "wav" -> "audio/wav"
            "m4a" -> "audio/mp4"
            "ogg" -> "audio/ogg"
            else -> "audio/mpeg" // Default to MP3
        }
    }

    /**
     * Returns the file extension for the configured audio format.
     */
    fun getExtension(): String {
        return when (format.lowercase()) {
            "mp3" -> "mp3"
            "aac" -> "aac"
            "wav" -> "wav"
            "m4a" -> "m4a"
            "ogg" -> "ogg"
            else -> "mp3"
        }
    }
}
