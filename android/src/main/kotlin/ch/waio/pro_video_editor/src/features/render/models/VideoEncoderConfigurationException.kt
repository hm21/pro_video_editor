package ch.waio.pro_video_editor.src.features.render.models

/**
 * Thrown when the video export fails because no encoder could be configured for
 * the requested output, even after the resilient fallback chain (operating-rate
 * cap, operating-rate removal, software encoder, profile downgrade) has been
 * exhausted.
 *
 * This is a distinct, descriptive type (rather than a generic render failure) so
 * the Flutter layer can surface a proper "format/encoder not supported" error
 * state instead of an opaque platform exception.
 *
 * @param isTransient True when the failure was codec-resource pressure (an
 *  exhausted codec pool or a reclaimed session, see
 *  [ch.waio.pro_video_editor.src.features.render.helpers.EncoderFailureClassifier])
 *  rather than an incompatible configuration. A transient failure is worth
 *  retrying once codec resources free up; a non-transient one is not.
 */
class VideoEncoderConfigurationException(
    message: String?,
    cause: Throwable? = null,
    val isTransient: Boolean = false,
) : Exception(message, cause)
