package ch.waio.pro_video_editor.src.features.audio.models

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Represents an active audio extraction task.
 *
 * Holds the Flutter result callback, job handle for cancellation,
 * and cancellation state tracking.
 *
 * @property job Handle to the active extraction job (null until job starts)
 * @property result Flutter method channel result to respond to when complete
 * @property canceled Flag indicating if this task was cancelled by user
 */
data class AudioExtractTask(
    var job: AudioExtractJobHandle? = null,
    val result: MethodChannel.Result,
    val canceled: AtomicBoolean = AtomicBoolean(false)
) {
    /**
     * Sends success response to Flutter with extracted audio bytes.
     * Only sends if not already replied to prevent crashes.
     */
    fun sendSuccess(data: ByteArray?) {
        try {
            result.success(data)
        } catch (e: IllegalStateException) {
            // Result already sent, ignore
        }
    }

    /**
     * Sends an arbitrary success value to Flutter (e.g. the audio-merge result
     * map). Only sends if not already replied to prevent crashes.
     */
    fun sendValue(value: Any?) {
        try {
            result.success(value)
        } catch (e: IllegalStateException) {
            // Result already sent, ignore
        }
    }

    /**
     * Sends error response to Flutter.
     * Only sends if not already replied to prevent crashes.
     */
    fun sendError(code: String, message: String?) {
        try {
            result.error(code, message, null)
        } catch (e: IllegalStateException) {
            // Result already sent, ignore
        }
    }
}
