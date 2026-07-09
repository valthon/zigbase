import 'package:test/test.dart';
import 'package:zigbase_client/typed.dart';

void main() {
  group('coerceInt', () {
    test('from JSON number', () => expect(coerceInt(42), 42));
    test('from integral double', () => expect(coerceInt(42.0), 42));
    test('from decimal-string wire form', () => expect(coerceInt('42'), 42));
    test('from integral decimal string', () => expect(coerceInt('42.0'), 42));
    test('empty string → fallback', () => expect(coerceInt('', 7), 7));
    test('null → fallback', () => expect(coerceInt(null), 0));
    test('garbage → fallback', () => expect(coerceInt('abc', 3), 3));
    test('fractional string throws (schema drift, no silent truncation)', () {
      expect(() => coerceInt('9.99'), throwsFormatException);
    });
    test('fractional double throws', () {
      expect(() => coerceInt(9.99), throwsFormatException);
    });
    test('coerceIntList propagates the throw', () {
      expect(() => coerceIntList(['1', '2.5']), throwsFormatException);
    });
  });

  group('coerceDouble', () {
    test('from num', () => expect(coerceDouble(2), 2.0));
    test('from fixed decimal string',
        () => expect(coerceDouble('19.99'), 19.99));
    test('empty → fallback', () => expect(coerceDouble('', 1.5), 1.5));
    test('null → fallback', () => expect(coerceDouble(null), 0.0));
  });

  group('coerceString / coerceBool', () {
    test('string passthrough', () => expect(coerceString('x'), 'x'));
    test('non-string → fallback', () => expect(coerceString(3, 'd'), 'd'));
    test('bool passthrough', () => expect(coerceBool(true), true));
    test('non-bool → false', () => expect(coerceBool('true'), false));
  });

  group('list coercion', () {
    test('coerceStringList from array', () {
      expect(coerceStringList(['a', 'b']), ['a', 'b']);
    });
    test('coerceStringList from scalar', () {
      expect(coerceStringList('a'), ['a']);
    });
    test('coerceStringList from null', () {
      expect(coerceStringList(null), <String>[]);
    });
    test('coerceIntList parses decimal strings', () {
      expect(coerceIntList(['1', '2', 3]), [1, 2, 3]);
    });
    test('coerceDoubleList', () {
      expect(coerceDoubleList(['1.5', 2]), [1.5, 2.0]);
    });
  });

  group('write encoders produce decimal-string wire form', () {
    test('encodeInt', () => expect(encodeInt(42), '42'));
    test('encodeInt null', () => expect(encodeInt(null), isNull));
    test('encodeFixed scales', () => expect(encodeFixed(19.9, 2), '19.90'));
    test('encodeFixed rounds', () => expect(encodeFixed(1.005, 2), '1.00'));
    test('encodeFixed null', () => expect(encodeFixed(null, 2), isNull));
  });

  test('int round-trip (write → wire → read)', () {
    final wire = encodeInt(1234567890);
    expect(coerceInt(wire), 1234567890);
  });
}
