package ch.waio.pro_video_editor.src.features.waveform.models

import io.flutter.plugin.common.MethodCall

/**
 * Configuration for waveform generation from video files.
 *
 * @property id Unique task identifier for progress tracking and cancellation
 * @property inputPath Absolute path to the source video file
 * @property fileExtension The file extension of the source video
 * @property samplesPerSecond Number of waveform samples per second of audio
 * @property startUs Optional start time in microseconds for partial extraction
 * @property endUs Optional end time in microseconds for partial extraction
 * @property chunkSize Number of samples per chunk for streaming mode
 */
data class WaveformConfig(
    val id: String,
    val inputPath: String,
    val fileExtension: String,
    val samplesPerSecond: Int,
    val startUs: Long?,
    val endUs: Long?,
    val chunkSize: Int = 100
) {
    companion object {
        /**
         * Creates a WaveformConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing waveform parameters
         * @throws IllegalArgumentException if required parameters are missing
         */
        fun fromMethodCall(call: MethodCall): WaveformConfig {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")

            val inputPath = call.argument<String>("inputPath")
                ?: throw IllegalArgumentException("inputPath is required")

            val fileExtension = call.argument<String>("extension") ?: "mp4"
            val samplesPerSecond = call.argument<Int>("samplesPerSecond") ?: 50
            val startUs = call.argument<Number>("startTime")?.toLong()
            val endUs = call.argument<Number>("endTime")?.toLong()
            val chunkSize = call.argument<Int>("chunkSize") ?: 100

            return WaveformConfig(
                id = id,
                inputPath = inputPath,
                fileExtension = fileExtension,
                samplesPerSecond = samplesPerSecond,
                startUs = startUs,
                endUs = endUs,
                chunkSize = chunkSize
            )
        }
    }
}
