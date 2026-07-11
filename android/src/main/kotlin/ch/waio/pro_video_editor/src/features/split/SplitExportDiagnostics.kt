package ch.waio.pro_video_editor.src.features.split

import java.util.Locale

/**
 * Immutable context for one exported half, used to enrich a stall/timeout
 * failure with actionable diagnostics.
 *
 * The bracketed suffix is intentionally identical in structure to the iOS side
 * (`mime` here vs `preset` there) so a host app can parse either platform's
 * message the same way, e.g.
 * `[half=end progress=0.00 segment=0.52s split=0.53s total=1.05s mime=video/avc audio=false]`.
 *
 * A duration of `-1` (unknown, e.g. the source duration could not be probed) is
 * rendered as `?` rather than a misleading `0.00s`.
 *
 * @property half `"start"` (0 → split) or `"end"` (split → end).
 * @property segmentUs Duration of *this* segment in microseconds, or -1 if unknown.
 * @property splitUs Absolute split position in microseconds.
 * @property totalUs Total source duration in microseconds, or -1 if unknown.
 * @property mimeType The output video MIME type (e.g. `video/avc`).
 * @property enableAudio Whether the source audio track is kept.
 */
data class SplitExportDiagnostics(
    val half: String,
    val segmentUs: Long,
    val splitUs: Long,
    val totalUs: Long,
    val mimeType: String,
    val enableAudio: Boolean,
) {
    /** The bracketed context suffix appended to a stall/timeout message. */
    fun context(progress: Double): String =
        "[half=$half progress=${fraction(progress)} " +
            "segment=${seconds(segmentUs)}s split=${seconds(splitUs)}s " +
            "total=${seconds(totalUs)}s mime=$mimeType audio=$enableAudio]"

    fun timeoutMessage(seconds: Long, progress: Double): String =
        "Split export timed out after ${seconds}s ${context(progress)}"

    fun stallMessage(seconds: Long, progress: Double): String =
        "Split export stalled after ${seconds}s with no progress ${context(progress)}"

    private fun fraction(value: Double): String = String.format(Locale.US, "%.2f", value)

    private fun seconds(us: Long): String =
        if (us < 0) "?" else String.format(Locale.US, "%.2f", us / 1_000_000.0)
}
