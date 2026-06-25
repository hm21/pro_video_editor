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
 */
class VideoEncoderConfigurationException(
    message: String?,
    cause: Throwable? = null,
) : Exception(message, cause)
