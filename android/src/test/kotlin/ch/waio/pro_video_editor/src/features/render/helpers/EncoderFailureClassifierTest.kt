package ch.waio.pro_video_editor.src.features.render.helpers

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class EncoderFailureClassifierTest {

    /** Marks the throwables a test treats as transient codec failures. */
    private class FakeTransient(message: String) : Exception(message)

    private val fakeClassifier: (Throwable) -> Boolean = { it is FakeTransient }

    private fun isTransient(throwable: Throwable?) =
        EncoderFailureClassifier.isTransientResourceFailure(throwable, fakeClassifier)

    /** Wraps [root] in [depth] plain exceptions, outermost returned. */
    private fun chainOf(depth: Int, root: Throwable): Throwable {
        var current = root
        repeat(depth) { current = RuntimeException("wrapper", current) }
        return current
    }

    @Test
    fun nullFailure_isNotTransient() {
        assertFalse(isTransient(null))
    }

    @Test
    fun transientRootFailure_isDetected() {
        assertTrue(isTransient(FakeTransient("insufficient resource")))
    }

    @Test
    fun transientFailureBuriedInCauseChain_isDetected() {
        // Media3 wraps the codec exception several levels deep before it
        // surfaces as an ExportException.
        val buried = IllegalStateException(
            "export failed",
            RuntimeException("codec init", FakeTransient("reclaimed")),
        )
        assertTrue(isTransient(buried))
    }

    @Test
    fun configurationFailureWithoutCodecResourceCause_isNotTransient() {
        val chain = IllegalStateException(
            "export failed",
            IllegalArgumentException("unsupported profile"),
        )
        assertFalse(isTransient(chain))
    }

    @Test
    fun selfReferencingCause_terminates() {
        val looping = object : Throwable("loops onto itself") {
            override val cause: Throwable get() = this
        }
        assertFalse(isTransient(looping))
    }

    @Test
    fun cyclicCauseChain_terminates() {
        class Cyclic : Throwable() {
            var next: Throwable? = null
            override val cause: Throwable? get() = next
        }

        val first = Cyclic()
        val second = Cyclic()
        first.next = second
        second.next = first

        assertFalse(isTransient(first))
    }

    @Test
    fun transientCauseWithinDepthLimit_isDetected() {
        // The deepest link the walk is still guaranteed to inspect.
        val chain = chainOf(
            depth = EncoderFailureClassifier.MAX_CAUSE_DEPTH - 1,
            root = FakeTransient("insufficient resource"),
        )
        assertTrue(isTransient(chain))
    }

    @Test
    fun transientCauseBeyondDepthLimit_isNotDetected() {
        // Documents the deliberate cut-off: a chain this deep does not occur in
        // practice, and bounding the walk matters more than finding it.
        val chain = chainOf(
            depth = EncoderFailureClassifier.MAX_CAUSE_DEPTH,
            root = FakeTransient("insufficient resource"),
        )
        assertFalse(isTransient(chain))
    }

    @Test
    fun defaultClassifier_ignoresNonCodecFailures() {
        // The real classifier only reacts to MediaCodec.CodecException, which
        // cannot be constructed off-device; anything else must be permanent.
        assertFalse(
            EncoderFailureClassifier.isTransientResourceFailure(
                IllegalStateException("configure failed", IllegalArgumentException()),
            )
        )
    }
}
