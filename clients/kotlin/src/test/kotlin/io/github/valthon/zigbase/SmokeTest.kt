package io.github.valthon.zigbase

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class SmokeTest {
    @Test
    fun `version constant matches project version`() {
        assertEquals("0.1.0", ZIGBASE_CLIENT_VERSION)
    }
}
