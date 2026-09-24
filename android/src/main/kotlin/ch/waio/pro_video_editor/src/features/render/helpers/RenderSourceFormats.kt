package ch.waio.pro_video_editor.src.features.render.helpers

import android.media.MediaFormat
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.features.render.models.RenderConfig

/**
 * The video formats of the sources a render reads, for a failed render's
 * error details.
 *
 * A failure names what broke, not what it was given: `Video frame processing
 * error` reads the same for an HDR clip as for an SDR one, although the HDR
 * clip takes a different GL path. Each entry carries the video track's `mime`
 * and, when the file states them, its `bitDepth` and `transfer` (`sdr`, `hlg`,
 * `pq`, `linear`, or the raw `MediaFormat` value). A bit depth the file does
 * not state is left out rather than reported as the 8 the transcode check
 * assumes. A source whose video track could not be read is an empty map.
 * Never the path, which can name the user's files.
 */
@UnstableApi
object RenderSourceFormats {

    /**
     * One entry per distinct format among the clips, then the layers' clips.
     * Opens every source, so it must not run on the main thread.
     */
    fun of(config: RenderConfig): List<Map<String, Any>> = describeDistinct(
        (
            config.videoClips.map { it.inputPath } +
                (config.composition?.layers ?: emptyList())
                    .flatMap { layer -> layer.clips.map { it.inputPath } }
            )
            .distinct()
            .map { MediaInfoExtractor.getVideoFormatInfo(it) }
    )

    /**
     * [infos] described in order, a format a previous source already had left
     * out. Without the path, a repeat says nothing new, and a composition of
     * dozens of same-format clips would otherwise push `cause` past a crash
     * reporter's cut.
     */
    fun describeDistinct(infos: List<MediaInfoExtractor.VideoFormatInfo>) =
        infos.map(::describe).distinct()

    fun describe(info: MediaInfoExtractor.VideoFormatInfo): Map<String, Any> {
        val mime = info.mime ?: return emptyMap()
        val entry = mutableMapOf<String, Any>("mime" to mime)
        if (info.bitDepthStated) entry["bitDepth"] = info.bitDepth
        info.colorTransfer?.let { entry["transfer"] = transferName(it) }
        return entry
    }

    fun transferName(transfer: Int): String = when (transfer) {
        MediaFormat.COLOR_TRANSFER_SDR_VIDEO -> "sdr"
        MediaFormat.COLOR_TRANSFER_HLG -> "hlg"
        MediaFormat.COLOR_TRANSFER_ST2084 -> "pq"
        MediaFormat.COLOR_TRANSFER_LINEAR -> "linear"
        else -> transfer.toString()
    }
}
