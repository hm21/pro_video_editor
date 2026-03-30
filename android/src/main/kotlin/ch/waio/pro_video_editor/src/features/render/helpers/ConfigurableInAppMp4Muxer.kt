package ch.waio.pro_video_editor.src.features.render.helpers

import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.container.Mp4OrientationData
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Mp4Muxer
import androidx.media3.muxer.Muxer
import androidx.media3.muxer.MuxerException
import androidx.media3.muxer.MuxerUtil
import androidx.media3.muxer.SeekableMuxerOutput
import com.google.common.collect.ImmutableList
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.LinkedHashSet
import java.util.Locale

/**
 * A configurable version of InAppMp4Muxer that allows setting attemptStreamableOutputEnabled.
 * 
 * This is a direct port of Media3's InAppMp4Muxer with the ability to configure
 * the streaming optimization flag.
 */
@UnstableApi
class ConfigurableInAppMp4Muxer private constructor(
    private val muxer: Mp4Muxer,
    private val videoDurationUs: Long
) : Muxer {

    private val metadataEntries: MutableSet<Metadata.Entry> = LinkedHashSet()
    private var videoTrackId: Int = TRACK_ID_UNSET

    companion object {
        private const val TAG = "ConfigInAppMp4Muxer"
        private const val TRACK_ID_UNSET = -1
    }

    /** Factory for ConfigurableInAppMp4Muxer */
    class Factory(
        private val attemptStreamableOutput: Boolean = true,
        private val videoDurationUs: Long = C.TIME_UNSET
    ) : Muxer.Factory {

        override fun create(path: String): ConfigurableInAppMp4Muxer {
            val outputStream: FileOutputStream
            try {
                outputStream = FileOutputStream(path)
            } catch (e: FileNotFoundException) {
                throw MuxerException("Error creating file output stream", e)
            }

            val builder = Mp4Muxer.Builder(SeekableMuxerOutput.of(outputStream))
                .setAttemptStreamableOutputEnabled(attemptStreamableOutput)

            val muxer = builder.build()

            return ConfigurableInAppMp4Muxer(muxer, videoDurationUs)
        }

        override fun getSupportedSampleMimeTypes(trackType: Int): ImmutableList<String> {
            return when (trackType) {
                C.TRACK_TYPE_VIDEO -> Mp4Muxer.SUPPORTED_VIDEO_SAMPLE_MIME_TYPES
                C.TRACK_TYPE_AUDIO -> Mp4Muxer.SUPPORTED_AUDIO_SAMPLE_MIME_TYPES
                else -> ImmutableList.of()
            }
        }

        override fun supportsWritingNegativeTimestampsInEditList(): Boolean {
            return true
        }
    }

    override fun addTrack(format: Format): Int {
        val trackId = muxer.addTrack(format)
        if (MimeTypes.isVideo(format.sampleMimeType)) {
            muxer.addMetadataEntry(Mp4OrientationData(format.rotationDegrees))
            videoTrackId = trackId
        }
        return trackId
    }

    override fun writeSampleData(
        trackId: Int,
        byteBuffer: ByteBuffer,
        bufferInfo: BufferInfo
    ) {
        if (videoDurationUs != C.TIME_UNSET &&
            trackId == videoTrackId &&
            bufferInfo.presentationTimeUs > videoDurationUs
        ) {
            Log.w(
                TAG,
                String.format(
                    Locale.US,
                    "Skipped sample with presentation time (%d) > video duration (%d)",
                    bufferInfo.presentationTimeUs,
                    videoDurationUs
                )
            )
            return
        }
        muxer.writeSampleData(trackId, byteBuffer, bufferInfo)
    }

    override fun addMetadataEntry(metadataEntry: Metadata.Entry) {
        // Only keep orientation data, strip all other metadata (GPS, date, etc.)
        if (metadataEntry is Mp4OrientationData) {
            if (MuxerUtil.isMetadataSupported(metadataEntry)) {
                metadataEntries.add(metadataEntry)
            }
        }
    }

    override fun close() {
        if (videoDurationUs != C.TIME_UNSET && videoTrackId != TRACK_ID_UNSET) {
            val bufferInfo = BufferInfo(
                /* presentationTimeUs= */ videoDurationUs,
                /* size= */ 0,
                C.BUFFER_FLAG_END_OF_STREAM
            )
            writeSampleData(videoTrackId, ByteBuffer.allocateDirect(0), bufferInfo)
        }
        writeMetadata()
        muxer.close()
    }

    private fun writeMetadata() {
        for (entry in metadataEntries) {
            muxer.addMetadataEntry(entry)
        }
    }
}
