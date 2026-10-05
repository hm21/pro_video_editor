package ch.waio.pro_video_editor.src.features.render.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class CustomVideoEffectConfigTest {

    @Test
    fun fromMap_readsIdParamsAndRange() {
        val config = CustomVideoEffectConfig.fromMap(
            mapOf(
                "id" to "divine.echo",
                "params" to mapOf("intensity" to 0.7, "copies" to 5),
                "startUs" to 1_000_000,
                "endUs" to 3_000_000L,
            )
        )!!
        assertEquals("divine.echo", config.id)
        assertEquals(mapOf("intensity" to 0.7, "copies" to 5), config.params)
        assertEquals(1_000_000L, config.startUs)
        assertEquals(3_000_000L, config.endUs)
    }

    @Test
    fun fromMap_isNullWithoutAnId() {
        assertNull(CustomVideoEffectConfig.fromMap(mapOf("params" to emptyMap<String, Any>())))
        assertNull(CustomVideoEffectConfig.fromMap(mapOf("id" to "")))
    }

    @Test
    fun fromMap_defaultsToNoParamsAndTheWholeVideo() {
        val config = CustomVideoEffectConfig.fromMap(mapOf("id" to "a"))!!
        assertEquals(emptyMap(), config.params)
        assertNull(config.startUs)
        assertNull(config.endUs)
        assertTrue(config.isActiveAt(0))
    }

    @Test
    fun isActiveAt_isHalfOpen() {
        val config = CustomVideoEffectConfig("a", emptyMap(), startUs = 500, endUs = 900)
        assertFalse(config.isActiveAt(499))
        assertTrue(config.isActiveAt(500))
        assertTrue(config.isActiveAt(899))
        assertFalse(config.isActiveAt(900))
    }

    @Test
    fun keepsFrameAt_startsAsFarAheadOfTheStartAsTheEffectLooksBack() {
        val config = CustomVideoEffectConfig("a", emptyMap(), startUs = 1_000_000, endUs = 2_000_000)
        assertFalse(config.keepsFrameAt(699_999, maxOffsetUs = 300_000))
        assertTrue(config.keepsFrameAt(700_000, maxOffsetUs = 300_000))
        assertFalse(config.keepsFrameAt(2_000_000, maxOffsetUs = 300_000))
    }
}
