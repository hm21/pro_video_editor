package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log

/**
 * Utility functions for audio channel mixing and normalization.
 */
@UnstableApi
object AudioMixingUtils {

    /**
     * Creates a ChannelMixingAudioProcessor configured with standard mixing matrices
     * to downmix common multi-channel formats to Stereo (2 channels).
     *
     * Supports:
     * - 1 channel (Mono) -> Stereo
     * - 2 channels (Stereo) -> Stereo (Identity)
     * - 4 channels (Quad) -> Stereo
     * - 6 channels (5.1 Surround) -> Stereo (ITU-R BS.775)
     * - 8 channels (7.1 Surround) -> Stereo
     */
    fun createStandardStereoMixer(): ChannelMixingAudioProcessor {
        val channelMixer = ChannelMixingAudioProcessor()
        val boost = 1.4f // Slight boost to compensate for downmixing volume loss

        // 8 channels (7.1) -> 2 channels (Stereo)
        // FL, FR, FC, LFE, BL, BR, SL, SR
        val eightToTwo = floatArrayOf(
            1.0f * boost, 0.0f,           // FL -> L, R
            0.0f, 1.0f * boost,           // FR -> L, R
            0.707f * boost, 0.707f * boost, // FC -> L, R
            0.0f, 0.0f,                   // LFE
            0.707f * boost, 0.0f,         // BL -> L
            0.0f, 0.707f * boost,         // BR -> R
            0.707f * boost, 0.0f,         // SL -> L
            0.0f, 0.707f * boost          // SR -> R
        )
        channelMixer.putChannelMixingMatrix(ChannelMixingMatrix(8, 2, eightToTwo))

        // 6 channels (5.1) -> 2 channels (Stereo)
        // FL, FR, FC, LFE, BL, BR
        val sixToTwo = floatArrayOf(
            1.0f * boost, 0.0f,           // FL -> L, R
            0.0f, 1.0f * boost,           // FR -> L, R
            0.707f * boost, 0.707f * boost, // FC -> L, R
            0.0f, 0.0f,                   // LFE
            0.707f * boost, 0.0f,         // BL -> L
            0.0f, 0.707f * boost          // BR -> R
        )
        channelMixer.putChannelMixingMatrix(ChannelMixingMatrix(6, 2, sixToTwo))

        // 4 channels (Quad) -> 2 channels (Stereo)
        // FL, FR, BL, BR
        val fourToTwo = floatArrayOf(
            1.0f, 0.0f,                   // FL -> L
            0.0f, 1.0f,                   // FR -> R
            0.707f, 0.0f,                 // BL -> L
            0.0f, 0.707f                  // BR -> R
        )
        channelMixer.putChannelMixingMatrix(ChannelMixingMatrix(4, 2, fourToTwo))

        // 2 channels -> 2 channels (Stereo passthrough)
        channelMixer.putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(2, 2))

        // 1 channel (Mono) -> 2 channels (Stereo)
        channelMixer.putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(1, 2))

        return channelMixer
    }
}
