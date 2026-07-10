package io.github.valthon.zigbase

import java.io.File

/**
 * A file to upload as a multipart part of a record create/update body.
 *
 * Port of the file-arg union in `clients/python/src/zigbase/_multipart.py`
 * (`IO[bytes] | tuple[str, bytes] | tuple[str, bytes, str]`) and the
 * `http.MultipartFile` values `clients/dart/lib/src/records.dart` expects.
 * Kotlin has no ambient "readable stream" union type, so this is a closed
 * sealed hierarchy instead: [Bytes] for content already in memory,
 * [FromFile] for content backed by a filesystem [File]. Present a [FileArg]
 * as the value of a body map key (or inside a top-level `List` of them,
 * repeating the key once per file) to force that request to be sent as
 * `multipart/form-data` instead of JSON -- see
 * `io.github.valthon.zigbase.internal.hasFile` /
 * `io.github.valthon.zigbase.internal.encodeBody`.
 */
sealed class FileArg {
    /** A file whose bytes are already in memory. */
    class Bytes(
        val filename: String,
        val content: ByteArray,
        val contentType: String? = null,
    ) : FileArg()

    /**
     * A file backed by a filesystem [File]. [filename] is [File.getName].
     *
     * Bytes are read from disk exactly once, at encode time, and buffered
     * into the resulting `EncodedBody` -- a retrying transport can resend
     * those buffered bytes any number of times without touching the
     * filesystem again, and mutating [file] after encoding cannot
     * retroactively change a request that has already been encoded.
     */
    class FromFile(
        val file: File,
        val contentType: String? = null,
    ) : FileArg()
}
