package ch.waio.pro_video_editor.src.features.render.helpers

import android.media.MediaCodec

/**
 * Tells *transient* codec failures apart from genuine encoder/format
 * incompatibility.
 *
 * Media3 reports both as the same `ExportException`
 * (`ERROR_CODE_ENCODER_INIT_FAILED`), but they call for opposite reactions:
 *
 *  - **Transient**: the codec could not be acquired because the device's
 *    MediaCodec pool was exhausted or the session was reclaimed by a
 *    higher-priority client (a preview player that has not released its decoder
 *    yet, a concurrent export, another app). Nothing is wrong with the video or
 *    the requested configuration — the very same export succeeds once codec
 *    resources free up, so the caller should retry.
 *  - **Permanent**: the encoder rejects the configuration/format itself.
 *    Retrying is pointless; the failure has to be surfaced.
 *
 * The distinction is only visible on the [MediaCodec.CodecException] buried in
 * the `ExportException` cause chain, which is what this classifier looks for.
 */
object EncoderFailureClassifier {
    /**
     * Upper bound for the cause-chain walk. Guards against a pathological
     * (cyclic) chain; real Media3 chains are only a few levels deep.
     */
    internal const val MAX_CAUSE_DEPTH = 32

    /**
     * Returns true when [throwable] or any of its causes is a transient
     * MediaCodec resource failure (see [isTransientCodecException]).
     *
     * @param throwable Failure to inspect (typically an `ExportException`).
     * @param isTransientCause Classifier applied to every link of the cause
     *  chain. Defaults to the MediaCodec check and is only overridden by tests
     *  (a [MediaCodec.CodecException] cannot be constructed off-device).
     */
    fun isTransientResourceFailure(
        throwable: Throwable?,
        isTransientCause: (Throwable) -> Boolean = ::isTransientCodecException,
    ): Boolean {
        var cause: Throwable? = throwable
        var depth = 0
        while (cause != null && depth < MAX_CAUSE_DEPTH) {
            if (isTransientCause(cause)) return true
            val next = cause.cause
            if (next === cause) return false
            cause = next
            depth++
        }
        return false
    }

    /**
     * True for a [MediaCodec.CodecException] that reports codec-resource
     * pressure rather than a bad configuration:
     * `ERROR_INSUFFICIENT_RESOURCE` (the codec pool is full),
     * `ERROR_RECLAIMED` (the session was taken away), or a codec that flags
     * itself as transient/recoverable.
     */
    private fun isTransientCodecException(throwable: Throwable): Boolean {
        if (throwable !is MediaCodec.CodecException) return false
        return throwable.isTransient ||
                throwable.isRecoverable ||
                throwable.errorCode ==
                MediaCodec.CodecException.ERROR_INSUFFICIENT_RESOURCE ||
                throwable.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED
    }
}
