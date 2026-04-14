import android.media.MediaCodecInfo
import android.media.MediaCodecList
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.VideoEncoderSettings
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Configures video encoder bitrate settings.
 *
 * Validates bitrate against codec capabilities and selects optimal bitrate mode:
 * - CBR (Constant Bitrate) if supported - predictable file size
 * - VBR (Variable Bitrate) fallback - better quality at same average bitrate
 *
 * @param encoderFactoryBuilder Encoder factory to configure
 * @param mimeType Video MIME type (e.g., "video/avc" for H.264)
 * @param bitrate Target bitrate in bits per second
 */
@UnstableApi
fun applyBitrate(
    encoderFactoryBuilder: DefaultEncoderFactory.Builder,
    mimeType: String?,
    bitrate: Int?
) {
    if (bitrate == null) return
    Log.d(RENDER_TAG, "Configuring bitrate: ${bitrate / 1000} kbps")

    val codecInfo = MediaCodecList(MediaCodecList.ALL_CODECS)
        .codecInfos
        .firstOrNull { it.isEncoder && it.supportedTypes.contains(mimeType) }

    if (codecInfo == null) {
        Log.e(RENDER_TAG, "No encoder found for $mimeType")
        return
    }

    val capabilities = codecInfo.getCapabilitiesForType(mimeType)
    val bitrateRange = capabilities.videoCapabilities.bitrateRange
    val supportsCBR = capabilities.encoderCapabilities
        .isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)

    if (!bitrateRange.contains(bitrate)) {
        Log.e(
            RENDER_TAG,
            "Bitrate ${bitrate / 1000} kbps outside supported range: ${bitrateRange.lower / 1000}-${bitrateRange.upper / 1000} kbps"
        )
        return
    }

    val bitrateMode = if (supportsCBR) {
        Log.d(RENDER_TAG, "Using CBR (Constant Bitrate) mode")
        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
    } else {
        Log.d(RENDER_TAG, "CBR not supported, using VBR (Variable Bitrate) mode")
        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
    }

    val builder = VideoEncoderSettings.Builder()
        .setBitrateMode(bitrateMode)
        .setBitrate(bitrate)

    encoderFactoryBuilder.setRequestedVideoEncoderSettings(builder.build())
}
