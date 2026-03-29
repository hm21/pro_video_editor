package ch.waio.pro_video_editor.src.features.audio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Utility class for writing WAV audio files with proper RIFF/WAVE format.
 *
 * This class handles the creation of WAV files by:
 * - Writing a proper RIFF/WAVE header
 * - Decoding compressed audio to PCM samples
 * - Writing PCM data in the correct format
 * - Updating the file size fields after writing
 */
class WavFileWriter(private val outputFile: File) {

    companion object {
        // Magic numbers for WAV format
        // Note: These are stored in little-endian byte order (reversed) so that when
        // written via a LITTLE_ENDIAN ByteBuffer, they appear correctly in the file.
        private const val RIFF_HEADER = 0x46464952 // "RIFF" in little-endian
        private const val WAVE_HEADER = 0x45564157 // "WAVE" in little-endian
        private const val FMT_HEADER = 0x20746d66  // "fmt " in little-endian
        private const val DATA_HEADER = 0x61746164 // "data" in little-endian
        private const val PCM_FORMAT = 1.toShort()
        private const val IEEE_FLOAT_FORMAT = 3.toShort()
        private const val BUFFER_SIZE = 1024 * 1024 // 1MB buffer
    }

    private var sampleRate: Int = 44100
    private var numChannels: Int = 2
    private var bitsPerSample: Int = 16
    private var isFloatPcm: Boolean = false
    private var totalDataSize: Long = 0

    /**
     * Extracts audio from a video file and writes it as a WAV file.
     *
     * @param extractor MediaExtractor configured with the source video
     * @param audioTrackIndex Index of the audio track in the extractor
     * @param startUs Optional start time in microseconds
     * @param endUs Optional end time in microseconds
     * @param onProgress Progress callback (0.0 to 1.0)
     * @param shouldStop Atomic boolean to check for cancellation
     * @throws Exception if extraction or writing fails
     */
    fun extractAndWrite(
        extractor: MediaExtractor,
        audioTrackIndex: Int,
        startUs: Long = 0L,
        endUs: Long = Long.MAX_VALUE,
        onProgress: (Double) -> Unit = {},
        shouldStop: () -> Boolean = { false }
    ) {
        val audioFormat = extractor.getTrackFormat(audioTrackIndex)

        sampleRate = audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        numChannels = audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        bitsPerSample = 16 // PCM 16-bit is standard

        val mime = audioFormat.getString(MediaFormat.KEY_MIME) ?: throw IllegalArgumentException("No MIME type in audio format")

        val isPcm = mime.equals("audio/raw", ignoreCase = true) ||
                           mime.equals("audio/pcm", ignoreCase = true)
        if (isPcm) {
            extractPcmToWav(extractor, audioTrackIndex, startUs, endUs, onProgress, shouldStop)
        } else {
            extractAndDecodeToWav(extractor, audioFormat, audioTrackIndex, startUs, endUs, onProgress, shouldStop)
        }
    }

    /**
     * Extracts compressed audio and decodes it to PCM WAV format.
     */
    private fun extractAndDecodeToWav(
        extractor: MediaExtractor,
        audioFormat: MediaFormat,
        audioTrackIndex: Int,
        startUs: Long,
        endUs: Long,
        onProgress: (Double) -> Unit,
        shouldStop: () -> Boolean
    ) {
        var decoder: MediaCodec? = null
        var outputStream: FileOutputStream? = null

        try {
            totalDataSize = 0

            val mime = audioFormat.getString(MediaFormat.KEY_MIME)!!
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(audioFormat, null, null, 0)
            decoder.start()

            // Get the decoder's ACTUAL output format immediately after starting
            // don't rely on INFO_OUTPUT_FORMAT_CHANGED which may not be sent
            val decoderOutputFormat = decoder.outputFormat
            
            // output parameters from decoder
            sampleRate = if (decoderOutputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                decoderOutputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else {
                audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            }
            
            numChannels = if (decoderOutputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                decoderOutputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else {
                audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            }
            
            // Determine bits per sample from PCM encoding
            // Convert float PCM to 16-bit integer for compatibility
            if (decoderOutputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                val pcmEncoding = decoderOutputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                when (pcmEncoding) {
                    AudioFormat.ENCODING_PCM_16BIT -> {
                        bitsPerSample = 16
                        isFloatPcm = false
                    }
                    AudioFormat.ENCODING_PCM_8BIT -> {
                        bitsPerSample = 8
                        isFloatPcm = false
                    }
                    AudioFormat.ENCODING_PCM_FLOAT -> {
                        // Convert float to 16-bit for better compatibility
                        bitsPerSample = 16
                        isFloatPcm = true
                    }
                    else -> {
                        bitsPerSample = 16
                        isFloatPcm = false
                    }
                }
            } else {
                bitsPerSample = 16
                isFloatPcm = false
            }

            extractor.selectTrack(audioTrackIndex)

            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            outputStream = FileOutputStream(outputFile)

            // Write initial WAV header with decoder output format
            // We'll update the sizes at the end
            writeWavHeader(outputStream, 0)

            val validEndUs = if (endUs == Long.MAX_VALUE) Long.MAX_VALUE else endUs
            val totalDurationUs = if (validEndUs == Long.MAX_VALUE) Long.MAX_VALUE else (validEndUs - startUs)
            var currentTimeUs = startUs
            var inputEos = false
            var outputEos = false

            onProgress(0.0)

            while (!outputEos && !shouldStop()) {
                if (!inputEos) {
                    val inputBufferId = decoder.dequeueInputBuffer(10000)
                    if (inputBufferId >= 0) {
                        val decoderInputBuffer = decoder.getInputBuffer(inputBufferId)!!
                        decoderInputBuffer.clear()

                        val sampleSize = extractor.readSampleData(decoderInputBuffer, 0)
                        val presentationTimeUs = extractor.sampleTime

                        if (sampleSize < 0 || presentationTimeUs > validEndUs) {
                            // End of stream or reached end time
                            decoder.queueInputBuffer(inputBufferId, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEos = true
                        } else {
                            decoder.queueInputBuffer(inputBufferId, 0, sampleSize, presentationTimeUs, 0)
                            extractor.advance()
                            currentTimeUs = presentationTimeUs

                            if (totalDurationUs != Long.MAX_VALUE) {
                                val progress = ((currentTimeUs - startUs).toDouble() / totalDurationUs).coerceIn(0.0, 1.0)
                                onProgress(progress)
                            }
                        }
                    }
                }

                val bufferInfo = MediaCodec.BufferInfo()
                val outputBufferId = decoder.dequeueOutputBuffer(bufferInfo, 10000)

                when {
                    outputBufferId == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // Output format changed during decoding - update our parameters
                        val newOutputFormat = decoder.outputFormat
                        
                        var formatChanged = false
                        if (newOutputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            val newSampleRate = newOutputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            if (newSampleRate != sampleRate) {
                                sampleRate = newSampleRate
                                formatChanged = true
                            }
                        }
                        if (newOutputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            val newChannels = newOutputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            if (newChannels != numChannels) {
                                numChannels = newChannels
                                formatChanged = true
                            }
                        }
                        if (newOutputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            val pcmEncoding = newOutputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            when (pcmEncoding) {
                                AudioFormat.ENCODING_PCM_16BIT -> {
                                    if (bitsPerSample != 16 || isFloatPcm) {
                                        bitsPerSample = 16
                                        isFloatPcm = false
                                        formatChanged = true
                                    }
                                }
                                AudioFormat.ENCODING_PCM_8BIT -> {
                                    if (bitsPerSample != 8 || isFloatPcm) {
                                        bitsPerSample = 8
                                        isFloatPcm = false
                                        formatChanged = true
                                    }
                                }
                                AudioFormat.ENCODING_PCM_FLOAT -> {
                                    // Convert float to 16-bit for compatibility
                                    if (bitsPerSample != 16 || !isFloatPcm) {
                                        bitsPerSample = 16
                                        isFloatPcm = true
                                        formatChanged = true
                                    }
                                }
                                else -> {
                                    if (bitsPerSample != 16 || isFloatPcm) {
                                        bitsPerSample = 16
                                        isFloatPcm = false
                                        formatChanged = true
                                    }
                                }
                            }
                        }
                        
                        // If format changed, rewrite the header
                        if (formatChanged) {
                            outputStream.flush()
                            val raf = RandomAccessFile(outputFile, "rw")
                            raf.seek(0L)
                            
                            val byteRate = sampleRate * numChannels * bitsPerSample / 8
                            val blockAlign = (numChannels * bitsPerSample / 8).toShort()
                            
                            val headerBytes = ByteBuffer.allocate(44).apply {
                                // All values written in little-endian order
                                // Magic number constants are pre-encoded for little-endian
                                order(ByteOrder.LITTLE_ENDIAN)
                                putInt(RIFF_HEADER)
                                putInt(0)  // Will update at end
                                putInt(WAVE_HEADER)
                                
                                putInt(FMT_HEADER)
                                putInt(16)
                                putShort(PCM_FORMAT)
                                putShort(numChannels.toShort())
                                putInt(sampleRate)
                                putInt(byteRate)
                                putShort(blockAlign)
                                putShort(bitsPerSample.toShort())
                                
                                putInt(DATA_HEADER)
                                putInt(0)  // Will update at end
                            }.array()
                            
                            raf.write(headerBytes)
                            raf.close()
                        }
                    }
                    outputBufferId >= 0 -> {
                        val decoderOutputBuffer = decoder.getOutputBuffer(outputBufferId)!!

                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEos = true
                        }

                        if (bufferInfo.size > 0) {
                            // Get PCM data from decoder output buffer
                            decoderOutputBuffer.position(bufferInfo.offset)
                            decoderOutputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            
                            if (isFloatPcm) {
                                // Convert float PCM to 16-bit integer PCM
                                val floatSamples = bufferInfo.size / 4 // 4 bytes per float
                                val int16Buffer = ByteBuffer.allocate(floatSamples * 2) // 2 bytes per int16
                                int16Buffer.order(ByteOrder.LITTLE_ENDIAN)
                                
                                for (i in 0 until floatSamples) {
                                    val floatValue = decoderOutputBuffer.float
                                    // Clamp and convert float [-1.0, 1.0] to int16 [-32768, 32767]
                                    val intValue = (floatValue.coerceIn(-1.0f, 1.0f) * 32767.0f).toInt().toShort()
                                    int16Buffer.putShort(intValue)
                                }
                                
                                outputStream.write(int16Buffer.array())
                                totalDataSize += int16Buffer.array().size
                            } else {
                                // Write PCM data directly (already in correct format)
                                val pcmData = ByteArray(bufferInfo.size)
                                decoderOutputBuffer.get(pcmData)
                                outputStream.write(pcmData)
                                totalDataSize += pcmData.size
                            }
                        }

                        decoder.releaseOutputBuffer(outputBufferId, false)
                    }
                }
            }

            outputStream.flush()
            outputStream.close()
            outputStream = null

            // Update WAV header with actual sizes
            updateWavHeader()

            onProgress(1.0)

        } finally {
            outputStream?.close()
            decoder?.stop()
            decoder?.release()
        }
    }

    /**
     * Extracts PCM audio directly without decoding.
     */
    private fun extractPcmToWav(
        extractor: MediaExtractor,
        audioTrackIndex: Int,
        startUs: Long,
        endUs: Long,
        onProgress: (Double) -> Unit,
        shouldStop: () -> Boolean
    ) {
        var outputStream: FileOutputStream? = null

        try {
            // Reset total data size for this extraction
            totalDataSize = 0

            // Select the audio track in the extractor
            extractor.selectTrack(audioTrackIndex)

            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }

            outputStream = FileOutputStream(outputFile)

            // Write placeholder WAV header
            writeWavHeader(outputStream, 0)

            val buffer = ByteBuffer.allocate(BUFFER_SIZE)
            val validEndUs = if (endUs == Long.MAX_VALUE) Long.MAX_VALUE else endUs
            val totalDurationUs = if (validEndUs == Long.MAX_VALUE) Long.MAX_VALUE else (validEndUs - startUs)
            var currentTimeUs = startUs

            onProgress(0.0)

            while (!shouldStop()) {
                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)

                if (sampleSize < 0) {
                    // End of stream
                    break
                }

                val presentationTimeUs = extractor.sampleTime

                if (presentationTimeUs > validEndUs) {
                    break
                }

                buffer.position(0)
                buffer.limit(sampleSize)

                val pcmData = ByteArray(sampleSize)
                buffer.get(pcmData)
                outputStream.write(pcmData)
                totalDataSize += sampleSize

                currentTimeUs = presentationTimeUs
                if (totalDurationUs != Long.MAX_VALUE) {
                    val progress = ((currentTimeUs - startUs).toDouble() / totalDurationUs).coerceIn(0.0, 1.0)
                    onProgress(progress)
                }

                extractor.advance()
            }

            outputStream.flush()
            outputStream.close()
            outputStream = null

            // Update WAV header with actual sizes
            updateWavHeader()

            onProgress(1.0)

        } finally {
            outputStream?.close()
        }
    }

    /**
     * Writes a WAV file header with RIFF/WAVE format.
     *
     * Note: RIFF files have a 4GB limit due to 32-bit size fields. This is a WAV format limitation.
     */
    private fun writeWavHeader(outputStream: FileOutputStream, dataSize: Long) {
        val header = ByteBuffer.allocate(44)
        header.order(ByteOrder.LITTLE_ENDIAN)

        val byteRate = sampleRate * numChannels * bitsPerSample / 8
        val blockAlign = (numChannels * bitsPerSample / 8).toShort()

        // Ensure dataSize doesn't exceed 32-bit signed integer limit for WAV format
        // WAV files are limited to 4GB due to 32-bit size fields in RIFF format
        val safeSizeForHeader = if (dataSize > 0x7FFFFFFFL) {
            0x7FFFFFFF
        } else {
            dataSize.toInt()
        }

        // RIFF header - all values written in little-endian order
        // Magic number constants are pre-encoded for little-endian
        header.putInt(RIFF_HEADER)                          // "RIFF"
        header.putInt(36 + safeSizeForHeader)               // File size - 8
        header.putInt(WAVE_HEADER)                          // "WAVE"

        // fmt sub-chunk
        header.putInt(FMT_HEADER)                           // "fmt "
        header.putInt(16)                                   // Sub-chunk size (16 for PCM)
        header.putShort(PCM_FORMAT)                         // Audio format (1 = PCM)
        header.putShort(numChannels.toShort())              // Number of channels
        header.putInt(sampleRate)                           // Sample rate
        header.putInt(byteRate)                             // Byte rate
        header.putShort(blockAlign)                         // Block align
        header.putShort(bitsPerSample.toShort())            // Bits per sample

        // data sub-chunk
        header.putInt(DATA_HEADER)                          // "data"
        header.putInt(safeSizeForHeader)                    // Data size

        outputStream.write(header.array())
    }

    /**
     * Updates the WAV header with the actual file sizes after writing is complete.
     * 
     * Note: WAV files are limited to 4GB due to 32-bit size fields. If the file exceeds this,
     * the header size fields will be clamped to the maximum 32-bit signed integer value.
     */
    private fun updateWavHeader() {
        // Ensure totalDataSize doesn't exceed 32-bit limit
        val safeSizeForHeader = if (totalDataSize > 0x7FFFFFFFL) {
            0x7FFFFFFF
        } else {
            totalDataSize.toInt()
        }

        RandomAccessFile(outputFile, "rw").use { raf ->
            // Update file size at byte 4 (RIFF chunk size = 36 + data size)
            // RIFF chunk size = file size - 8 bytes
            raf.seek(4L)
            val riffSize = 36 + safeSizeForHeader
            raf.write(ByteBuffer.allocate(4).apply {
                order(ByteOrder.LITTLE_ENDIAN)
                putInt(riffSize)
                flip()
            }.array())

            // Update data size at byte 40 (data chunk size)
            raf.seek(40L)
            raf.write(ByteBuffer.allocate(4).apply {
                order(ByteOrder.LITTLE_ENDIAN)
                putInt(safeSizeForHeader)
                flip()
            }.array())
        }
    }
}
