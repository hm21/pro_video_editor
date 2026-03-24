package ch.waio.pro_video_editor.src.features.render.models

import PACKAGE_TAG
import android.util.Log
import io.flutter.plugin.common.MethodCall

/**
 * Represents a video clip segment with optional trimming.
 * 
 * @property inputPath Absolute path to video file
 * @property startUs Start time in microseconds (null = from beginning)
 * @property endUs End time in microseconds (null = until end)
 */
data class VideoClip(
    val inputPath: String,
    val startUs: Long?,
    val endUs: Long?
)

data class RenderConfig(
    val videoClips: List<VideoClip>,
    val imageBytes: ByteArray? = null,
    val outputFormat: String,
    val outputPath: String? = null,
    val rotateTurns: Int? = null,
    val flipX: Boolean = false,
    val flipY: Boolean = false,
    val cropWidth: Int? = null,
    val cropHeight: Int? = null,
    val cropX: Int? = null,
    val cropY: Int? = null,
    val scaleX: Float? = null,
    val scaleY: Float? = null,
    val bitrate: Int? = null,
    val enableAudio: Boolean = true,
    val playbackSpeed: Float? = null,
    val colorMatrixList: List<List<Double>> = emptyList(),
    val blur: Double? = null,
    val customAudioPath: String? = null,
    /** Start time offset in microseconds for the custom audio track */
    val customAudioStartTimeUs: Long? = null,
    val originalAudioVolume: Float? = null,
    val customAudioVolume: Float? = null,
    /** Global start time in microseconds for trimming the final composition */
    val startUs: Long? = null,
    /** Global end time in microseconds for trimming the final composition */
    val endUs: Long? = null,
    /** Whether to optimize the video for network streaming (fast start).
     * When true, attempts to place moov atom at start of MP4 for progressive streaming.
     * When false, moov atom will be at the end (smaller file, but not streamable). */
    val shouldOptimizeForNetworkUse: Boolean = true,
    /** Whether to apply cropping to the image overlay along with the video.
     * When true, the image overlay is applied before cropping (cropped together with video).
     * When false (default), the overlay is scaled to the final cropped size. */
    val imageBytesWithCropping: Boolean = false,
    /** Whether to loop the custom audio if it is shorter than the video.
     * When true (default), audio is repeated to match video duration.
     * When false, audio plays once and silence fills the rest. */
    val loopCustomAudio: Boolean = true
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as RenderConfig
        return videoClips == other.videoClips &&
                imageBytes?.contentEquals(
                    other.imageBytes ?: byteArrayOf()
                ) ?: (other.imageBytes == null) &&
                outputFormat == other.outputFormat &&
                outputPath == other.outputPath
    }

    override fun hashCode(): Int {
        var result = videoClips.hashCode()
        result = 31 * result + (imageBytes?.contentHashCode() ?: 0)
        result = 31 * result + outputFormat.hashCode()
        result = 31 * result + (outputPath?.hashCode() ?: 0)
        return result
    }

    companion object {
        /**
         * Creates a RenderConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing all render parameters
         * @throws IllegalArgumentException if required videoClips are missing or invalid
         */
        fun fromMethodCall(call: MethodCall): RenderConfig {
            // Parse video clips (required)
            val videoClipsRaw = call.argument<List<Map<String, Any>>>("videoClips")

            Log.d(PACKAGE_TAG, "Received videoClipsRaw: ${videoClipsRaw?.size ?: 0} clips")

            if (videoClipsRaw == null || videoClipsRaw.isEmpty()) {
                throw IllegalArgumentException("videoClips is required and cannot be empty")
            }

            val videoClips: List<VideoClip> = videoClipsRaw.mapIndexed { index, clipMap ->
                val clip = VideoClip(
                    inputPath = clipMap["inputPath"] as String,
                    startUs = (clipMap["startUs"] as? Number)?.toLong(),
                    endUs = (clipMap["endUs"] as? Number)?.toLong()
                )
                Log.d(
                    PACKAGE_TAG,
                    "Clip $index: path=${clip.inputPath}, start=${clip.startUs}, end=${clip.endUs}"
                )
                clip
            }

            // Parse all other parameters
            return RenderConfig(
                videoClips = videoClips,
                imageBytes = call.argument<ByteArray?>("imageBytes"),
                outputFormat = call.argument<String>("outputFormat") ?: "mp4",
                outputPath = call.argument<String>("outputPath"),
                rotateTurns = call.argument<Number>("rotateTurns")?.toInt(),
                flipX = call.argument<Boolean>("flipX") ?: false,
                flipY = call.argument<Boolean>("flipY") ?: false,
                cropWidth = call.argument<Number>("cropWidth")?.toInt(),
                cropHeight = call.argument<Number>("cropHeight")?.toInt(),
                cropX = call.argument<Number>("cropX")?.toInt(),
                cropY = call.argument<Number>("cropY")?.toInt(),
                scaleX = call.argument<Number>("scaleX")?.toFloat(),
                scaleY = call.argument<Number>("scaleY")?.toFloat(),
                bitrate = call.argument<Number>("bitrate")?.toInt(),
                enableAudio = call.argument<Boolean>("enableAudio") ?: true,
                playbackSpeed = call.argument<Number>("playbackSpeed")?.toFloat(),
                colorMatrixList = call.argument<List<List<Double>>>("colorMatrixList")
                    ?: emptyList(),
                blur = call.argument<Number>("blur")?.toDouble(),
                customAudioPath = call.argument<String?>("customAudioPath"),
                customAudioStartTimeUs = call.argument<Number?>("customAudioStartTimeUs")?.toLong(),
                originalAudioVolume = call.argument<Number?>("originalAudioVolume")?.toFloat(),
                customAudioVolume = call.argument<Number?>("customAudioVolume")?.toFloat(),
                startUs = call.argument<Number?>("startUs")?.toLong(),
                endUs = call.argument<Number?>("endUs")?.toLong(),
                shouldOptimizeForNetworkUse = call.argument<Boolean>("shouldOptimizeForNetworkUse") ?: true,
                imageBytesWithCropping = call.argument<Boolean>("imageBytesWithCropping") ?: false,
                loopCustomAudio = call.argument<Boolean>("loopCustomAudio") ?: true
            )
        }
    }
}
