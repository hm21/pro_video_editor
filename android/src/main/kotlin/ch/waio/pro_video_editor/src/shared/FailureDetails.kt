package ch.waio.pro_video_editor.src.shared

import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException

/**
 * The `details` a failed job attaches to its method-channel error.
 *
 * A job's error message is the throwable's own message, and for the failures
 * that matter most that is one generic line per Media3 error code — "Video
 * frame processing error", "Muxer error" — with the exception underneath,
 * which says what actually broke, dropped on the floor. Nothing an app can
 * branch on survives that, so the details carry what does: the throwable's
 * type, the Media3 error code when there is one, and the cause chain. Same
 * shape as Darwin's `FailureDetails`, which builds it from an `NSError`.
 *
 * Keys:
 * - `domain`: the outermost throwable's class name.
 * - `code` / `codeName`: `ExportException.errorCode` and its name
 *   (`ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED`) from the first
 *   [ExportException] in the chain; absent when there is none.
 * - `sources`: for a failed render, the video format of every source it read
 *   (see `RenderSourceFormats`). Absent for every other job.
 * - `cause`: every throwable below the outermost one, outermost first, as
 *   `<class>: <message>` (`(no message)` for a throwable without one), each
 *   message cut to its first line. Absent when there is none.
 *
 * `cause` comes last and each message keeps only its first line because
 * crash reporters cut a long error message from the end (Crashlytics at about
 * 2,000 characters), and a GL compile error carries the whole shader source,
 * several kilobytes, after the line that names the problem.
 */
@UnstableApi
object FailureDetails {
    /**
     * Causes deeper than this are cut off; a chain that long is a cycle or a
     * bug, and the top levels already say what happened.
     */
    private const val MAX_CAUSE_DEPTH = 8

    /** A cause's first line is cut here, so no single entry can crowd out the rest. */
    private const val MAX_CAUSE_MESSAGE_LENGTH = 240

    fun of(error: Throwable, sources: List<Map<String, Any>>? = null): Map<String, Any> {
        val chain = causeChain(error)
        val details = mutableMapOf<String, Any>("domain" to error.javaClass.name)
        chain.filterIsInstance<ExportException>().firstOrNull()?.let { export ->
            details["code"] = export.errorCode
            details["codeName"] = export.errorCodeName
        }
        sources?.let { details["sources"] = it }
        val cause = chain.drop(1).joinToString(" <- ") {
            "${it.javaClass.name}: ${summary(it.message)}"
        }
        if (cause.isNotEmpty()) details["cause"] = cause
        return details
    }

    /** [message]'s first non-blank line, cut at [MAX_CAUSE_MESSAGE_LENGTH]. */
    private fun summary(message: String?): String {
        val line = message?.lineSequence()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() }
            ?: return "(no message)"
        return if (line.length <= MAX_CAUSE_MESSAGE_LENGTH) line
        else line.take(MAX_CAUSE_MESSAGE_LENGTH) + "…"
    }

    /** [error] followed by its causes, stopping at a repeat or at the depth cap. */
    private fun causeChain(error: Throwable): List<Throwable> {
        val chain = mutableListOf<Throwable>()
        var current: Throwable? = error
        while (current != null && chain.size <= MAX_CAUSE_DEPTH && chain.none { it === current }) {
            chain.add(current)
            current = current.cause
        }
        return chain
    }
}
