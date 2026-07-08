import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

final _secureRandom = Random.secure();

String _randomString(int length) {
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(_unreserved[_secureRandom.nextInt(_unreserved.length)]);
  }
  return buffer.toString();
}

/// An OAuth2 PKCE (RFC 7636) verifier/challenge pair.
class PkceChallenge {
  final String verifier;
  final String challenge;

  const PkceChallenge({required this.verifier, required this.challenge});
}

/// Generates a fresh 64-character PKCE verifier (drawn from the unreserved
/// charset `[A-Za-z0-9-._~]`) and its matching S256 challenge.
PkceChallenge createPkceChallenge() {
  final verifier = _randomString(64);
  return PkceChallenge(
      verifier: verifier, challenge: pkceChallengeFor(verifier));
}

/// Derives the S256 PKCE challenge for [verifier]: the base64url encoding
/// (without padding) of `sha256(ascii(verifier))`.
String pkceChallengeFor(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Generates a random 32-character OAuth2 `state` value (drawn from the same
/// unreserved charset as the PKCE verifier) via a cryptographically secure
/// random source.
String randomState() => _randomString(32);
