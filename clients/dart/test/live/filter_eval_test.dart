import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  group('filter evaluator', () {
    test('evaluates a compound && / || filter on own scalar fields', () {
      final ast =
          parseFilter("status = 'published' && (views > 10 || pinned = true)");
      expect(
          evaluateFilter(
              {'status': 'published', 'views': 3, 'pinned': true}, ast),
          isTrue);
      expect(
          evaluateFilter(
              {'status': 'published', 'views': 20, 'pinned': false}, ast),
          isTrue);
      expect(
          evaluateFilter({'status': 'draft', 'views': 99, 'pinned': true}, ast),
          isFalse);
      expect(
          evaluateFilter(
              {'status': 'published', 'views': 3, 'pinned': false}, ast),
          isFalse);
    });

    test('handles all comparison operators', () {
      final r = {'n': 5, 's': 'hello'};
      expect(evaluateFilter(r, parseFilter('n = 5')), isTrue);
      expect(evaluateFilter(r, parseFilter('n != 6')), isTrue);
      expect(evaluateFilter(r, parseFilter('n >= 5')), isTrue);
      expect(evaluateFilter(r, parseFilter('n <= 4')), isFalse);
      expect(evaluateFilter(r, parseFilter('n > 4')), isTrue);
      expect(evaluateFilter(r, parseFilter('n < 5')), isFalse);
    });

    test('does case-sensitive substring with ~ and !~', () {
      final r = {'title': 'Hello World'};
      expect(evaluateFilter(r, parseFilter("title ~ 'World'")), isTrue);
      expect(evaluateFilter(r, parseFilter("title ~ 'world'")), isFalse);
      expect(evaluateFilter(r, parseFilter("title !~ 'xyz'")), isTrue);
    });

    test('compares against null', () {
      expect(
          evaluateFilter({'deletedAt': null}, parseFilter('deletedAt = null')),
          isTrue);
      expect(
          evaluateFilter(
              {'deletedAt': '2026'}, parseFilter('deletedAt = null')),
          isFalse);
      expect(
          evaluateFilter(
              {'deletedAt': '2026'}, parseFilter('deletedAt != null')),
          isTrue);
    });

    test('reads dotted paths against expanded relations present on the record',
        () {
      final r = {
        'id': 'p1',
        'author': {'name': 'Ada'}
      };
      expect(evaluateFilter(r, parseFilter("author.name = 'Ada'")), isTrue);
      // missing path resolves to null -> not equal
      expect(evaluateFilter({'id': 'p2'}, parseFilter("author.name = 'Ada'")),
          isFalse);
    });

    test('accepts double-quoted strings and both-quote escapes', () {
      expect(evaluateFilter({'s': "a'b"}, parseFilter('s = "a\'b"')), isTrue);
      expect(evaluateFilter({'s': 'x"y'}, parseFilter('s = \'x"y\'')), isTrue);
      // Escaped backslash inside a single-quoted literal.
      expect(evaluateFilter({'s': r'a\b'}, parseFilter(r"s = 'a\\b'")), isTrue);
    });

    test('an injection-ish string literal is matched verbatim, not executed',
        () {
      // A closing-quote-and-boolean-clause attempt is just a string value.
      final evil = "x' || 1=1 || 'y";
      final ast = parseFilter("title = 'x\\' || 1=1 || \\'y'");
      expect(evaluateFilter({'title': evil}, ast), isTrue);
      expect(evaluateFilter({'title': 'x'}, ast), isFalse);
    });

    test('rejects a malformed filter', () {
      expect(() => parseFilter('status ='), throwsFormatException);
      expect(() => parseFilter('a = 1 b = 2'), throwsFormatException);
      expect(() => parseFilter('(a = 1'), throwsFormatException);
    });

    test('rejects an unterminated string literal', () {
      expect(() => parseFilter("title = 'oops"), throwsFormatException);
      expect(() => parseFilter('title = "oops'), throwsFormatException);
      // An escaped quote at the end must not count as the closing quote.
      expect(() => parseFilter(r"title = 'oops\'"), throwsFormatException);
    });

    test('ordering compare against a null/missing field is false, not a throw',
        () {
      expect(evaluateFilter({'n': null}, parseFilter('n > 4')), isFalse);
      expect(evaluateFilter({'n': null}, parseFilter('n <= 4')), isFalse);
      expect(
          evaluateFilter(<String, dynamic>{}, parseFilter('n >= 0')), isFalse);
    });

    test('ordering compare against a non-numeric field is false, not a throw',
        () {
      expect(evaluateFilter({'n': 'five'}, parseFilter('n > 4')), isFalse);
      expect(evaluateFilter({'n': 'five'}, parseFilter('n < 4')), isFalse);
      // Numeric field against a string RHS literal: also false.
      expect(evaluateFilter({'n': 5}, parseFilter("n > '4'")), isFalse);
    });
  });

  group('analyzeFilter', () {
    test('classifies own-scalar-field filters as locally evaluable', () {
      final a =
          analyzeFilter(parseFilter("status = 'published' && views > 10"));
      expect(a.locallyEvaluable, isTrue);
      expect(a.referencesRelations, isFalse);
      expect(a.referencesMacros, isFalse);
    });

    test('flags relation-traversal filters as NOT locally evaluable', () {
      final a = analyzeFilter(parseFilter("author.name = 'Ada'"));
      expect(a.locallyEvaluable, isFalse);
      expect(a.referencesRelations, isTrue);
    });

    test('flags @request.* / macro filters as NOT locally evaluable', () {
      final a = analyzeFilter(parseFilter('@request.auth.id = owner'));
      expect(a.locallyEvaluable, isFalse);
      expect(a.referencesMacros, isTrue);
    });

    test('classifies a field-to-field RHS relation path', () {
      final a = analyzeFilter(parseFilter('a = owner.id'));
      expect(a.locallyEvaluable, isFalse);
      expect(a.referencesRelations, isTrue);
    });

    test('treats an empty filter (null) as locally evaluable (matches all)',
        () {
      final a = analyzeFilter(null);
      expect(a.locallyEvaluable, isTrue);
    });
  });
}
