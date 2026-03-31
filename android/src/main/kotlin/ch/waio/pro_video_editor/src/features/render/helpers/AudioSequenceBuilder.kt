package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.net.Uri
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import java.io.File

/**
 * Builder class for creating custom audio sequences in video compositions.
 *
 * Handles looping, volume control, and channel normalization for custom
 * audio tracks that play alongside or replace original video audio.
 */
@UnstableApi
class AudioSequenceBuilder(
    private val audioPath: String,
    private val videoDurationUs: Long
) {
    private var volume: Float = 1.0f
    private var needsNormalization: Boolean = false
    private var loopAudio: Boolean = true
    private var startTimeUs: Long = 0
    private var audioEndTimeUs: Long? = null
    private var compositionStartTimeUs: Long? = null
    private var compositionEndTimeUs: Long? = null

    /**
     * Sets the volume multiplier for the custom audio.
     *
     * @param volume Volume factor (0.0=silent, 1.0=unchanged, >1.0=amplified)
     */
    fun setVolume(volume: Float): AudioSequenceBuilder {
        this.volume = volume
        return this
    }

    /**
     * Enables channel normalization (convert to stereo).
     *
     * Should be enabled when video clips have different channel counts
     * to ensure compatibility.
     */
    fun setNormalization(enabled: Boolean): AudioSequenceBuilder {
        this.needsNormalization = enabled
        return this
    }

    /**
     * Sets whether the audio should loop to match video duration.
     *
     * @param loop If true, audio repeats; if false, plays once
     */
    fun setLoop(loop: Boolean): AudioSequenceBuilder {
        this.loopAudio = loop
        return this
    }

    /**
     * Sets the start time offset for the custom audio.
     *
     * @param startTimeUs Start time in microseconds from the beginning of the audio file
     */
    fun setStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.startTimeUs = startTimeUs ?: 0
        return this
    }

    /**
     * Sets the end time within the audio source file.
     *
     * @param endTimeUs End time in microseconds within the audio file (null = use full file)
     */
    fun setAudioEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.audioEndTimeUs = endTimeUs
        return this
    }

    /**
     * Sets when this audio track should start playing in the composition timeline.
     *
     * @param startTimeUs Composition time in microseconds (null = from beginning)
     */
    fun setCompositionStartTime(startTimeUs: Long?): AudioSequenceBuilder {
        this.compositionStartTimeUs = startTimeUs
        return this
    }

    /**
     * Sets when this audio track should stop playing in the composition timeline.
     *
     * @param endTimeUs Composition time in microseconds (null = until end)
     */
    fun setCompositionEndTime(endTimeUs: Long?): AudioSequenceBuilder {
        this.compositionEndTimeUs = endTimeUs
        return this
    }

    /**
     * Builds the audio sequence with looping to match video duration.
     *
     * @return EditedMediaItemSequence for custom audio, or null if file not found
     */
    fun build(): EditedMediaItemSequence? {
        Log.d(RENDER_TAG, "Building custom audio sequence: $audioPath")
        Log.d(RENDER_TAG, "Custom audio volume: $volume")
        if (startTimeUs > 0) {
            Log.d(RENDER_TAG, "Custom audio start offset: ${startTimeUs / 1000} ms")
        }

        val audioFile = File(audioPath)
        if (!audioFile.exists()) {
            Log.e(RENDER_TAG, "Custom audio file not found: $audioPath")
            return null
        }

        val totalAudioDurationUs = MediaInfoExtractor.getAudioDuration(audioPath)
        if (totalAudioDurationUs == 0L) {
            Log.w(RENDER_TAG, "Cannot determine custom audio duration")
            return null
        }

        // Calculate effective audio duration considering source clipping
        val sourceEndUs = audioEndTimeUs?.coerceAtMost(totalAudioDurationUs) ?: totalAudioDurationUs
        val effectiveAudioDurationUs = sourceEndUs - startTimeUs
        if (effectiveAudioDurationUs <= 0) {
            Log.w(
                RENDER_TAG,
                "Start time ($startTimeUs us) exceeds audio end ($sourceEndUs us)"
            )
            return null
        }

        // Calculate target duration based on composition placement
        val compStart = compositionStartTimeUs ?: 0L
        val compEnd = compositionEndTimeUs ?: videoDurationUs
        val targetDurationUs = (compEnd - compStart).coerceAtLeast(0L)

        // Build audio effects
        val audioProcessors = buildAudioProcessors()
        val audioEffects = Effects(audioProcessors, emptyList())

        // Create audio content items with looping or single play
        val audioContentItems = if (loopAudio) {
            createLoopedAudioItems(
                audioFile,
                sourceEndUs,
                effectiveAudioDurationUs,
                targetDurationUs,
                audioEffects
            )
        } else {
            createSingleAudioItem(audioFile, sourceEndUs, effectiveAudioDurationUs, targetDurationUs, audioEffects)
        }

        val allItems = mutableListOf<EditedMediaItem>()

        // Add leading silence if audio starts after composition time 0.
        // Media3 parallel sequences always start at time 0, so we need
        // silence padding to offset the audio to the correct position.
        if (compStart > 0) {
            val silentItem = createSilentAudioItem(compStart, audioEffects)
            if (silentItem != null) {
                allItems.add(silentItem)
                Log.d(RENDER_TAG, "Added ${compStart / 1000}ms leading silence for composition offset")
            }
        }

        allItems.addAll(audioContentItems)

        // Add trailing silence so the sequence spans the full video duration.
        // This ensures all parallel sequences have matching lengths.
        val totalContentDurationUs = compStart + targetDurationUs
        if (totalContentDurationUs < videoDurationUs) {
            val trailingDurationUs = videoDurationUs - totalContentDurationUs
            val silentItem = createSilentAudioItem(trailingDurationUs, audioEffects)
            if (silentItem != null) {
                allItems.add(silentItem)
                Log.d(RENDER_TAG, "Added ${trailingDurationUs / 1000}ms trailing silence")
            }
        }

        return EditedMediaItemSequence.Builder(allItems).build()
    }

    /**
     * Builds audio processors for custom audio (channel mixing + volume).
     *
     * Uses ITU-R BS.775 standard coefficients for multi-channel downmixing.
     */
    private fun buildAudioProcessors(): List<AudioProcessor> {
        val processors = mutableListOf<AudioProcessor>()

        // Add channel mixing if needed
        if (needsNormalization) {
            val channelMixer = ChannelMixingAudioProcessor()

            // 7.1 Surround (8 channels) to Stereo (2 channels)
            // Channel order: FL, FR, FC, LFE, BL, BR, SL, SR
            val eightToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.707f, 0.0f, 0.0f, 0.707f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(8, 2, eightToTwo)
            )

            // 5.1 Surround (6 channels) to Stereo (2 channels)
            // ITU-R BS.775 standard
            val sixToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.707f, 0.0f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(6, 2, sixToTwo)
            )

            // Quad (4 channels) to Stereo (2 channels)
            val fourToTwo = floatArrayOf(
                1.0f, 0.0f, 0.707f, 0.0f,  // Left output
                0.0f, 1.0f, 0.0f, 0.707f   // Right output
            )
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix(4, 2, fourToTwo)
            )

            // Stereo (2 channels) to Stereo (2 channels) - passthrough
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix.create(2, 2)
            )

            // Mono (1 channel) to Stereo (2 channels)
            channelMixer.putChannelMixingMatrix(
                ChannelMixingMatrix.create(1, 2)
            )

            processors.add(channelMixer)
            Log.d(RENDER_TAG, "Added channel normalization for custom audio")
        }

        // NOTE: Volume control is now handled by VolumeControlAudioMixerFactory
        // because Media3's AudioProcessors on EditedMediaItems are NOT invoked
        // when using parallel sequences (multiple EditedMediaItemSequence).
        // The VolumeAudioProcessor was being configured but never actually processing audio.
        // See VolumeControlAudioMixer which applies volumes during the mixing stage.
        if (volume != 1.0f) {
            Log.d(
                RENDER_TAG,
                "Custom audio volume: ${volume}x (applied via VolumeControlAudioMixer)"
            )
        }

        return processors
    }

    /**
     * Creates audio items with looping to match target duration.
     * First iteration uses startTimeUs offset, subsequent loops start from beginning.
     */
    private fun createLoopedAudioItems(
        audioFile: File,
        sourceEndUs: Long,
        effectiveAudioDurationUs: Long,
        targetDurationUs: Long,
        effects: Effects
    ): List<EditedMediaItem> {
        val audioItems = mutableListOf<EditedMediaItem>()

        if (effectiveAudioDurationUs <= 0 || targetDurationUs <= 0) {
            // Fallback: add audio once without duration constraints
            val audioItem = createAudioItem(audioFile, startTimeUs, null, effects)
            audioItems.add(audioItem)
            return audioItems
        }

        var remainingDurationUs = targetDurationUs
        var loopCount = 0
        var isFirstLoop = true

        while (remainingDurationUs > 0) {
            loopCount++

            // First loop uses startTimeUs offset, subsequent loops start from 0
            val loopStartUs = if (isFirstLoop) startTimeUs else 0L
            val loopEndUs = if (isFirstLoop) sourceEndUs else sourceEndUs
            val loopAudioDurationUs =
                if (isFirstLoop) effectiveAudioDurationUs else (sourceEndUs - 0L)

            val endPositionUs = if (remainingDurationUs < loopAudioDurationUs) {
                Log.d(
                    RENDER_TAG,
                    "Loop $loopCount: Trimming audio to ${remainingDurationUs / 1000} ms (final loop)"
                )
                loopStartUs + remainingDurationUs
            } else {
                Log.d(
                    RENDER_TAG,
                    "Loop $loopCount: Using audio duration ${loopAudioDurationUs / 1000} ms" +
                            if (isFirstLoop && startTimeUs > 0) " (starting at ${startTimeUs / 1000} ms)" else ""
                )
                if (audioEndTimeUs != null) loopEndUs else null
            }

            val audioItem = createAudioItem(audioFile, loopStartUs, endPositionUs, effects)
            audioItems.add(audioItem)
            remainingDurationUs -= loopAudioDurationUs
            isFirstLoop = false
        }

        Log.d(RENDER_TAG, "Custom audio will loop $loopCount times to match target duration")
        return audioItems
    }

    /**
     * Creates a single audio item (no looping). Trims if audio is longer than target duration.
     */
    private fun createSingleAudioItem(
        audioFile: File,
        sourceEndUs: Long,
        effectiveAudioDurationUs: Long,
        targetDurationUs: Long,
        effects: Effects
    ): List<EditedMediaItem> {
        val endPositionUs = if (effectiveAudioDurationUs > targetDurationUs && targetDurationUs > 0) {
            Log.d(RENDER_TAG, "Trimming audio to ${targetDurationUs / 1000} ms (no loop)")
            startTimeUs + targetDurationUs
        } else if (audioEndTimeUs != null) {
            Log.d(
                RENDER_TAG, "Playing audio once (${effectiveAudioDurationUs / 1000} ms, no loop)" +
                        if (startTimeUs > 0) " starting at ${startTimeUs / 1000} ms" else ""
            )
            sourceEndUs
        } else {
            Log.d(
                RENDER_TAG, "Playing audio once (${effectiveAudioDurationUs / 1000} ms, no loop)" +
                        if (startTimeUs > 0) " starting at ${startTimeUs / 1000} ms" else ""
            )
            null
        }
        return listOf(createAudioItem(audioFile, startTimeUs, endPositionUs, effects))
    }

    /**
     * Creates a single audio EditedMediaItem with start offset and optional end position.
     */
    private fun createAudioItem(
        audioFile: File,
        startPositionUs: Long,
        endPositionUs: Long?,
        effects: Effects
    ): EditedMediaItem {
        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(audioFile))

        if (startPositionUs > 0 || endPositionUs != null) {
            val clippingConfig = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(startPositionUs / 1000)

            if (endPositionUs != null) {
                clippingConfig.setEndPositionMs(endPositionUs / 1000)
            }

            mediaItemBuilder.setClippingConfiguration(clippingConfig.build())
        }

        val mediaItem = mediaItemBuilder.build()
        return EditedMediaItem.Builder(mediaItem)
            .setRemoveVideo(true)
            .setEffects(effects)
            .build()
    }

    /**
     * Creates a silent audio EditedMediaItem of the specified duration.
     *
     * Media3 parallel sequences always start at time 0, so we use silence
     * to offset audio to the correct composition position.
     */
    private fun createSilentAudioItem(durationUs: Long, effects: Effects): EditedMediaItem? {
        if (durationUs <= 0) return null

        val silentFile = generateSilentWavFile(durationUs)
        if (silentFile == null) {
            Log.e(RENDER_TAG, "Failed to create silent audio item")
            return null
        }

        val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(silentFile)).build()
        return EditedMediaItem.Builder(mediaItem)
            .setRemoveVideo(true)
            .setEffects(effects)
            .build()
    }

    /**
     * Generates a temporary WAV file containing silence of the specified duration.
     *
     * Creates a valid PCM WAV file with stereo 44100Hz 16-bit silence.
     */
    private fun generateSilentWavFile(durationUs: Long): File? {
        try {
            val sampleRate = 44100
            val channels = 2
            val bitsPerSample = 16
            val bytesPerSample = bitsPerSample / 8
            val numSamples = (sampleRate * durationUs / 1_000_000.0).toInt()
            val dataSize = numSamples * channels * bytesPerSample
            val fileSize = 36 + dataSize

            val file = File.createTempFile("silence_", ".wav")
            file.deleteOnExit()

            file.outputStream().use { out ->
                // RIFF header
                out.write("RIFF".toByteArray(Charsets.US_ASCII))
                out.write(toLittleEndian(fileSize, 4))
                out.write("WAVE".toByteArray(Charsets.US_ASCII))

                // fmt subchunk
                out.write("fmt ".toByteArray(Charsets.US_ASCII))
                out.write(toLittleEndian(16, 4))  // Subchunk1Size (PCM)
                out.write(toLittleEndian(1, 2))   // AudioFormat (PCM = 1)
                out.write(toLittleEndian(channels, 2))
                out.write(toLittleEndian(sampleRate, 4))
                out.write(toLittleEndian(sampleRate * channels * bytesPerSample, 4))
                out.write(toLittleEndian(channels * bytesPerSample, 2))
                out.write(toLittleEndian(bitsPerSample, 2))

                // data subchunk
                out.write("data".toByteArray(Charsets.US_ASCII))
                out.write(toLittleEndian(dataSize, 4))

                // Write silence (all zeros)
                val buffer = ByteArray(8192)
                var remaining = dataSize
                while (remaining > 0) {
                    val toWrite = minOf(remaining, buffer.size)
                    out.write(buffer, 0, toWrite)
                    remaining -= toWrite
                }
            }

            Log.d(RENDER_TAG, "Generated ${durationUs / 1000}ms silent WAV: ${file.absolutePath}")
            return file
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to generate silent WAV: ${e.message}")
            return null
        }
    }

    /** Converts an integer to little-endian byte array. */
    private fun toLittleEndian(value: Int, numBytes: Int): ByteArray {
        return ByteArray(numBytes) { i -> ((value shr (8 * i)) and 0xFF).toByte() }
    }
}
