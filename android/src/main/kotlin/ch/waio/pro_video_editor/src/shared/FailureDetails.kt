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
 * - `cause`: every throwable below the outermost one, outermost first, as
 *   `<class>: <message>`. Absent when there is none.
 */
@UnstableApi
object FailureDetails {
    /**
     * Causes deeper than this are cut off; a chain that long is a cycle or a
     * bug, and the top levels already say what happened.
     */
    private const val MAX_CAUSE_DEPTH = 8

    fun of(error: Throwable): Map<String, Any> {
        val chain = causeChain(error)
        val details = mutableMapOf<String, Any>("domain" to error.javaClass.name)
        chain.filterIsInstance<ExportException>().firstOrNull()?.let { export ->
            details["code"] = export.errorCode
            details["codeName"] = export.errorCodeName
        }
        val cause = chain.drop(1).joinToString(" <- ") { "${it.javaClass.name}: ${it.message}" }
        if (cause.isNotEmpty()) details["cause"] = cause
        return details
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
