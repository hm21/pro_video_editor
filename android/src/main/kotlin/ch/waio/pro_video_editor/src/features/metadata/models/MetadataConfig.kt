package ch.waio.pro_video_editor.src.features.metadata.models

import io.flutter.plugin.common.MethodCall

data class MetadataConfig(
    val inputPath: String,
    val extension: String,
    val checkStreamingOptimization: Boolean = false
) {
    companion object {
        /**
         * Creates a MetadataConfig from a Flutter MethodCall.
         *
         * @param call The MethodCall containing metadata parameters
         * @throws IllegalArgumentException if required parameters are missing
         */
        fun fromMethodCall(call: MethodCall): MetadataConfig {
            val inputPath = call.argument<String>("inputPath")
                ?: throw IllegalArgumentException("inputPath is required")
            val extension = call.argument<String>("extension")
                ?: throw IllegalArgumentException("extension is required")

            return MetadataConfig(
                inputPath = inputPath,
                extension = extension,
                checkStreamingOptimization = call.argument<Boolean>("checkStreamingOptimization")
                    ?: false
            )
        }
    }
}
