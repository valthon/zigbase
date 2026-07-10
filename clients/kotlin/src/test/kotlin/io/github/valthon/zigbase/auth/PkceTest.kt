package io.github.valthon.zigbase.auth

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for [generateCodeVerifier]/[codeChallengeS256], mirroring
 * `clients/python/tests/test_pkce.py`.
 */
class PkceTest {
    private val unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".toSet()

    @Test
    fun `generateCodeVerifier default length and charset`() {
        val verifier = generateCodeVerifier()
        assertEquals(64, verifier.length)
        assertTrue(verifier.all { it in unreserved })
    }

    @Test
    fun `generateCodeVerifier custom length`() {
        val verifier = generateCodeVerifier(32)
        assertEquals(32, verifier.length)
        assertTrue(verifier.all { it in unreserved })
    }

    @Test
    fun `generateCodeVerifier is random`() {
        assertNotEquals(generateCodeVerifier(), generateCodeVerifier())
    }

    @Test
    fun `codeChallengeS256 matches the RFC 7636 Appendix B vector`() {
        // Hardcoded RFC 7636 Appendix B verifier/challenge pair -- re-deriving
        // the expectation with the same digest call under test would make
        // this tautological.
        val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        val expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        assertEquals(expected, codeChallengeS256(verifier))
    }

    @Test
    fun `codeChallengeS256 is unpadded base64url`() {
        val challenge = codeChallengeS256(generateCodeVerifier())
        assertFalse(challenge.contains("="))
        assertFalse(challenge.contains("+"))
        assertFalse(challenge.contains("/"))
    }

    @Test
    fun `codeChallengeS256 is deterministic`() {
        val verifier = generateCodeVerifier()
        assertEquals(codeChallengeS256(verifier), codeChallengeS256(verifier))
    }
}
