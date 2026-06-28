package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.math.roundToLong

/**
 * Pure, dependency-free math for resolving a composition-wide global trim.
 *
 * The global trim window ([globalStartUs]/[globalEndUs]) is expressed in OUTPUT
 * time — the final rendered length the caller wants — while each clip is stored
 * in SOURCE time. Because per-clip [ClipInput.playbackSpeed] and the
 * composition-wide [globalPlaybackSpeed] shrink/stretch a clip on the timeline,
 * the trim has to be resolved against the post-speed (output) timeline and then
 * mapped back into each clip's source units.
 *
 * This mirrors the iOS pipeline, where per-clip speed is baked into the
 * composition via `scaleTimeRange` before the export `timeRange` (the cap) is
 * applied, so the cap always limits the output length.
 *
 * Kept free of Android/MediaCodec dependencies (source durations are resolved by
 * the caller and passed in) so it can be unit-tested directly, mirroring
 * [VideoTimelineDurationCalculator].
 */
internal object VideoGlobalTrimCalculator {
    /** One decoded-but-not-yet-trimmed clip, in SOURCE microseconds. */
    data class ClipInput(
        val sourceStartUs: Long,
        val sourceEndUs: Long,
        val playbackSpeed: Float?,
        val reverseVideo: Boolean,
    )

    /** Resolved source range for a surviving clip, in SOURCE microseconds. */
    data class ClipTrimResult(
        val sourceStartUs: Long,
        val sourceEndUs: Long,
    )

    /**
     * Resolves the global trim against the OUTPUT timeline.
     *
     * @param frameCompensationUs Subtracted (in SOURCE units) from a clip cut by
     *   the global end so the encoder does not overshoot to the next frame/audio
     *   sample boundary. Stays in source units because it compensates for the
     *   decoded source frame boundary, not the output one.
     * @return one entry per input clip, in the same order; `null` where the clip
     *   falls entirely outside the trim window (caller must drop it).
     */
    fun applyGlobalTrim(
        clips: List<ClipInput>,
        globalStartUs: Long?,
        globalEndUs: Long?,
        globalPlaybackSpeed: Float?,
        frameCompensationUs: Long = 33333L, // ~33ms = 1 frame at 30fps
    ): List<ClipTrimResult?> {
        if (globalStartUs == null && globalEndUs == null) {
            return clips.map { ClipTrimResult(it.sourceStartUs, it.sourceEndUs) }
        }

        val globalStart = globalStartUs ?: 0L
        val globalEnd = globalEndUs ?: Long.MAX_VALUE

        val results = ArrayList<ClipTrimResult?>(clips.size)
        // Position on the OUTPUT (post-speed) timeline, where the trim lives.
        var compositionTimeUs = 0L

        for (clip in clips) {
            val sourceDurationUs = (clip.sourceEndUs - clip.sourceStartUs).coerceAtLeast(0L)
            val outputDurationUs = VideoTimelineDurationCalculator.renderedClipDurationUs(
                sourceDurationUs = sourceDurationUs,
                clipPlaybackSpeed = clip.playbackSpeed,
                globalPlaybackSpeed = globalPlaybackSpeed,
            )

            val clipStartInComposition = compositionTimeUs
            val clipEndInComposition = compositionTimeUs + outputDurationUs

            if (clipEndInComposition <= globalStart || clipStartInComposition >= globalEnd) {
                // Clip is completely outside the global trim range - drop it.
                results.add(null)
            } else {
                val effectiveSpeed = effectiveSpeed(clip.playbackSpeed, globalPlaybackSpeed)

                var newStartInSource = clip.sourceStartUs
                var newEndInSource = clip.sourceEndUs

                // Output-time amount the trim cuts off each side of this clip.
                val startTrimOutputUs = if (clipStartInComposition < globalStart) {
                    globalStart - clipStartInComposition
                } else {
                    0L
                }
                val endTrimOutputUs = if (clipEndInComposition > globalEnd) {
                    clipEndInComposition - globalEnd
                } else {
                    0L
                }

                // Convert the output-time offsets back into source units.
                val startTrimSourceUs = (startTrimOutputUs * effectiveSpeed).roundToLong()
                val endTrimSourceUs = (endTrimOutputUs * effectiveSpeed).roundToLong()

                // Adjust start if the global start cuts into this clip.
                if (startTrimSourceUs > 0L) {
                    if (clip.reverseVideo) {
                        newEndInSource = clip.sourceEndUs - startTrimSourceUs
                    } else {
                        newStartInSource = clip.sourceStartUs + startTrimSourceUs
                    }
                }

                // Adjust end if the global end cuts into this clip.
                if (endTrimSourceUs > 0L) {
                    if (clip.reverseVideo) {
                        newStartInSource = minOf(
                            newEndInSource,
                            newStartInSource + endTrimSourceUs + frameCompensationUs
                        )
                    } else {
                        newEndInSource = maxOf(
                            newStartInSource,
                            newEndInSource - endTrimSourceUs - frameCompensationUs
                        )
                    }
                }

                // Only keep the clip if there is still content left.
                if (newEndInSource > newStartInSource) {
                    results.add(ClipTrimResult(newStartInSource, newEndInSource))
                } else {
                    results.add(null)
                }
            }

            compositionTimeUs += outputDurationUs
        }

        return results
    }

    private fun effectiveSpeed(clipSpeed: Float?, globalSpeed: Float?): Double {
        return validSpeedOrOne(clipSpeed) * validSpeedOrOne(globalSpeed)
    }

    private fun validSpeedOrOne(speed: Float?): Double {
        return if (speed != null && speed > 0f) speed.toDouble() else 1.0
    }
}
