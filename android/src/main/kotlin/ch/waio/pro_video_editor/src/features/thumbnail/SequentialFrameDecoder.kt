package ch.waio.pro_video_editor.src.features.thumbnail

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.TreeSet

/**
 * Decodes frames at arbitrary timestamps with a single hardware MediaCodec
 * session in one forward pass through the stream.
 *
 * Unlike seek-per-frame approaches (MediaMetadataRetriever, Media3
 * FrameExtractor) each GOP is decoded at most once even when several
 * requested timestamps fall into it: non-target frames are decoded but never
 * rendered (cheap), target frames are rendered into a [SurfaceTexture] and
 * read back over OpenGL. The GPU performs the YUV to RGB conversion, which
 * also keeps proprietary decoder buffer layouts (e.g. Samsung SBWC) out of
 * the CPU path. GOPs without any requested timestamp are skipped via seek.
 * This mirrors how AVAssetImageGenerator batches sorted times on iOS/macOS.
 *
 * Frame selection matches MediaMetadataRetriever's OPTION_CLOSEST: the
 * sample timestamps are scanned up front (no decoding) and each requested
 * timestamp is mapped to the presentation time of the closest frame.
 */
class SequentialFrameDecoder(private val inputPath: String) {

    /**
     * Decodes the frames closest to [timestampsUs].
     *
     * Frames are rendered by the GPU directly at the aspect-preserving
     * thumbnail size derived from [outputWidth]/[outputHeight]/[boxFit]
     * (same formula as the bitmap resize used by the other extraction
     * paths), so a 4K source never round-trips at full resolution.
     *
     * [onFrame] is invoked on the decoding thread with the list of indices
     * into [timestampsUs] that resolve to the delivered frame (several
     * requested timestamps can map to the same frame) and the decoded,
     * rotation-corrected, already-resized bitmap. The callback owns the
     * bitmap.
     *
     * @throws Exception when the video cannot be decoded this way; callers
     *   are expected to fall back to another extraction path.
     */
    fun decode(
        timestampsUs: List<Long>,
        outputWidth: Int,
        outputHeight: Int,
        boxFit: String,
        onFrame: (indices: List<Int>, bitmap: Bitmap) -> Unit,
    ) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var frameReader: GlFrameReader? = null

        try {
            extractor.setDataSource(inputPath)
            val trackIndex = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("video/") == true
            }
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                format.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                0
            }
            // Rotation is applied to the bitmap below; the decoder must
            // deliver unrotated frames so the GL surface dimensions match.
            if (rotation != 0) format.setInteger(MediaFormat.KEY_ROTATION, 0)

            // Scan all sample timestamps without decoding to resolve each
            // requested timestamp to the closest real frame, and remember
            // sync samples for GOP skip-ahead.
            val samplePts = ArrayList<Long>(1024)
            val syncPts = TreeSet<Long>()
            while (true) {
                val time = extractor.sampleTime
                if (time >= 0) {
                    samplePts.add(time)
                    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                        syncPts.add(time)
                    }
                }
                if (!extractor.advance()) break
            }
            check(samplePts.isNotEmpty()) { "No video samples found" }
            samplePts.sort()

            // pts -> indices of requested timestamps resolving to that frame
            val targets = HashMap<Long, MutableList<Int>>()
            timestampsUs.forEachIndexed { index, timeUs ->
                targets.getOrPut(closestPts(samplePts, timeUs)) { mutableListOf() }.add(index)
            }
            val pendingPts = TreeSet(targets.keys)

            // Final thumbnail dimensions, computed on the rotated frame
            // size with the same formula as resizeBitmapKeepingAspect so
            // output dimensions stay identical to the other paths. The GL
            // pass renders at the pre-rotation orientation.
            val rotatedWidth = if (rotation % 180 == 0) width else height
            val rotatedHeight = if (rotation % 180 == 0) height else width
            val widthRatio = outputWidth.toFloat() / rotatedWidth
            val heightRatio = outputHeight.toFloat() / rotatedHeight
            val scale = when (boxFit.lowercase()) {
                "cover" -> maxOf(widthRatio, heightRatio)
                else -> minOf(widthRatio, heightRatio)
            }
            val finalWidth = (rotatedWidth * scale).toInt().coerceAtLeast(1)
            val finalHeight = (rotatedHeight * scale).toInt().coerceAtLeast(1)
            val renderWidth = if (rotation % 180 == 0) finalWidth else finalHeight
            val renderHeight = if (rotation % 180 == 0) finalHeight else finalWidth

            frameReader = GlFrameReader(renderWidth, renderHeight)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, frameReader.surface, null, 0)
            codec.start()

            extractor.seekTo(pendingPts.first(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var lastProgressAt = System.currentTimeMillis()

            while (pendingPts.isNotEmpty()) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
                if (outIndex >= 0) {
                    lastProgressAt = System.currentTimeMillis()
                    val pts = bufferInfo.presentationTimeUs
                    // Claim the exact target plus any pending target the
                    // decoder skipped past (e.g. frames dropped after an
                    // open-GOP seek); for those this frame is the closest
                    // one that can still be produced.
                    val claimed = mutableListOf<Long>()
                    if (bufferInfo.size > 0) {
                        if (pendingPts.remove(pts)) claimed.add(pts)
                        val missed = pendingPts.headSet(pts).toList()
                        if (missed.isNotEmpty()) {
                            pendingPts.removeAll(missed.toSet())
                            claimed.addAll(missed)
                        }
                    }
                    val isTarget = claimed.isNotEmpty()
                    codec.releaseOutputBuffer(outIndex, isTarget)
                    if (isTarget) {
                        val bitmap = frameReader.readFrame(rotation)
                        onFrame(claimed.flatMap { targets.getValue(it) }, bitmap)

                        // Skip ahead when the next target's GOP starts well
                        // after the current position. For small gaps decoding
                        // through is cheaper than a codec flush.
                        val next = pendingPts.firstOrNull()
                        if (next != null) {
                            val nextSync = syncPts.floor(next)
                            if (nextSync != null && nextSync - pts > MIN_SKIP_AHEAD_US) {
                                extractor.seekTo(next, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                                codec.flush()
                                inputDone = false
                            }
                        }
                    }
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                } else if (System.currentTimeMillis() - lastProgressAt > STALL_TIMEOUT_MS) {
                    throw IllegalStateException("Decoder stalled, ${pendingPts.size} frames left")
                }
            }

            check(pendingPts.size < targets.size) { "No frames could be decoded" }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            frameReader?.release()
            extractor.release()
        }
    }

    /** Returns the sample timestamp closest to [timeUs] (OPTION_CLOSEST). */
    private fun closestPts(sortedPts: List<Long>, timeUs: Long): Long {
        var index = sortedPts.binarySearch(timeUs)
        if (index >= 0) return sortedPts[index]
        index = -index - 1
        val after = sortedPts.getOrNull(index)
        val before = sortedPts.getOrNull(index - 1)
        return when {
            before == null -> after!!
            after == null -> before
            after - timeUs < timeUs - before -> after
            else -> before
        }
    }

    private companion object {
        const val DEQUEUE_TIMEOUT_US = 10_000L
        const val STALL_TIMEOUT_MS = 10_000L
        const val FRAME_WAIT_TIMEOUT_MS = 2_500L
        const val MIN_SKIP_AHEAD_US = 2_000_000L
    }

    /**
     * Offscreen GL consumer for decoder output.
     *
     * The decoder renders into [surface]; [readFrame] waits for the frame,
     * draws the external texture into a pbuffer and reads the pixels back
     * into a bitmap (grafika's CodecOutputSurface pattern).
     */
    private inner class GlFrameReader(private val width: Int, private val height: Int) {
        private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        private val textureId: Int
        private val program: Int
        private val surfaceTexture: SurfaceTexture
        private val listenerThread = HandlerThread("GlFrameReader").apply { start() }
        private val frameLock = Object()
        private var frameAvailable = false
        private val stMatrix = FloatArray(16)
        private val readBuffer: ByteBuffer =
            ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)

        val surface: Surface

        init {
            setupEgl()
            program = buildProgram()
            textureId = createExternalTexture()
            surfaceTexture = SurfaceTexture(textureId)
            surfaceTexture.setOnFrameAvailableListener(
                {
                    synchronized(frameLock) {
                        frameAvailable = true
                        frameLock.notifyAll()
                    }
                },
                Handler(listenerThread.looper)
            )
            surface = Surface(surfaceTexture)
        }

        /** Awaits the rendered frame, draws it and reads it back. */
        fun readFrame(rotation: Int): Bitmap {
            synchronized(frameLock) {
                val deadline = System.currentTimeMillis() + FRAME_WAIT_TIMEOUT_MS
                while (!frameAvailable) {
                    val waitMs = deadline - System.currentTimeMillis()
                    check(waitMs > 0) { "Timed out waiting for decoder frame" }
                    frameLock.wait(waitMs)
                }
                frameAvailable = false
            }
            surfaceTexture.updateTexImage()
            surfaceTexture.getTransformMatrix(stMatrix)

            GLES20.glViewport(0, 0, width, height)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(program)

            val positionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val texCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val stMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glUniformMatrix4fv(stMatrixLoc, 1, false, stMatrix, 0)
            GLES20.glEnableVertexAttribArray(positionLoc)
            GLES20.glVertexAttribPointer(positionLoc, 2, GLES20.GL_FLOAT, false, 0, QUAD_POSITIONS)
            GLES20.glEnableVertexAttribArray(texCoordLoc)
            GLES20.glVertexAttribPointer(texCoordLoc, 2, GLES20.GL_FLOAT, false, 0, QUAD_TEX_COORDS)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(positionLoc)
            GLES20.glDisableVertexAttribArray(texCoordLoc)

            readBuffer.rewind()
            GLES20.glReadPixels(
                0, 0, width, height,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, readBuffer
            )
            checkGlError("glReadPixels")

            readBuffer.rewind()
            var bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(readBuffer)
            if (rotation != 0) {
                val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, width, height, matrix, true)
                if (rotated !== bitmap) bitmap.recycle()
                bitmap = rotated
            }
            return bitmap
        }

        fun release() {
            surface.release()
            surfaceTexture.release()
            listenerThread.quitSafely()
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    eglDisplay,
                    EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
                )
                if (eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(eglDisplay, eglSurface)
                }
                if (eglContext != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglDestroyContext(eglDisplay, eglContext)
                }
                EGL14.eglReleaseThread()
                EGL14.eglTerminate(eglDisplay)
            }
        }

        private fun setupEgl() {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "No EGL display" }
            val version = IntArray(2)
            check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
                "Unable to initialize EGL"
            }
            val configAttributes = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            check(
                EGL14.eglChooseConfig(
                    eglDisplay, configAttributes, 0, configs, 0, 1, numConfigs, 0
                ) && numConfigs[0] > 0
            ) { "No suitable EGL config" }
            val config = configs[0]!!

            eglContext = EGL14.eglCreateContext(
                eglDisplay, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
            )
            check(eglContext != EGL14.EGL_NO_CONTEXT) { "Unable to create EGL context" }

            eglSurface = EGL14.eglCreatePbufferSurface(
                eglDisplay, config,
                intArrayOf(EGL14.EGL_WIDTH, width, EGL14.EGL_HEIGHT, height, EGL14.EGL_NONE), 0
            )
            check(eglSurface != EGL14.EGL_NO_SURFACE) { "Unable to create pbuffer surface" }
            check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                "eglMakeCurrent failed"
            }
        }

        private fun buildProgram(): Int {
            val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
            val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, vertexShader)
            GLES20.glAttachShader(program, fragmentShader)
            GLES20.glLinkProgram(program)
            val linked = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
            check(linked[0] == GLES20.GL_TRUE) {
                "Program link failed: ${GLES20.glGetProgramInfoLog(program)}"
            }
            GLES20.glDeleteShader(vertexShader)
            GLES20.glDeleteShader(fragmentShader)
            return program
        }

        private fun compileShader(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val compiled = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
            check(compiled[0] == GLES20.GL_TRUE) {
                "Shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}"
            }
            return shader
        }

        private fun createExternalTexture(): Int {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE
            )
            checkGlError("createExternalTexture")
            return textures[0]
        }

        private fun checkGlError(op: String) {
            val error = GLES20.glGetError()
            check(error == GLES20.GL_NO_ERROR) { "$op: glError 0x${error.toString(16)}" }
        }
    }
}

/**
 * Full-viewport quad. Texture coordinates are flipped vertically so the
 * bottom-up GL read-back lands top-down in the bitmap.
 */
private val QUAD_POSITIONS = floatBufferOf(
    -1f, -1f,
    1f, -1f,
    -1f, 1f,
    1f, 1f,
)
private val QUAD_TEX_COORDS = floatBufferOf(
    0f, 1f,
    1f, 1f,
    0f, 0f,
    1f, 0f,
)

private fun floatBufferOf(vararg values: Float): java.nio.FloatBuffer =
    ByteBuffer.allocateDirect(values.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(values)
            rewind()
        }

private const val VERTEX_SHADER = """
uniform mat4 uSTMatrix;
attribute vec4 aPosition;
attribute vec4 aTextureCoord;
varying vec2 vTextureCoord;
void main() {
    gl_Position = aPosition;
    vTextureCoord = (uSTMatrix * aTextureCoord).xy;
}
"""

private const val FRAGMENT_SHADER = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vTextureCoord;
uniform samplerExternalOES sTexture;
void main() {
    gl_FragColor = texture2D(sTexture, vTextureCoord);
}
"""
