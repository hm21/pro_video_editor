package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig
import ch.waio.pro_video_editor.src.features.render.models.VideoClip
import ch.waio.pro_video_editor.src.shared.media.contentDataSource

/**
 * Moves a trim onto the picture it names when it misses that picture's start
 * by at most a microsecond.
 *
 * Android reads sample times in whole microseconds, truncated, so its own
 * frame times cut exactly. A frame time rounded to the nearest microsecond
 * instead, as iOS and macOS report them, lies a microsecond after the sample
 * of a picture that starts between two: as an end it keeps that picture, and
 * as a start it drops it. A time on a sample, or a microsecond before one,
 * already cuts on it.
 */
internal object PictureStartSnapping {
    /**
     * How many pictures H.264 and HEVC may decode ahead of one they show after
     * (`max_num_reorder_frames`, `sps_max_num_reorder_pics`).
     */
    private const val MAX_REORDERED_PICTURES = 16

    /** Whether any video clip of [config] has a trim [snapped] could move. */
    fun isNeeded(config: RenderConfig): Boolean =
        config.videoClips.any { (it.startUs ?: 0) > 0 || (it.endUs ?: 0) > 0 }

    /**
     * [config] with every video clip's trim on the pictures it names. Reads
     * the clips' samples, so it must run off the main thread.
     */
    fun snapped(context: Context, config: RenderConfig): RenderConfig {
        if (!isNeeded(config)) return config
        return config.copy(videoClips = config.videoClips.map { snapped(context, it) })
    }

    private fun snapped(context: Context, clip: VideoClip): VideoClip {
        val startUs = clip.startUs?.takeIf { it > 0 }
        val endUs = clip.endUs?.takeIf { it > 0 }
        if (startUs == null && endUs == null) return clip

        val extractor = MediaExtractor()
        return try {
            extractor.contentDataSource(context, clip.inputPath)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("video/") == true
            } ?: return clip
            extractor.selectTrack(track)
            val samplesFrom = { fromUs: Long ->
                extractor.seekTo(fromUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                generateSequence(extractor.sampleTime.takeIf { it >= 0 }) {
                    if (extractor.advance()) extractor.sampleTime.takeIf { it >= 0 } else null
                }
            }
            clip.copy(
                startUs = startUs?.let { snapped(it, samplesFrom) } ?: clip.startUs,
                endUs = endUs?.let { snapped(it, samplesFrom) } ?: clip.endUs,
            )
        } catch (e: Exception) {
            // The render opens the clip again and reports what is wrong with
            // it; the trim then stays as it was given.
            Log.w(RENDER_TAG, "Could not read the samples of ${clip.inputPath}: ${e.message}")
            clip
        } finally {
            extractor.release()
        }
    }

    /**
     * [timeUs] moved onto the sample a microsecond before it, if there is one.
     *
     * [samplesFrom] lists the sample times in decode order from the sync
     * sample at or before the given time. Pictures come out of decode order,
     * so the search ends only once more pictures after the sample's time have
     * gone by than may be decoded ahead of it.
     */
    fun snapped(timeUs: Long, samplesFrom: (Long) -> Sequence<Long>): Long {
        val sampleUs = timeUs - 1
        var later = 0
        for (time in samplesFrom(sampleUs)) {
            if (time == sampleUs) return sampleUs
            if (time > sampleUs && ++later > MAX_REORDERED_PICTURES) break
        }
        return timeUs
    }
}
