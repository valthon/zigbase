package io.github.valthon.zigbase.auth

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/*
 * PKCE (RFC 7636) verifier/challenge helpers for the OAuth2 authorization-code flow.
 *
 * Port of `generate_code_verifier`/`code_challenge_s256` in
 * `clients/python/src/zigbase/pkce.py` (itself a port of
 * `clients/typescript/src/pkce.ts` / `clients/dart/lib/src/pkce.dart`).
 * `SecureRandom` supplies the randomness -- the verifier is a credential,
 * not a display token.
 */

private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

private val secureRandom = SecureRandom()

/**
 * A random PKCE verifier drawn from the RFC 7636 unreserved charset
 * (`[A-Za-z0-9-._~]`). The default [length] of `64` sits inside RFC 7636's
 * required 43-128 character range; also reusable at other lengths (e.g. an
 * OAuth2 `state` value).
 */
fun generateCodeVerifier(length: Int = 64): String {
    val sb = StringBuilder(length)
    repeat(length) { sb.append(UNRESERVED[secureRandom.nextInt(UNRESERVED.length)]) }
    return sb.toString()
}

/**
 * The S256 PKCE challenge for [verifier]: the base64url encoding (unpadded)
 * of `sha256(ascii(verifier))`.
 */
fun codeChallengeS256(verifier: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
    return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
}
