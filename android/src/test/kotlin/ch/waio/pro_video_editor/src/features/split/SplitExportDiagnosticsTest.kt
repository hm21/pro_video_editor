package ch.waio.pro_video_editor.src.features.split

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class SplitExportDiagnosticsTest {

    private fun diag(
        half: String = "end",
        segmentUs: Long = 520_000L,
        splitUs: Long = 530_000L,
        totalUs: Long = 1_050_000L,
        mimeType: String = "video/avc",
        enableAudio: Boolean = false,
    ) = SplitExportDiagnostics(half, segmentUs, splitUs, totalUs, mimeType, enableAudio)

    @Test
    fun context_rendersAllFieldsInSecondsWithTwoDecimals() {
        val ctx = diag().context(progress = 0.0)
        assertEquals(
            "[half=end progress=0.00 segment=0.52s split=0.53s total=1.05s " +
                "mime=video/avc audio=false]",
            ctx,
        )
    }

    @Test
    fun timeoutMessage_startsWithFixedPrefixThenContext() {
        val message = diag().timeoutMessage(seconds = 120, progress = 0.0)
        assertTrue(
            message.startsWith("Split export timed out after 120s [half=end progress=0.00"),
            "unexpected message: $message",
        )
    }

    @Test
    fun stallMessage_reportsNoProgressAndLastKnownFraction() {
        val message = diag(half = "start", segmentUs = 530_000L)
            .stallMessage(seconds = 12, progress = 0.5)
        assertTrue(
            message.startsWith("Split export stalled after 12s with no progress "),
            "unexpected prefix: $message",
        )
        assertTrue(message.contains("half=start"), message)
        assertTrue(message.contains("progress=0.50"), message)
    }

    @Test
    fun unknownDurations_renderAsQuestionMarkNotZero() {
        val ctx = diag(segmentUs = -1L, totalUs = -1L).context(progress = 0.0)
        assertTrue(ctx.contains("segment=?s"), ctx)
        assertTrue(ctx.contains("total=?s"), ctx)
        // A known duration must still format normally.
        assertTrue(ctx.contains("split=0.53s"), ctx)
    }
}
