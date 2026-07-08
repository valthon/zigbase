import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

final _unreservedPattern = RegExp(r'^[A-Za-z0-9\-._~]+$');

void main() {
  group('createPkceChallenge', () {
    test('verifier is 64 chars from the unreserved charset', () {
      final pkce = createPkceChallenge();
      expect(pkce.verifier.length, 64);
      expect(_unreservedPattern.hasMatch(pkce.verifier), isTrue);
    });

    test('challenge is derived from the verifier', () {
      final pkce = createPkceChallenge();
      expect(pkce.challenge, pkceChallengeFor(pkce.verifier));
    });

    test('two calls produce different verifiers', () {
      final a = createPkceChallenge();
      final b = createPkceChallenge();
      expect(a.verifier, isNot(b.verifier));
    });
  });

  group('pkceChallengeFor', () {
    test('matches the RFC 7636 appendix B vector', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expected = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
      expect(pkceChallengeFor(verifier), expected);
    });
  });

  group('randomState', () {
    test('is 32 chars from the unreserved charset', () {
      final state = randomState();
      expect(state.length, 32);
      expect(_unreservedPattern.hasMatch(state), isTrue);
    });

    test('two calls differ', () {
      expect(randomState(), isNot(randomState()));
    });
  });
}
