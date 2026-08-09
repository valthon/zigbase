package io.github.valthon.zigbase.errors

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ZigbaseExceptionTest {
    @Test
    fun `captures status, message, data, and url`() {
        val err =
            ZigbaseException(
                status = 400,
                message = "Failed to validate the request.",
                data = mapOf("email" to FieldError("validation_required", "Missing.")),
                url = "http://x/api/collections/users/records",
            )
        assertEquals(400, err.status)
        assertEquals("Failed to validate the request.", err.message)
        assertEquals("validation_required", err.data["email"]?.code)
        assertEquals("Missing.", err.data["email"]?.message)
        assertEquals("http://x/api/collections/users/records", err.url)
    }

    @Test
    fun `toString includes status, message, and url`() {
        val err = ZigbaseException(status = 400, message = "Bad request.", url = "http://x/api/y")
        assertEquals("ZigbaseException(400): Bad request. (http://x/api/y)", err.toString())
    }

    @Test
    fun `data defaults to an empty map`() {
        val err = ZigbaseException(status = 500, message = "oops", url = "http://x")
        assertTrue(err.data.isEmpty())
    }
}

class ParseErrorResponseTest {
    @Test
    fun `parses a zigbase error response body`() {
        val body = """{"status":403,"code":"forbidden","message":"Forbidden.","data":{}}"""
        val err = parseErrorResponse(403, body, "http://x/api/y")
        assertEquals(403, err.status)
        assertEquals("Forbidden.", err.message)
        assertTrue(err.data.isEmpty())
        // The frozen machine code must survive the transport.
        assertEquals("forbidden", err.code)
    }

    @Test
    fun `exposes a bespoke code so callers never match on message text`() {
        val body =
            """{"status":403,"code":"email_not_verified","message":"Email not verified.","data":{}}"""
        val err = parseErrorResponse(403, body, "http://x/api/y")
        // Same status as a plain `forbidden`; only `code` tells them apart.
        assertEquals(403, err.status)
        assertEquals("email_not_verified", err.code)
    }

    @Test
    fun `ignores a non-string code`() {
        // Pre-unification servers put the integer HTTP status in `code`.
        val body = """{"code":403,"message":"Forbidden."}"""
        val err = parseErrorResponse(403, body, "http://x/api/y")
        assertEquals("", err.code)
    }

    @Test
    fun `code is empty when the body is not JSON`() {
        val err = parseErrorResponse(502, "oops", "http://x/api/y")
        assertEquals("", err.code)
    }

    @Test
    fun `parses field-level error data`() {
        val body =
            """
            {
              "message": "Failed to validate the request.",
              "data": {"email": {"code": "validation_required", "message": "Missing."}}
            }
            """.trimIndent()
        val err = parseErrorResponse(400, body, "http://x/api/y")
        assertEquals(400, err.status)
        assertEquals("Failed to validate the request.", err.message)
        assertEquals("validation_required", err.data["email"]?.code)
        assertEquals("Missing.", err.data["email"]?.message)
    }

    @Test
    fun `falls back to reasonPhrase when body is not JSON`() {
        val err = parseErrorResponse(500, "oops", "http://x/api/y", reasonPhrase = "Internal Server Error")
        assertEquals(500, err.status)
        assertEquals("Internal Server Error", err.message)
        assertTrue(err.data.isEmpty())
    }

    @Test
    fun `falls back to a generic message when there is no reasonPhrase`() {
        val err = parseErrorResponse(500, "oops", "http://x/api/y")
        assertEquals(500, err.status)
        assertEquals("Request failed with status 500", err.message)
    }

    @Test
    fun `falls back to a generic message when reasonPhrase is blank`() {
        val err = parseErrorResponse(502, "oops", "http://x/api/y", reasonPhrase = "")
        assertEquals("Request failed with status 502", err.message)

        val blankErr = parseErrorResponse(502, "oops", "http://x/api/y", reasonPhrase = "   ")
        assertEquals("Request failed with status 502", blankErr.message)
    }

    @Test
    fun `skips malformed field-error entries but keeps the valid one`() {
        val body =
            """
            {
              "message": "Failed to validate the request.",
              "data": {
                "email": {"code": "validation_required", "message": "Missing."},
                "title": "not-an-object",
                "age": {"code": 123, "message": "Bad."},
                "views": {"code": "invalid"}
              }
            }
            """.trimIndent()
        val err = parseErrorResponse(400, body, "http://x/api/y")
        assertEquals(setOf("email"), err.data.keys)
        assertEquals("validation_required", err.data["email"]?.code)
        assertTrue("title" !in err.data)
        assertTrue("age" !in err.data)
        assertTrue("views" !in err.data)
    }

    @Test
    fun `ignores a non-object data field`() {
        val body = """{"message":"oops","data":"not-a-dict"}"""
        val err = parseErrorResponse(400, body, "http://x/api/y")
        assertTrue(err.data.isEmpty())
    }

    @Test
    fun `ignores a non-string message field`() {
        val body = """{"message":12345}"""
        val err = parseErrorResponse(400, body, "http://x/api/y", reasonPhrase = "Bad Request")
        assertEquals("Bad Request", err.message)
    }
}
