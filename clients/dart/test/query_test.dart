import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  group('filterValue', () {
    test('passes through null/bool/finite numbers bare', () {
      expect(filterValue(null), 'null');
      expect(filterValue(true), 'true');
      expect(filterValue(false), 'false');
      expect(filterValue(5), '5');
      expect(filterValue(3.14), '3.14');
      // Byte-parity with TS `String(value)`: an integral double must render
      // bare ("1"), not with a trailing ".0" (Dart's default double.toString).
      expect(filterValue(1.0), '1');
      expect(filterValue(2.5), '2.5');
    });

    test('single-quotes a plain string', () {
      expect(filterValue('published'), "'published'");
    });

    test('escapes an embedded single quote as \\ (not by swapping quotes)', () {
      expect(filterValue("O'Brien"), r"'O\'Brien'");
    });

    test('leaves an embedded double quote literal', () {
      expect(filterValue('say "hi"'), '\'say "hi"\'');
    });

    test('represents a value with both single and double quotes (no throw)',
        () {
      expect(filterValue('he said "hi" to O\'Brien'),
          "'he said \"hi\" to O\\'Brien'");
    });

    test('escapes backslashes (a\\b -> a\\\\b)', () {
      expect(filterValue(r'a\b'), r"'a\\b'");
    });

    test('escapes control characters into \\n / \\t / \\r', () {
      expect(filterValue('a\nb\tc\rd'), r"'a\nb\tc\rd'");
    });

    test('neutralizes an injection attempt (escaped, inert single token)', () {
      expect(filterValue("' || 1=1 --"), r"'\' || 1=1 --'");
    });

    test('serializes DateTime as a single-quoted UTC ISO string literal', () {
      final d = DateTime.utc(2026, 6, 16);
      expect(filterValue(d), "'2026-06-16T00:00:00.000Z'");
    });

    test('clamps DateTime to millisecond precision (JS Date parity)', () {
      // JS Date is millisecond-resolution, so the TS SDK always emits a
      // 3-digit fraction; a 6-digit Dart microsecond fraction would break
      // byte-parity AND server-side lexicographic TEXT comparison
      // ("...05.678Z" > "...05.678901Z" in a string compare).
      final d = DateTime.utc(2026, 1, 2, 3, 4, 5, 678, 901);
      expect(filterValue(d), "'2026-01-02T03:04:05.678Z'");
    });

    test('converts a non-UTC DateTime to UTC before formatting', () {
      final d = DateTime.utc(2026, 1, 2, 5); // matches local(2026,1,2) at -05
      expect(filterValue(d.toUtc()), "'2026-01-02T05:00:00.000Z'");
    });

    test('throws ArgumentError on array operands', () {
      expect(() => filterValue([1, 2]), throwsArgumentError);
      expect(() => filterValue(['a', 'b']), throwsArgumentError);
    });

    test('throws ArgumentError on map operands', () {
      expect(() => filterValue({'a': 1}), throwsArgumentError);
    });

    test('throws ArgumentError on non-finite numbers', () {
      expect(() => filterValue(double.nan), throwsArgumentError);
      expect(() => filterValue(double.infinity), throwsArgumentError);
      expect(() => filterValue(double.negativeInfinity), throwsArgumentError);
    });
  });

  group('zbFilter', () {
    test('interpolates named placeholders', () {
      expect(zbFilter('status = {:s} && n > {:n}', {'s': 'pub', 'n': 5}),
          "status = 'pub' && n > 5");
    });

    test('supports multiple/repeated placeholders and static text', () {
      expect(zbFilter('{:a} = {:a} && b = {:b}', {'a': 'x', 'b': true}),
          "'x' = 'x' && b = true");
    });

    test('throws ArgumentError on an unknown placeholder', () {
      expect(() => zbFilter('x = {:missing}'), throwsArgumentError);
    });

    test('passes through an expression with no placeholders', () {
      expect(zbFilter('status = "published"'), 'status = "published"');
    });
  });

  group('VectorQuery.spec', () {
    test('formats field:metric:json-array, matching JSON.stringify bytes', () {
      // Byte-parity with TS `vectorSpec`, which serializes via
      // `JSON.stringify(values)`: JSON.stringify([1, 2.5]) === "[1,2.5]" — an
      // integral double renders as a bare "1", not "1.0".
      expect(
          const VectorQuery(field: 'emb', metric: 'cosine', values: [1.0, 2.5])
              .spec(),
          'emb:cosine:[1,2.5]');
    });

    test('omits the metric segment when metric is null', () {
      expect(const VectorQuery(field: 'emb', values: [0.1, 0.2]).spec(),
          'emb:[0.1,0.2]');
    });

    test('throws ArgumentError on a non-finite value', () {
      expect(() => const VectorQuery(field: 'e', values: [double.nan]).spec(),
          throwsArgumentError);
      expect(
          () => const VectorQuery(field: 'e', values: [double.infinity]).spec(),
          throwsArgumentError);
    });
  });
}
