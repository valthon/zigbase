/// The HTTP engine every service builds on: URL assembly, header injection,
/// JSON/multipart bodies, 401 one-shot refresh, 429 backoff, and opt-in
/// `requestKey` de-duplication.
///
/// This is an internal module — it is intentionally **not** exported from
/// `zigbase_client.dart`; consumers reach it only through the typed service
/// classes. The semantics are a port of `clients/typescript/src/transport.ts`;
/// see the notes on each method for the deliberate Dart-specific deviations
/// (chiefly `requestKey`, which cannot abort a live socket with `package:http`
/// and instead resolves the loser's future with [ZigbaseCancelledException]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'auth_store.dart';
import 'errors.dart';
import 'records.dart';

/// Ceiling for the exponential 429 backoff — a high attempt count can never
/// request an absurd multi-minute sleep.
const Duration _maxBackoff = Duration(seconds: 30);

Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

/// Formats a [DateTime] as a UTC ISO-8601 string clamped to millisecond
/// precision, matching JS `Date.prototype.toJSON` byte-for-byte — the same
/// (deliberately duplicated, library-private) helper as in
/// `lib/src/records.dart` and `lib/src/query.dart`; see the latter for the
/// full rationale. Kept private per file because every `lib/src` module is
/// barrel-exported, so a shared non-underscore helper would expand the
/// public API.
String _formatDateTime(DateTime value) {
  final utc = value.toUtc();
  final clamped = utc.microsecond == 0
      ? utc
      : utc.subtract(Duration(microseconds: utc.microsecond));
  return clamped.toIso8601String();
}

/// JSON-encode a request body the way JS `JSON.stringify` would: a nested
/// [DateTime] serializes via its `toJSON`-equivalent (ms-clamped UTC
/// ISO-8601). Anything else non-encodable is rejected loudly as an
/// [ArgumentError] naming the offending runtime type — the same posture as
/// `encodeMultipart` in `lib/src/records.dart` (TS would silently emit `{}`
/// garbage for such values).
String _jsonEncodeBody(Object? body) {
  try {
    return jsonEncode(body,
        toEncodable: (Object? nested) =>
            nested is DateTime ? _formatDateTime(nested) : nested);
  } on JsonUnsupportedObjectError catch (e) {
    throw ArgumentError.value(
        e.unsupportedObject,
        'body',
        'send: body contains a value that is cyclic or not JSON-encodable '
            '(${e.unsupportedObject.runtimeType})');
  }
}

/// One caller-supplied file part, buffered to bytes so a fresh (unfinalized)
/// [http.MultipartFile] can be rebuilt for every retry attempt. package:http
/// marks a MultipartFile finalized after its first send and throws on reuse,
/// so the same instance cannot survive a 401-refresh or 429-backoff retry.
class _BufferedFile {
  final String field;
  final String? filename;
  final MediaType contentType;
  final List<int> bytes;

  _BufferedFile(this.field, this.filename, this.contentType, this.bytes);

  http.MultipartFile toPart() => http.MultipartFile.fromBytes(field, bytes,
      filename: filename, contentType: contentType);
}

/// A multipart body encoded + buffered ONCE per logical call, from which each
/// attempt builds a fresh [http.MultipartRequest].
class _BufferedMultipart {
  final Map<String, List<String>> fields;
  final List<_BufferedFile> files;

  _BufferedMultipart(this.fields, this.files);
}

class Transport {
  final String _baseUrl;
  final AuthStore _authStore;
  final http.Client _httpClient;
  final bool _autoRefresh;
  final int _maxRetries;
  final String? _lang;
  final String? _accountId;
  final Future<void> Function(Duration) _sleep;
  Future<void> Function()? _refresh;

  /// Cancel tokens keyed by `requestKey`, for opt-in last-write-wins
  /// de-duplication. Each token's future completes (with error) only when a
  /// newer keyed request supersedes the one that owns it.
  final Map<String, Completer<Never>> _inflight = {};

  Transport({
    required String baseUrl,
    required AuthStore authStore,
    required http.Client httpClient,
    bool autoRefresh = false,
    int maxRetries = 3,
    String? lang,
    String? accountId,
    Future<void> Function()? refresh,
    Future<void> Function(Duration)? sleep,
  })  : _baseUrl = baseUrl,
        _authStore = authStore,
        _httpClient = httpClient,
        _autoRefresh = autoRefresh,
        _maxRetries = maxRetries,
        _lang = lang,
        _accountId = accountId,
        _refresh = refresh,
        _sleep = sleep ?? _defaultSleep;

  String get baseUrl => _baseUrl;

  /// Wire the refresh callback after construction (the [ZigbaseClient] closes
  /// over the auth service, which in turn needs this transport, so the wiring
  /// is deferred past both constructors).
  set refresh(Future<void> Function()? fn) => _refresh = fn;

  /// Build the absolute request [Uri]. [path] is appended to [baseUrl] (whose
  /// trailing slashes are trimmed) unless it already starts with `http`, in
  /// which case it is used verbatim. A relative [path] that does not begin with
  /// `/` gets a separator inserted so `buildUrl('api/x')` and
  /// `buildUrl('/api/x')` resolve identically (internal callers always pass a
  /// leading slash; this guards the public surface). [query] entries with a
  /// `null` value are skipped; every other value is stringified and
  /// url-encoded. A [query] key that duplicates one already present in
  /// [path]'s own query string is **appended**, not overwritten — both values
  /// survive (matching the TS SDK's `URLSearchParams`-append behavior), so
  /// the resulting [Uri] can carry the same key twice.
  Uri buildUrl(String path, [Map<String, dynamic>? query]) {
    final base = _baseUrl.replaceAll(RegExp(r'/+$'), '');
    final String raw;
    if (path.startsWith('http')) {
      raw = path;
    } else if (path.isEmpty || path.startsWith('/')) {
      raw = '$base$path';
    } else {
      raw = '$base/$path';
    }
    final parsed = Uri.parse(raw);
    if (query == null || query.isEmpty) return parsed;

    final params = <String, List<String>>{};
    parsed.queryParametersAll
        .forEach((key, values) => params[key] = List<String>.from(values));
    var added = false;
    for (final entry in query.entries) {
      final value = entry.value;
      if (value == null) continue;
      params.putIfAbsent(entry.key, () => <String>[]).add(value.toString());
      added = true;
    }
    // Nothing added (all values null): return the parsed Uri untouched
    // instead of rebuilding an identical one.
    if (!added) return parsed;
    final qp = <String, dynamic>{
      for (final entry in params.entries)
        entry.key: entry.value.length == 1 ? entry.value.first : entry.value,
    };
    return parsed.replace(queryParameters: qp);
  }

  /// Issue a request and return its parsed JSON body (or `null` for a 204 /
  /// empty body). Non-2xx responses throw a [ZigbaseException]; a 401 may
  /// trigger a single auto-refresh + retry, and a 429 is retried with backoff.
  ///
  /// For a non-GET request, [body] is always sent as `application/json`
  /// unless it contains an [http.MultipartFile] (which switches the whole
  /// request to multipart instead) — this applies even to a bare scalar, so
  /// a `String` [body] is JSON-encoded too and arrives as a quoted JSON
  /// string literal (`"hi"`), never sent as raw unquoted text. [raw] shares
  /// this same body encoding (it only skips JSON-*parsing* the response).
  ///
  /// When [requestKey] is set, any in-flight request sharing the key is
  /// superseded: its future completes with [ZigbaseCancelledException] and its
  /// eventual HTTP response is discarded.
  Future<dynamic> send(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Object? body,
    Map<String, String>? headers,
    bool skipAuth = false,
    String? requestKey,
  }) {
    final url = buildUrl(path, query);
    final work = _exchange(url, method, body, headers, skipAuth);
    if (requestKey == null) return work;
    return _dedupe(requestKey, work);
  }

  /// Raw escape hatch: perform the request and return the [http.Response]
  /// as-is — no JSON *parse* of the response, no error mapping, no 401
  /// refresh, no 429 retry. Auth/lang/account headers and the
  /// [body]/[query]/[headers] all still apply, including [send]'s body
  /// encoding (see its dartdoc) — this only changes how the response is
  /// handled. Use for a binary/text response or custom status handling.
  Future<http.Response> raw(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Object? body,
    Map<String, String>? headers,
    bool skipAuth = false,
  }) async {
    final url = buildUrl(path, query);
    final multipart = await _maybeBufferMultipart(method, body);
    return _perform(url, method, body, headers, skipAuth, multipart);
  }

  /// Closes the underlying [http.Client].
  void close() => _httpClient.close();

  // --- internals -----------------------------------------------------------

  /// The refresh/retry loop around a single logical request. Rebuilds the
  /// request each attempt so a refreshed token / fresh headers are picked up.
  Future<dynamic> _exchange(
    Uri url,
    String method,
    Object? body,
    Map<String, String>? headers,
    bool skipAuth,
  ) async {
    var didRefresh = false;
    var attempt = 0;
    // Multipart bodies are encoded + buffered ONCE for the whole logical call
    // (see [_BufferedFile]); JSON/string bodies are re-encoded per attempt.
    final multipart = await _maybeBufferMultipart(method, body);

    for (;;) {
      final res =
          await _perform(url, method, body, headers, skipAuth, multipart);
      final status = res.statusCode;

      if (status >= 200 && status < 300) {
        if (status == 204) return null;
        final text = res.body;
        return text.isEmpty ? null : jsonDecode(text);
      }

      // One-shot auto-refresh on 401.
      if (status == 401 &&
          _autoRefresh &&
          _refresh != null &&
          !didRefresh &&
          !skipAuth) {
        didRefresh = true;
        try {
          await _refresh!();
          continue;
        } catch (_) {
          // Refresh failed — fall through and throw the original error.
        }
      }

      // 429 backoff: a numeric Retry-After is honored verbatim; otherwise an
      // exponential delay capped at [_maxBackoff].
      if (status == 429 && attempt < _maxRetries) {
        final delay = _retryDelay(res, attempt);
        attempt += 1;
        await _sleep(delay);
        continue;
      }

      throw parseErrorResponse(status, res.body, url.toString(),
          reasonPhrase: res.reasonPhrase);
    }
  }

  Duration _retryDelay(http.Response res, int attempt) {
    final header = res.headers['retry-after'];
    final seconds = header == null ? null : num.tryParse(header.trim());
    if (seconds != null && seconds > 0) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    final ms = math.min(_maxBackoff.inMilliseconds, (1 << attempt) * 200);
    return Duration(milliseconds: ms);
  }

  /// Encode + buffer a multipart body once per logical call, so retries can
  /// rebuild fresh file parts. Returns `null` for non-multipart bodies (JSON
  /// paths are untouched). Reads each caller-supplied [http.MultipartFile]'s
  /// stream fully into memory — acceptable, and equivalent to what the TS SDK
  /// effectively does with in-memory Blob-backed FormData.
  Future<_BufferedMultipart?> _maybeBufferMultipart(
      String method, Object? body) async {
    if (method.toUpperCase() == 'GET') return null;
    if (body is! Map<String, dynamic> || !hasFilePayload(body)) return null;
    final encoded = encodeMultipart(body);
    final files = <_BufferedFile>[];
    for (final f in encoded.files) {
      files.add(_BufferedFile(
          f.field, f.filename, f.contentType, await f.finalize().toBytes()));
    }
    return _BufferedMultipart(encoded.fields, files);
  }

  /// Build and send a single HTTP request (JSON or multipart), returning the
  /// fully-buffered [http.Response].
  Future<http.Response> _perform(
    Uri url,
    String method,
    Object? body,
    Map<String, String>? headers,
    bool skipAuth,
    _BufferedMultipart? multipart,
  ) async {
    final hdrs = _buildHeaders(headers, skipAuth);
    final isGet = method.toUpperCase() == 'GET';

    http.BaseRequest request;
    if (multipart != null) {
      request = _multipartRequest(method, url, hdrs, multipart);
    } else if (!isGet && body != null) {
      // Every non-multipart, non-null body is JSON-encoded — including a
      // bare String/num/bool — matching the TS transport, which always
      // `JSON.stringify`s a non-FormData body. A Dart String therefore
      // becomes a quoted JSON string literal (`"hi"`, not `hi`) with
      // `Content-Type: application/json`, not sent raw. A nested [DateTime]
      // serializes as a ms-clamped UTC ISO-8601 string (see
      // [_jsonEncodeBody]); other non-encodables throw [ArgumentError].
      final req = http.Request(method, url)..headers.addAll(hdrs);
      req.headers['content-type'] = 'application/json';
      req.body = _jsonEncodeBody(body);
      request = req;
    } else {
      request = http.Request(method, url)..headers.addAll(hdrs);
    }

    final streamed = await _httpClient.send(request);
    return http.Response.fromStream(streamed);
  }

  /// Build a fresh [http.MultipartRequest] from the pre-buffered parts. Every
  /// part (field or file) is a new instance, so the request can be rebuilt for
  /// each retry attempt without tripping package:http's finalize-once guard.
  http.MultipartRequest _multipartRequest(
    String method,
    Uri url,
    Map<String, String> hdrs,
    _BufferedMultipart encoded,
  ) {
    final req = http.MultipartRequest(method, url)..headers.addAll(hdrs);
    encoded.fields.forEach((key, values) {
      if (values.length == 1) {
        // A single value is a plain form field.
        req.fields[key] = values.first;
      } else {
        // MultipartRequest.fields is a Map and cannot repeat a key. The ZigBase
        // server (src/files/multipart.zig) discriminates files by the presence
        // of a `filename` disposition parameter and promotes a repeated
        // non-file key to a JSON string array. A filename-less
        // MultipartFile.fromString emits a `content-disposition: form-data;
        // name="key"` part with NO filename, so the server reads each as a form
        // field and coalesces the repeats into an array — matching the TS SDK's
        // FormData.append(key, value) semantics.
        for (final value in values) {
          req.files.add(http.MultipartFile.fromString(key, value));
        }
      }
    });
    req.files.addAll(encoded.files.map((f) => f.toPart()));
    return req;
  }

  /// Assemble the effective headers: bearer (unless [skipAuth]/no token),
  /// Accept-Language, and X-Account-Id (only when not already supplied by the
  /// per-request [headers], which win). Auth/lang override any per-request
  /// header of the same name (case-insensitively), matching the TS `Headers`
  /// semantics.
  Map<String, String> _buildHeaders(
      Map<String, String>? headers, bool skipAuth) {
    final out = <String, String>{};
    if (headers != null) out.addAll(headers);

    final token = _authStore.token;
    if (!skipAuth && token != null && token.isNotEmpty) {
      _setHeader(out, 'Authorization', 'Bearer $token');
    }
    if (_lang != null) _setHeader(out, 'Accept-Language', _lang);
    if (_accountId != null && !_hasHeader(out, 'X-Account-Id')) {
      _setHeader(out, 'X-Account-Id', _accountId);
    }
    return out;
  }

  static bool _hasHeader(Map<String, String> h, String name) {
    final lower = name.toLowerCase();
    return h.keys.any((k) => k.toLowerCase() == lower);
  }

  static void _setHeader(Map<String, String> h, String name, String value) {
    final lower = name.toLowerCase();
    h.removeWhere((k, _) => k.toLowerCase() == lower);
    h[name] = value;
  }

  /// Race the real request [work] against a per-key cancel token so a newer
  /// request with the same key supersedes it.
  ///
  /// package:http cannot abort a live socket, so cancellation is cooperative:
  /// the superseded call's future completes with [ZigbaseCancelledException]
  /// while its HTTP request keeps running and its response is discarded on
  /// arrival (the abandoned branch has a no-op error sink so a late failure is
  /// never an unhandled async error).
  Future<dynamic> _dedupe(String key, Future<dynamic> work) {
    final prior = _inflight[key];
    if (prior != null && !prior.isCompleted) {
      prior.completeError(const ZigbaseCancelledException());
    }
    final cancel = Completer<Never>();
    _inflight[key] = cancel;

    // Clear our slot when the real request settles — but only if it still owns
    // the slot (a newer keyed request may have replaced the token).
    void release() {
      if (identical(_inflight[key], cancel)) _inflight.remove(key);
    }

    final settled = work.then(
      (value) {
        release();
        return value;
      },
      onError: (Object error, StackTrace stack) {
        release();
        Error.throwWithStackTrace(error, stack);
      },
    );

    // If this call loses the race to a cancellation, `settled` keeps running
    // and eventually completes; swallow that late result/error so it never
    // surfaces as an unhandled async error.
    unawaited(settled.then((_) {}, onError: (Object _) {}));

    return Future.any([settled, cancel.future]);
  }
}
