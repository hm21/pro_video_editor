package ch.waio.pro_video_editor.src.shared.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream

/**
 * EXIF-aware decoding of caller-supplied encoded images.
 *
 * A photo straight from a phone's gallery stores a portrait shot as *landscape*
 * pixels plus an EXIF `Orientation` tag saying how to turn them. [BitmapFactory]
 * decodes the pixels and drops the tag, so the image renders sideways.
 *
 * Every path that takes encoded bytes from the caller — the chroma-key
 * background, image layers, stop-motion frames — decodes through here, so they
 * agree with each other and with Darwin's `decodeOrientedImage`, which
 * normalizes the same way. The contract is: an encoded image renders the way
 * the user sees it in their photo library.
 */
internal object ImageOrientation {

    /** The eight orientations EXIF defines; anything else means "no transform". */
    private val DEFINED_ORIENTATIONS = intArrayOf(
        ExifInterface.ORIENTATION_NORMAL,
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL,
        ExifInterface.ORIENTATION_ROTATE_180,
        ExifInterface.ORIENTATION_FLIP_VERTICAL,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_TRANSVERSE,
        ExifInterface.ORIENTATION_ROTATE_270,
    )

    /** An encoded image's displayed size together with its EXIF orientation. */
    data class Probe(val width: Int, val height: Int, val orientation: Int)

    /**
     * Header-only probe: the **orientation-corrected** pixel size of [data] plus
     * the orientation itself, without holding a full-size bitmap.
     *
     * Returns null when the bytes do not decode.
     */
    fun probe(data: ByteArray): Probe? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
        return probeOf(opts.outWidth, opts.outHeight, data)
    }

    /**
     * [probe] for stored dimensions that are already known, skipping the header
     * decode.
     */
    fun probeOf(storedWidth: Int, storedHeight: Int, data: ByteArray): Probe {
        val orientation = read(data)
        val (width, height) = orientedSize(storedWidth, storedHeight, orientation)
        return Probe(width, height, orientation)
    }

    /**
     * The EXIF orientation stored in [data], always one of the eight defined
     * values.
     *
     * A file with no tag reports `ORIENTATION_UNDEFINED`, and unreadable bytes
     * report nothing at all; both come back as [ExifInterface.ORIENTATION_NORMAL]
     * so callers get a definite orientation rather than a value they have to
     * range-check themselves.
     */
    fun read(data: ByteArray): Int {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(data)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        return if (orientation in DEFINED_ORIENTATIONS) {
            orientation
        } else {
            ExifInterface.ORIENTATION_NORMAL
        }
    }

    /** Whether [orientation] exchanges the image's width and height. */
    fun swapsDimensions(orientation: Int): Boolean = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_ROTATE_270,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_TRANSVERSE -> true

        else -> false
    }

    /** [width]×[height] as it is displayed once [orientation] has been applied. */
    fun orientedSize(width: Int, height: Int, orientation: Int): Pair<Int, Int> =
        if (swapsDimensions(orientation)) Pair(height, width) else Pair(width, height)

    /**
     * Decodes [data] and applies its EXIF orientation, so portrait photos are not
     * rendered sideways.
     *
     * When both [reqWidth] and [reqHeight] are positive the bitmap is decoded
     * downscaled toward that size instead of at full resolution — worth passing
     * whenever the caller is going to scale the result down anyway, since it
     * saves both the oversized decode and the oversized rotation copy. The
     * request is in *displayed* pixels, i.e. after the orientation. [config],
     * when given, is passed on as `inPreferredConfig`.
     */
    fun decode(
        data: ByteArray,
        reqWidth: Int = 0,
        reqHeight: Int = 0,
        config: Bitmap.Config? = null,
    ): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        // `inSampleSize` measures the stored pixels, so the request has to be
        // turned back into stored space first — the same swap, since exchanging
        // the two dimensions is its own inverse.
        val orientation = read(data)
        val (srcReqWidth, srcReqHeight) = orientedSize(reqWidth, reqHeight, orientation)

        val opts = BitmapFactory.Options().apply {
            inSampleSize =
                sampleSizeFor(bounds.outWidth, bounds.outHeight, srcReqWidth, srcReqHeight)
            if (config != null) inPreferredConfig = config
        }
        val raw = BitmapFactory.decodeByteArray(data, 0, data.size, opts) ?: return null
        return orient(raw, orientation)
    }

    /**
     * Turns [bitmap] the way [orientation] says it should be displayed.
     *
     * **Takes ownership of [bitmap].** Returns a new bitmap and recycles
     * [bitmap] when the orientation calls for a transform; returns [bitmap]
     * untouched otherwise (including for the "undefined" orientation a file
     * without the tag reports). Either way the caller must use the return value
     * and treat [bitmap] as gone.
     */
    fun orient(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }

            else -> return bitmap
        }
        val transformed = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
        )
        if (transformed !== bitmap) bitmap.recycle()
        return transformed
    }

    /**
     * Largest power-of-two sample size that keeps the image ≥ the target size.
     *
     * A non-positive target means "no downscale", i.e. a sample size of 1.
     */
    fun sampleSizeFor(srcWidth: Int, srcHeight: Int, reqWidth: Int, reqHeight: Int): Int {
        if (reqWidth <= 0 || reqHeight <= 0) return 1
        var sample = 1
        var halfWidth = srcWidth / 2
        var halfHeight = srcHeight / 2
        while (halfWidth >= reqWidth && halfHeight >= reqHeight) {
            sample *= 2
            halfWidth /= 2
            halfHeight /= 2
        }
        return sample
    }
}
