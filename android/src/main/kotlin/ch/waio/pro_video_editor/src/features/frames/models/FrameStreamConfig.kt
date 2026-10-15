package ch.waio.pro_video_editor.src.features.frames.models

import io.flutter.plugin.common.MethodCall

/**
 * Configuration for streaming every frame of a range as raw luma.
 *
 * @property startUs first source timestamp to deliver, or null for the start
 * @property endUs source timestamp to stop before, or null for the end
 * @property outputWidth bounding box the upright frames are scaled into
 * @property outputHeight bounding box the upright frames are scaled into
 * @property maxFrameRate frames closer together than its period are skipped
 * @property maxParallelDecoders upper bound of hardware decoder sessions
 */
data class FrameStreamConfig(
    val id: String,
    val inputPath: String,
    val extension: String,
    val startUs: Long?,
    val endUs: Long?,
    val outputWidth: Int,
    val outputHeight: Int,
    val maxFrameRate: Double?,
    val maxParallelDecoders: Int?,
) {
    companion object {
        /**
         * Creates a config from a Flutter [MethodCall].
         *
         * @throws IllegalArgumentException if a required value is missing or
         *   invalid
         */
        fun fromMethodCall(call: MethodCall): FrameStreamConfig {
            val outputWidth = call.argument<Number>("outputWidth")?.toInt()
                ?: throw IllegalArgumentException("outputWidth is required")
            val outputHeight = call.argument<Number>("outputHeight")?.toInt()
                ?: throw IllegalArgumentException("outputHeight is required")
            require(outputWidth > 0 && outputHeight > 0) { "output size must be positive" }
            val maxFrameRate = call.argument<Number>("maxFrameRate")?.toDouble()
            require(maxFrameRate == null || maxFrameRate > 0) { "maxFrameRate must be positive" }
            val maxParallelDecoders = call.argument<Number>("maxParallelDecoders")?.toInt()
            require(maxParallelDecoders == null || maxParallelDecoders >= 1) {
                "maxParallelDecoders must be at least 1"
            }
            return FrameStreamConfig(
                id = call.argument<String>("id") ?: "",
                inputPath = call.argument<String>("inputPath")
                    ?: throw IllegalArgumentException("inputPath is required"),
                extension = call.argument<String>("extension") ?: "mp4",
                startUs = call.argument<Number>("startUs")?.toLong(),
                endUs = call.argument<Number>("endUs")?.toLong(),
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                maxFrameRate = maxFrameRate,
                maxParallelDecoders = maxParallelDecoders,
            )
        }
    }
}
