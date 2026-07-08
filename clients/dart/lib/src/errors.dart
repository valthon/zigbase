import 'dart:convert';

/// A single field-level validation error, as returned in the `data` map of
/// a ZigBase API error response.
class FieldError {
  final String code;
  final String message;

  const FieldError(this.code, this.message);
}

/// Thrown when the ZigBase API responds with a non-2xx status.
class ZigbaseException implements Exception {
  final int status;
  final String message;
  final Map<String, FieldError> data;
  final String url;

  ZigbaseException({
    required this.status,
    required this.message,
    this.data = const {},
    required this.url,
  });

  @override
  String toString() => 'ZigbaseException($status): $message ($url)';
}

/// Thrown when a request is aborted/cancelled before it completes.
class ZigbaseCancelledException implements Exception {
  final String message;

  const ZigbaseCancelledException([this.message = 'Request was cancelled.']);

  @override
  String toString() => 'ZigbaseCancelledException: $message';
}

/// Builds a [ZigbaseException] from a response body, which may not be JSON.
///
/// Parses a `{message?, data?}` shaped JSON body, where `data` maps field
/// names to `{code, message}` objects. When the body is not valid JSON (or
/// not a JSON object), falls back to [reasonPhrase], then to a generic
/// "Request failed with status $status" message.
ZigbaseException parseErrorResponse(
  int status,
  String bodyText,
  String url, {
  String? reasonPhrase,
}) {
  String message = (reasonPhrase != null && reasonPhrase.isNotEmpty)
      ? reasonPhrase
      : 'Request failed with status $status';
  Map<String, FieldError> data = const {};

  try {
    final decoded = jsonDecode(bodyText);
    if (decoded is Map) {
      final msg = decoded['message'];
      if (msg is String) message = msg;

      final rawData = decoded['data'];
      if (rawData is Map) {
        data = rawData.map((key, value) {
          String code = '';
          String fieldMessage = '';
          if (value is Map) {
            final rawCode = value['code'];
            final rawMessage = value['message'];
            if (rawCode is String) code = rawCode;
            if (rawMessage is String) fieldMessage = rawMessage;
          }
          return MapEntry(key.toString(), FieldError(code, fieldMessage));
        });
      }
    }
  } catch (_) {
    // Non-JSON (or non-object) body; keep the fallback message.
  }

  return ZigbaseException(
      status: status, message: message, data: data, url: url);
}
