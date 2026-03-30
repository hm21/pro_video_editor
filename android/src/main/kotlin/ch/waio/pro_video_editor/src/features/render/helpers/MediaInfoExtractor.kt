package ch.waio.pro_video_editor.src.features.render.helpers

import RENDER_TAG
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import androidx.media3.common.util.UnstableApi

/**
 * Utility class for extracting media information from video and audio files.
 *
 * Provides methods to extract duration, channel count, and sample rate
 * using Android's MediaExtractor API.
 */
@UnstableApi
object MediaInfoExtractor {

    /**
     * Retrieves video duration from file.
     *
     * @param videoPath Absolute path to video file
     * @return Duration in microseconds, or 0 if not found
     */
    fun getVideoDuration(videoPath: String): Long {
        return try {
            val extractor = MediaExtractor()
            extractor.setDataSource(videoPath)
            var duration = 0L

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    duration = format.getLong(MediaFormat.KEY_DURATION)
                    break
                }
            }

            extractor.release()
            duration
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to get video duration for $videoPath: ${e.message}")
            0L
        }
    }

    /**
     * Retrieves audio duration from file.
     *
     * @param audioPath Absolute path to audio file
     * @return Duration in microseconds, or 0 if not found
     */
    fun getAudioDuration(audioPath: String): Long {
        return try {
            val extractor = MediaExtractor()
            extractor.setDataSource(audioPath)
            var duration = 0L

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    duration = format.getLong(MediaFormat.KEY_DURATION)
                    Log.d(RENDER_TAG, "Audio duration: ${duration / 1000} ms")
                    break
                }
            }

            extractor.release()
            duration
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to get audio duration: ${e.message}")
            0L
        }
    }

    /**
     * Detects the number of audio channels in a video file.
     *
     * @param videoPath Absolute path to video file
     * @return Number of channels (1=mono, 2=stereo, 6=5.1), or null if not found
     */
    fun getAudioChannelCount(videoPath: String): Int? {
        return try {
            val extractor = MediaExtractor()
            extractor.setDataSource(videoPath)
            var channelCount: Int? = null

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    Log.d(RENDER_TAG, "File $videoPath: $channelCount audio channels")
                    break
                }
            }

            extractor.release()
            channelCount
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to detect audio channels for $videoPath: ${e.message}")
            null
        }
    }

    /**
     * Detects sample rate of an audio file.
     *
     * @param audioPath Absolute path to audio file
     * @return Sample rate in Hz (e.g., 48000), or 0 if not found
     */
    fun getAudioSampleRate(audioPath: String): Int {
        return try {
            val extractor = MediaExtractor()
            extractor.setDataSource(audioPath)
            var sampleRate = 0

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    Log.d(RENDER_TAG, "Audio sample rate: $sampleRate Hz")
                    break
                }
            }

            extractor.release()
            sampleRate
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to detect audio sample rate: ${e.message}")
            0
        }
    }

    /**
     * Data class containing video format information for transcoding decisions.
     * 
     * @property isHevc True if video uses HEVC/H.265 codec
     * @property bitDepth Color bit depth (8 or 10)
     * @property isHdr True if video has HDR metadata (HLG, HDR10, etc.)
     * @property profile Codec profile string (e.g., "hvc1.2.4.H120")
     */
    data class VideoFormatInfo(
        val isHevc: Boolean,
        val bitDepth: Int,
        val isHdr: Boolean,
        val profile: String?
    ) {
        /**
         * Determines if video requires transcoding to H.264 before applying GPU effects.
         * 
         * HEVC 10-bit HDR videos (hvc1.2.4.H120) have GPU surface compatibility issues
         * when applying effects on Android. These need to be transcoded to H.264 8-bit first.
         */
        fun needsTranscodingForEffects(): Boolean {
            // Transcode if: HEVC + (10-bit OR HDR)
            return isHevc && (bitDepth > 8 || isHdr)
        }
    }

    /**
     * Extracts detailed video format information to determine transcoding needs.
     * 
     * Specifically detects HEVC 10-bit HDR videos that cause GPU surface issues
     * when applying effects (colorMatrix, blur, overlay).
     * 
     * @param videoPath Absolute path to video file
     * @return VideoFormatInfo with codec, bit depth, and HDR information
     */
    fun getVideoFormatInfo(videoPath: String): VideoFormatInfo {
        return try {
            val extractor = MediaExtractor()
            extractor.setDataSource(videoPath)

            var isHevc = false
            var bitDepth = 8
            var isHdr = false
            val profile: String? = null

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""

                if (mime.startsWith("video/")) {
                    // Check if HEVC
                    isHevc = mime == "video/hevc" || mime == "video/h265"

                    // Try to get bit depth (API 24+)
                    try {
                        if (format.containsKey("color-bit-depth")) {
                            bitDepth = format.getInteger("color-bit-depth")
                        }
                    } catch (e: Exception) {
                        // Key not available on older devices
                    }

                    // Check for HDR transfer function (API 24+)
                    try {
                        if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                            val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                            // HDR transfer functions: HLG (7), PQ/HDR10 (6), Linear HDR (1)
                            isHdr = transfer == 7 || transfer == 6 || transfer == 1
                        }
                    } catch (e: Exception) {
                        // Key not available
                    }

                    // Check color standard for wide color gamut (usually indicates HDR)
                    try {
                        if (format.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
                            val standard = format.getInteger(MediaFormat.KEY_COLOR_STANDARD)
                            // BT.2020 (6) - typically used with HDR content
                            if (standard == 6) {
                                isHdr = true
                            }
                        }
                    } catch (e: Exception) {
                        // Key not available
                    }

                    // Try to get codec profile string
                    try {
                        if (format.containsKey("csd-0")) {
                            val csd = format.getByteBuffer("csd-0")
                            // The profile is encoded in the codec-specific data
                            // For now, just log that we have codec data
                        }
                    } catch (e: Exception) {
                        // Key not available
                    }

                    // If HEVC and no explicit bit-depth found, check profile level
                    // Main 10 profile typically uses 10-bit
                    if (isHevc && bitDepth == 8) {
                        try {
                            if (format.containsKey(MediaFormat.KEY_PROFILE)) {
                                val profileLevel = format.getInteger(MediaFormat.KEY_PROFILE)
                                // Main 10 profile = 2
                                if (profileLevel == 2) {
                                    bitDepth = 10
                                }
                            }
                        } catch (e: Exception) {
                            // Key not available
                        }
                    }

                    Log.d(
                        RENDER_TAG,
                        "Video format: mime=$mime, isHevc=$isHevc, bitDepth=$bitDepth, isHdr=$isHdr"
                    )
                    break
                }
            }

            extractor.release()
            VideoFormatInfo(isHevc, bitDepth, isHdr, profile)
        } catch (e: Exception) {
            Log.e(RENDER_TAG, "Failed to get video format info for $videoPath: ${e.message}")
            // Return safe defaults - assume no transcoding needed
            VideoFormatInfo(isHevc = false, bitDepth = 8, isHdr = false, profile = null)
        }
    }
}
