package ch.waio.pro_video_editor.src.features.audio.models

import io.flutter.plugin.common.MethodCall

/**
 * A single trimmed audio window that participates in an audio merge.
 *
 * @property inputPath Absolute path to the source video/audio file.
 * @property startUs Window start in the source timeline, in microseconds.
 * @property endUs Window end in the source timeline, in microseconds (> startUs).
 * @property speed Playback speed multiplier applied after trimming (> 0).
 */
data class AudioMergeSegmentConfig(
    val inputPath: String,
    val startUs: Long,
    val endUs: Long,
    val speed: Float
)

/**
 * Configuration for merging several trimmed audio windows into one file.
 *
 * Mirrors [AudioExtractConfig] but carries an ordered list of segments plus an
 * optional uniform output sample rate / channel count.
 *
 * @property id Unique task identifier for progress tracking and cancellation.
 * @property format Output audio format (wav, aac, m4a, ...).
 * @property sampleRate Optional uniform output sample rate in Hz (null = derive
 *   from the first audio-bearing segment).
 * @property channels Optional uniform output channel count (null = derive from
 *   the first audio-bearing segment).
 * @property outputPath Absolute path where the merged file is written.
 * @property segments Ordered segments to concatenate.
 */
data class AudioMergeConfig(
    val id: String,
    val format: String,
    val sampleRate: Int?,
    val channels: Int?,
    val outputPath: String,
    val segments: List<AudioMergeSegmentConfig>
) {
    /** Whether the caller pinned an explicit uniform output format. */
    val hasExplicitFormat: Boolean get() = sampleRate != null || channels != null

    companion object {
        /**
         * Creates an [AudioMergeConfig] from a Flutter [MethodCall].
         *
         * @throws IllegalArgumentException if required parameters are missing or
         *   a segment is invalid (empty list, `endUs <= startUs`, `speed <= 0`).
         */
        fun fromMethodCall(call: MethodCall): AudioMergeConfig {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")
            val format = call.argument<String>("format") ?: "wav"
            val outputPath = call.argument<String>("outputPath")
                ?: throw IllegalArgumentException("outputPath is required")
            val sampleRate = call.argument<Number>("sampleRate")?.toInt()
            val channels = call.argument<Number>("channels")?.toInt()

            val rawSegments = call.argument<List<Map<String, Any?>>>("segments")
                ?: throw IllegalArgumentException("segments is required")
            if (rawSegments.isEmpty()) {
                throw IllegalArgumentException("segments must not be empty")
            }

            val segments = rawSegments.mapIndexed { index, raw ->
                val inputPath = raw["inputPath"] as? String
                    ?: throw IllegalArgumentException("segment[$index].inputPath is required")
                val startUs = (raw["startTime"] as? Number)?.toLong()
                    ?: throw IllegalArgumentException("segment[$index].startTime is required")
                val endUs = (raw["endTime"] as? Number)?.toLong()
                    ?: throw IllegalArgumentException("segment[$index].endTime is required")
                val speed = (raw["speed"] as? Number)?.toFloat() ?: 1.0f
                if (endUs <= startUs) {
                    throw IllegalArgumentException("segment[$index].endTime must be > startTime")
                }
                if (speed <= 0f) {
                    throw IllegalArgumentException("segment[$index].speed must be > 0")
                }
                AudioMergeSegmentConfig(
                    inputPath = inputPath,
                    startUs = startUs,
                    endUs = endUs,
                    speed = speed
                )
            }

            return AudioMergeConfig(
                id = id,
                format = format,
                sampleRate = sampleRate,
                channels = channels,
                outputPath = outputPath,
                segments = segments
            )
        }
    }

    /** Returns the file extension for the configured output format. */
    fun getExtension(): String = when (format.lowercase()) {
        "wav" -> "wav"
        "aac" -> "aac"
        "m4a" -> "m4a"
        "mp3" -> "mp3"
        "ogg" -> "ogg"
        else -> "m4a"
    }

    /** Builds the equivalent single-clip [AudioExtractConfig] for a segment. */
    fun extractConfig(segment: AudioMergeSegmentConfig): AudioExtractConfig = AudioExtractConfig(
        id = id,
        inputPath = segment.inputPath,
        format = format,
        startUs = segment.startUs,
        endUs = segment.endUs,
        speed = segment.speed,
        outputPath = outputPath
    )
}
