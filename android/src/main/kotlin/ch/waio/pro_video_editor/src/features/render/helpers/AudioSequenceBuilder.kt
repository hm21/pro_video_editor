package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import ch.waio.pro_video_editor.src.shared.logging.PluginLog as Log
import java.io.File

/**
 * Builder class for creating custom audio sequences in video compositions.
 *
 * Pre-renders the entire audio track (leading silence + looped/clipped
 * source + trailing silence) into a single PCM WAV file via
 * [AudioPreRenderer], then exposes it as ONE [EditedMediaItem] inside an
 * [EditedMediaItemSequence].
 *
 * Using a single item per audio track removes the AAC frame realignment
 * artifacts (clicks/gaps) that previously occurred at every loop boundary
 * and silence/audio transition when the sequence contained multiple
 * items.
 *
 * The generated WAV file path is returned from [build] alongside the
 * sequence so the caller can register it for cleanup once the
 * Transformer export finishes.
 */
@UnstableApi
class AudioSequenceBuilder(
    private val context: Context,
    private val audioPath: String,
    private val videoDurationUs: Long
) {
    /**
     * The result of a successful [build]: the audio sequence ready to be
     * added to the composition, plus the temporary WAV file that must be
     * deleted by the caller after rendering completes.
     */
    data class BuildResult(
        val sequence: EditedMediaItemSequence,
        val temporaryFile: File
    )

    private var loopAudio: Boolean = true
    private var startTimeUs: Long = 0
    private var audioEndTimeUs: Long? = null
    private var compositionStartTimeUs: Long? = null
    private var compositionEndTimeUs: Long? = null
    private var loopCrossfadeMillis: Double = 0.0

    /**
     * Sets whether the audio should loop to fill the play range.
     */
    fun setLoop(loop: Boolean): AudioSequenceBuilder {
        this.loopAudio = loop
        return this
    }

    /**
     * Sets the start time offset within the source audio file.
     */
    fun setStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.startTimeUs = (startTimeUs ?: 0L).coerceAtLeast(0L)
        return this
    }

    /**
     * Sets the end time within the source audio file.
     */
    fun setAudioEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.audioEndTimeUs = endTimeUs
        return this
    }

    /**
     * Sets when this audio track should start playing on the composition
     * timeline.
     */
    fun setCompositionStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.compositionStartTimeUs = startTimeUs
        return this
    }

    /**
     * Sets when this audio track should stop playing on the composition
     * timeline.
     */
    fun setCompositionEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.compositionEndTimeUs = endTimeUs
        return this
    }

    /**
     * Sets the equal-power crossfade length (ms) applied at the loop seam
     * so the rendered file loops seamlessly. 0 disables it.
     */
    fun setLoopCrossfadeMillis(millis: Double): AudioSequenceBuilder {
        this.loopCrossfadeMillis = millis.coerceAtLeast(0.0)
        return this
    }

    /**
     * Builds the audio sequence by pre-rendering the source into a single
     * gap-less PCM WAV file.
     *
     * @return [BuildResult] with the sequence and the temporary file to
     *   delete after export, or null if the audio could not be prepared.
     */
    fun build(): BuildResult? {
        val sourceFile = File(audioPath)
        if (!sourceFile.exists()) {
            Log.e(RENDER_TAG, "Custom audio file not found: $audioPath")
            return null
        }

        val compStart = (compositionStartTimeUs ?: 0L).coerceAtLeast(0L)
        val compEnd = (compositionEndTimeUs ?: videoDurationUs)
            .coerceAtMost(videoDurationUs)
        val playDurationUs = (compEnd - compStart).coerceAtLeast(0L)

        if (playDurationUs <= 0L) {
            Log.w(RENDER_TAG, "Custom audio play duration <= 0, skipping track")
            return null
        }

        val preRender = AudioPreRenderer.render(
            context = context,
            audioPath = audioPath,
            audioStartUs = startTimeUs,
            audioEndUs = audioEndTimeUs,
            loop = loopAudio,
            compositionStartUs = compStart,
            compositionDurationUs = playDurationUs,
            videoDurationUs = videoDurationUs,
            crossfadeMillis = loopCrossfadeMillis
        ) ?: return null

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(preRender.outputFile))
            .build()

        val editedItem = EditedMediaItem.Builder(mediaItem)
            .setRemoveVideo(true)
            .setEffects(Effects(emptyList<AudioProcessor>(), emptyList()))
            .build()

        val sequence = EditedMediaItemSequence.Builder(editedItem).build()

        return BuildResult(sequence, preRender.outputFile)
    }
}
