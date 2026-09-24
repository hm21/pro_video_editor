package ch.waio.pro_video_editor.src.features.render.helpers

import android.media.MediaFormat
import androidx.media3.common.util.UnstableApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@UnstableApi
internal class RenderSourceFormatsTest {

    private fun info(mime: String?, bitDepth: Int? = null, transfer: Int? = null) =
        MediaInfoExtractor.VideoFormatInfo(
            isHevc = mime == "video/hevc",
            bitDepth = bitDepth ?: 8,
            isHdr = false,
            profile = null,
            mime = mime,
            colorTransfer = transfer,
            bitDepthStated = bitDepth != null,
        )

    @Test
    fun hdrSource_namesItsTransfer() {
        assertEquals(
            mapOf("mime" to "video/hevc", "bitDepth" to 10, "transfer" to "hlg"),
            RenderSourceFormats.describe(
                info("video/hevc", bitDepth = 10, transfer = MediaFormat.COLOR_TRANSFER_HLG)
            ),
        )
        assertEquals(
            "pq",
            RenderSourceFormats.describe(
                info("video/hevc", bitDepth = 10, transfer = MediaFormat.COLOR_TRANSFER_ST2084)
            )["transfer"],
        )
    }

    @Test
    fun sourceWithoutAStatedTransfer_leavesTheKeyOut() {
        assertEquals(
            mapOf("mime" to "video/avc", "bitDepth" to 8),
            RenderSourceFormats.describe(info("video/avc", bitDepth = 8)),
        )
    }

    @Test
    fun unstatedBitDepth_isLeftOutRatherThanAssumed() {
        // The transcode check falls back to 8; a 10-bit file whose extractor
        // states neither depth nor profile must not be reported as 8-bit.
        assertEquals(
            mapOf("mime" to "video/hevc", "transfer" to "hlg"),
            RenderSourceFormats.describe(
                info("video/hevc", transfer = MediaFormat.COLOR_TRANSFER_HLG)
            ),
        )
    }

    @Test
    fun unknownTransfer_keepsItsRawValue() {
        assertEquals(
            "42",
            RenderSourceFormats.describe(info("video/avc", transfer = 42))["transfer"],
        )
    }

    @Test
    fun repeatedFormat_isListedOnce() {
        val hlg = info("video/hevc", bitDepth = 10, transfer = MediaFormat.COLOR_TRANSFER_HLG)
        val sdr = info("video/avc", transfer = MediaFormat.COLOR_TRANSFER_SDR_VIDEO)

        assertEquals(
            listOf(
                mapOf("mime" to "video/avc", "transfer" to "sdr"),
                mapOf("mime" to "video/hevc", "bitDepth" to 10, "transfer" to "hlg"),
            ),
            RenderSourceFormats.describeDistinct(List(30) { sdr } + hlg + sdr),
        )
    }

    @Test
    fun unreadableSource_isAnEmptyEntry() {
        assertTrue(RenderSourceFormats.describe(info(mime = null)).isEmpty())
    }
}
