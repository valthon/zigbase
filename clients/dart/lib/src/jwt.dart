import 'dart:convert';

/// Decodes the payload segment of a JWT without verifying its signature.
///
/// Returns `null` for any malformed input: not a string with exactly three
/// dot-separated segments, an empty payload segment, invalid base64url, or a
/// payload that doesn't decode to a JSON object.
Map<String, dynamic>? decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length != 3 || parts[1].isEmpty) return null;

  try {
    final normalized = base64Url.normalize(parts[1]);
    final bytes = base64Url.decode(normalized);
    // `jsonDecode` always produces a `Map<String, dynamic>` for a JSON object
    // (its keys are always strings), so there is no other `Map` shape to
    // re-key here.
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Returns `true` when [token] is expired (or has no readable/`exp` claim).
///
/// [leewaySeconds] is subtracted from `exp` before comparing to the current
/// time, so a token can be treated as expired slightly before its real
/// expiry (e.g. to account for clock skew or in-flight request latency).
bool isTokenExpired(String token, {int leewaySeconds = 0}) {
  final payload = decodeJwtPayload(token);
  final exp = payload?['exp'];
  if (exp is! num) return true;

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return exp - leewaySeconds <= now;
}
