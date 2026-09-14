package ch.waio.pro_video_editor.src.shared

import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.ExportException
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

@UnstableApi
internal class FailureDetailsTest {

    @Test
    fun exportException_carriesItsMedia3CodeAndTheCauseUnderneath() {
        val root = IOException("write failed: ENOSPC (No space left on device)")
        val export = ExportException.createForAssetLoader(
            IllegalStateException("muxer", root),
            ExportException.ERROR_CODE_MUXING_FAILED,
        )

        val details = FailureDetails.of(export)

        assertEquals("androidx.media3.transformer.ExportException", details["domain"])
        assertEquals(ExportException.ERROR_CODE_MUXING_FAILED, details["code"])
        assertEquals("ERROR_CODE_MUXING_FAILED", details["codeName"])
        assertEquals(
            "java.lang.IllegalStateException: muxer <- " +
                "java.io.IOException: write failed: ENOSPC (No space left on device)",
            details["cause"],
        )
    }

    @Test
    fun wrappedExportException_keepsTheWrapperAsDomainAndTheCodeFromInside() {
        val export = ExportException.createForUnexpected(RuntimeException("gl"))
        val wrapper = IllegalStateException("render failed", export)

        val details = FailureDetails.of(wrapper)

        assertEquals("java.lang.IllegalStateException", details["domain"])
        assertEquals(ExportException.ERROR_CODE_FAILED_RUNTIME_CHECK, details["code"])
        assertEquals("ERROR_CODE_FAILED_RUNTIME_CHECK", details["codeName"])
        assertEquals(
            "androidx.media3.transformer.ExportException: Unexpected runtime error <- " +
                "java.lang.RuntimeException: gl",
            details["cause"],
        )
    }

    @Test
    fun plainThrowableWithoutCause_carriesOnlyItsType() {
        val details = FailureDetails.of(IllegalStateException("Render export stalled"))

        assertEquals("java.lang.IllegalStateException", details["domain"])
        assertNull(details["code"])
        assertNull(details["codeName"])
        assertNull(details["cause"])
    }

    @Test
    fun selfReferencingCause_terminates() {
        val looping = object : Throwable("loops onto itself") {
            override val cause: Throwable get() = this
        }

        val details = FailureDetails.of(looping)

        assertNull(details["cause"])
    }

    @Test
    fun causeChain_isCutOffAtTheDepthCap() {
        var current: Throwable = RuntimeException("level 0")
        repeat(20) { current = RuntimeException("level ${it + 1}", current) }

        val cause = FailureDetails.of(current)["cause"] as String

        assertEquals(8, cause.split(" <- ").size)
    }
}
