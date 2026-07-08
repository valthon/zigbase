import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  group('ZbRecord', () {
    test('id falls back to empty string when absent', () {
      final r = ZbRecord({'title': 'hi'});
      expect(r.id, '');
    });

    test('id reads the id field', () {
      final r = ZbRecord({'id': 'abc123', 'title': 'hi'});
      expect(r.id, 'abc123');
    });

    test('id falls back to empty string when present but not a String', () {
      final r = ZbRecord({'id': 42});
      expect(r.id, '');
    });

    test('operator [] reads raw values', () {
      final r = ZbRecord({'title': 'hi', 'count': 3});
      expect(r['title'], 'hi');
      expect(r['count'], 3);
      expect(r['missing'], isNull);
    });

    test('getString returns the string or null', () {
      final r = ZbRecord({'title': 'hi', 'count': 3});
      expect(r.getString('title'), 'hi');
      expect(r.getString('missing'), isNull);
    });

    test('getInt coerces a num (including a double) to int', () {
      final r = ZbRecord({'count': 3, 'total': 4.0});
      expect(r.getInt('count'), 3);
      expect(r.getInt('total'), 4);
      expect(r.getInt('missing'), isNull);
    });

    test('getDouble coerces a num to double', () {
      final r = ZbRecord({'count': 3, 'price': 4.5});
      expect(r.getDouble('count'), 3.0);
      expect(r.getDouble('price'), 4.5);
      expect(r.getDouble('missing'), isNull);
    });

    test('getBool returns the bool or null', () {
      final r = ZbRecord({'ok': true});
      expect(r.getBool('ok'), true);
      expect(r.getBool('missing'), isNull);
    });

    test('getList returns the list or null', () {
      final r = ZbRecord({
        'tags': ['a', 'b']
      });
      expect(r.getList('tags'), ['a', 'b']);
      expect(r.getList('missing'), isNull);
    });

    test('toJson returns the underlying data map', () {
      final data = {'id': 'abc', 'title': 'hi'};
      final r = ZbRecord(data);
      expect(r.toJson(), same(data));
    });
  });

  group('ListResult.fromJson', () {
    test('maps the offset-paginated envelope exactly', () {
      final result = ListResult.fromJson({
        'page': 2,
        'perPage': 30,
        'totalItems': 61,
        'totalPages': 3,
        'items': [
          {'id': 'r1'},
          {'id': 'r2'},
        ],
      });
      expect(result.page, 2);
      expect(result.perPage, 30);
      expect(result.totalItems, 61);
      expect(result.totalPages, 3);
      expect(result.items, hasLength(2));
      expect(result.items[0], isA<ZbRecord>());
      expect(result.items[0].id, 'r1');
      expect(result.items[1].id, 'r2');
    });

    test('defaults missing numeric fields to 0 and items to empty', () {
      final result = ListResult.fromJson({});
      expect(result.page, 0);
      expect(result.perPage, 0);
      expect(result.totalItems, 0);
      expect(result.totalPages, 0);
      expect(result.items, isEmpty);
    });
  });

  group('CursorPage.fromJson', () {
    test('maps the cursor envelope exactly (server key names)', () {
      final page = CursorPage.fromJson({
        'items': [
          {'id': 'r1'},
        ],
        'nextCursor': 'abc',
        'prevCursor': null,
        'hasNext': true,
        'hasPrev': false,
        'totalItems': 5,
      });
      expect(page.items, hasLength(1));
      expect(page.items[0].id, 'r1');
      expect(page.nextCursor, 'abc');
      expect(page.prevCursor, isNull);
      expect(page.hasNext, isTrue);
      expect(page.hasPrev, isFalse);
      expect(page.totalItems, 5);
    });

    test('nextCursor/prevCursor null and totalItems absent (skipTotal default)',
        () {
      final page = CursorPage.fromJson({
        'items': <Map<String, dynamic>>[],
        'nextCursor': null,
        'prevCursor': null,
        'hasNext': false,
        'hasPrev': false,
      });
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(page.prevCursor, isNull);
      expect(page.hasNext, isFalse);
      expect(page.hasPrev, isFalse);
      expect(page.totalItems, isNull);
    });
  });

  group('hasFilePayload', () {
    test('false for plain JSON-ish bodies', () {
      expect(
          hasFilePayload({
            'title': 'hi',
            'n': 3,
            'tags': ['a', 'b']
          }),
          isFalse);
      expect(hasFilePayload({}), isFalse);
    });

    test('true for a top-level file value', () {
      expect(
          hasFilePayload({
            'title': 'hi',
            'avatar': http.MultipartFile.fromString('avatar', 'x'),
          }),
          isTrue);
    });

    test('true for an array containing a file', () {
      expect(
          hasFilePayload({
            'photos': [
              'a',
              http.MultipartFile.fromString('photos', 'b'),
            ],
          }),
          isTrue);
      expect(
          hasFilePayload({
            'photos': [
              http.MultipartFile.fromString('photos', 'a'),
              http.MultipartFile.fromString('photos', 'b'),
            ],
          }),
          isTrue);
    });
  });

  group('encodeMultipart', () {
    test(
        'scalars stringify, nested map JSON-encodes once, null becomes '
        'empty string', () {
      final result = encodeMultipart({
        'title': 'hi',
        'count': 3,
        'flag': true,
        'meta': {'a': 1},
        'note': null,
      });
      expect(result.fields['title'], ['hi']);
      expect(result.fields['count'], ['3']);
      expect(result.fields['flag'], ['true']);
      expect(result.fields['meta'], ['{"a":1}']); // jsonEncode({'a': 1})
      expect(result.fields['note'], ['']);
      expect(result.files, isEmpty);
    });

    test('a single file value is appended as a file with field == key', () {
      final result = encodeMultipart({
        'cover': http.MultipartFile.fromString('cover', 'bytes'),
      });
      expect(result.fields.containsKey('cover'), isFalse);
      expect(result.files, hasLength(1));
      expect(result.files.single.field, 'cover');
    });

    test(
        'a file forces field == the map key even if constructed with a '
        'different field name', () {
      final result = encodeMultipart({
        'cover': http.MultipartFile.fromString('mismatched', 'bytes'),
      });
      expect(result.files.single.field, 'cover');
    });

    test('DateTime serializes as a plain UTC ISO string (not JSON-quoted)', () {
      final result = encodeMultipart({
        'when': DateTime.utc(2026, 1, 2),
      });
      expect(result.fields['when'], ['2026-01-02T00:00:00.000Z']);
    });

    test('array of files repeats the field name (one MultipartFile per item)',
        () {
      final result = encodeMultipart({
        'photos': [
          http.MultipartFile.fromString('photos', 'a'),
          http.MultipartFile.fromString('photos', 'b'),
        ],
      });
      expect(result.fields.containsKey('photos'), isFalse);
      expect(result.files, hasLength(2));
      expect(result.files.every((f) => f.field == 'photos'), isTrue);
    });

    // Array-encoding ambiguity resolution: the TS source (`toFormData` in
    // clients/typescript/src/records.ts) iterates array *elements*
    // individually and appends one form part per element — it does NOT
    // JSON-encode the whole array once. This applies uniformly, not only to
    // file arrays: a plain-scalar array repeats the key too, exactly like a
    // file array does. We port that element-wise behavior verbatim rather
    // than the plan's draft assumption (JSON-encode non-file lists once).
    test(
        'a non-file array of scalars repeats the key per element (ported '
        'from TS toFormData, which iterates elements, not the whole array)',
        () {
      final result = encodeMultipart({
        'tags': ['a', 'b'],
      });
      expect(result.fields['tags'], ['a', 'b']);
      expect(result.files, isEmpty);
    });

    test('a non-file array of maps JSON-encodes each element individually', () {
      final result = encodeMultipart({
        'rows': [
          {'a': 1},
          {'b': 2},
        ],
      });
      expect(result.fields['rows'], ['{"a":1}', '{"b":2}']);
    });

    test('a non-file array of DateTimes ISO-encodes each element', () {
      final result = encodeMultipart({
        'when': [DateTime.utc(2026, 1, 2), DateTime.utc(2026, 1, 3)],
      });
      expect(result.fields['when'],
          ['2026-01-02T00:00:00.000Z', '2026-01-03T00:00:00.000Z']);
    });

    test('null items inside an array are dropped (not stringified)', () {
      final result = encodeMultipart({
        'tags': ['a', null, 'b'],
      });
      expect(result.fields['tags'], ['a', 'b']);
    });

    test('an empty array produces no field part at all (absent key)', () {
      final result = encodeMultipart({
        'tags': <String>[],
      });
      expect(result.fields.containsKey('tags'), isFalse);
    });

    test(
        'a DateTime nested inside a Map value JSON-encodes as a ms-clamped '
        'UTC ISO string (JS JSON.stringify Date parity)', () {
      final result = encodeMultipart({
        'meta': {'when': DateTime.utc(2026, 1, 2)},
      });
      expect(result.fields['meta'], ['{"when":"2026-01-02T00:00:00.000Z"}']);
    });

    test('a nested DateTime with microseconds clamps to milliseconds', () {
      final result = encodeMultipart({
        'meta': {'when': DateTime.utc(2026, 1, 2, 3, 4, 5, 678, 901)},
      });
      expect(result.fields['meta'], ['{"when":"2026-01-02T03:04:05.678Z"}']);
    });

    test('a DateTime nested inside a List of maps JSON-encodes per element',
        () {
      final result = encodeMultipart({
        'rows': [
          {'at': DateTime.utc(2026, 1, 2)},
          {'at': DateTime.utc(2026, 1, 3)},
        ],
      });
      expect(result.fields['rows'], [
        '{"at":"2026-01-02T00:00:00.000Z"}',
        '{"at":"2026-01-03T00:00:00.000Z"}',
      ]);
    });

    test(
        'a MultipartFile nested inside a Map value throws ArgumentError '
        'naming the key (deliberate divergence from TS, which emits "{}")', () {
      expect(
        () => encodeMultipart({
          'meta': {'file': http.MultipartFile.fromString('file', 'x')},
        }),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('meta'))),
      );
    });

    test('mixed body: scalar fields + a nested map + a single file together',
        () {
      final result = encodeMultipart({
        'title': 'hi',
        'meta': {'a': 1},
        'cover': http.MultipartFile.fromString('cover', 'bytes'),
        'tags': ['a', 'b'],
      });
      expect(result.fields['title'], ['hi']);
      expect(result.fields['meta'], ['{"a":1}']);
      expect(result.fields['tags'], ['a', 'b']);
      expect(result.files, hasLength(1));
      expect(result.files.single.field, 'cover');
    });
  });
}
