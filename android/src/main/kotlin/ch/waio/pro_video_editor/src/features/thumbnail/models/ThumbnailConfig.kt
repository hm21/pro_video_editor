package ch.waio.pro_video_editor.src.features.thumbnail.models

import io.flutter.plugin.common.MethodCall

data class ThumbnailConfig(
    val id: String,
    val inputPath: String,
    val extension: String,
    val boxFit: String,
    val outputFormat: String,
    val jpegQuality: Int,
    val outputWidth: Int,
    val outputHeight: Int,
    val timestampsUs: List<Long>,
    val maxOutputFrames: Int?,
    /**
     * Upper bound of hardware decoder sessions the timestamp path may run in
     * parallel, or null for the generator's default. A caller that shares the
     * device's decoder pool with a live player passes 1 so the extraction
     * never holds more than one session at a time.
     */
    val maxParallelDecoders: Int? = null,
) {
    companion object {
        /**
         * Creates a ThumbnailConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing thumbnail parameters
         * @throws IllegalArgumentException if required parameters are missing or invalid
         */
        fun fromMethodCall(call: MethodCall): ThumbnailConfig {
            val id = call.argument<String>("id") ?: ""
            val inputPath = call.argument<String>("inputPath")
                ?: throw IllegalArgumentException("inputPath is required")
            val extension = call.argument<String>("extension")
                ?: throw IllegalArgumentException("extension is required")
            val boxFit = call.argument<String>("boxFit")
                ?: throw IllegalArgumentException("boxFit is required")
            val outputFormat = call.argument<String>("outputFormat")
                ?: throw IllegalArgumentException("outputFormat is required")
            val jpegQuality = call.argument<Number>("jpegQuality")?.toInt() ?: 90
            require(jpegQuality in 0..100) { "jpegQuality must be between 0 and 100" }
            val outputWidth = call.argument<Number>("outputWidth")?.toInt()
                ?: throw IllegalArgumentException("outputWidth is required")
            val outputHeight = call.argument<Number>("outputHeight")?.toInt()
                ?: throw IllegalArgumentException("outputHeight is required")

            val rawTimestamps = call.argument<List<Number>>("timestamps") ?: emptyList()
            val timestampsUs = rawTimestamps.map { it.toLong() }
            val maxOutputFrames = call.argument<Number>("maxOutputFrames")?.toInt()
            val maxParallelDecoders = call.argument<Number>("maxParallelDecoders")?.toInt()
            require(maxParallelDecoders == null || maxParallelDecoders >= 1) {
                "maxParallelDecoders must be at least 1"
            }

            if (timestampsUs.isEmpty() && maxOutputFrames == null) {
                throw IllegalArgumentException("Either timestamps or maxOutputFrames must be provided")
            }

            return ThumbnailConfig(
                id = id,
                inputPath = inputPath,
                extension = extension,
                boxFit = boxFit,
                outputFormat = outputFormat,
                jpegQuality = jpegQuality,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                timestampsUs = timestampsUs,
                maxOutputFrames = maxOutputFrames,
                maxParallelDecoders = maxParallelDecoders,
            )
        }
    }
}
