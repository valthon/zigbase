import 'dart:convert';

import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  group('ZigbaseException', () {
    test('captures status, message, url, and field data', () {
      final err = ZigbaseException(
        status: 400,
        message: 'Failed to validate the request.',
        data: {'email': const FieldError('validation_required', 'Missing.')},
        url: 'http://x/api/collections/users/records',
      );
      expect(err, isA<Exception>());
      expect(err.status, 400);
      expect(err.data['email']?.code, 'validation_required');
      expect(err.data['email']?.message, 'Missing.');
      expect(err.url, 'http://x/api/collections/users/records');
    });

    test('toString includes status, message, and url', () {
      final err = ZigbaseException(
        status: 400,
        message: 'Bad request.',
        url: 'http://x/api/y',
      );
      expect(err.toString(),
          'ZigbaseException(400): Bad request. (http://x/api/y)');
    });

    test('data defaults to empty map', () {
      final err =
          ZigbaseException(status: 500, message: 'oops', url: 'http://x');
      expect(err.data, isEmpty);
    });
  });

  group('ZigbaseCancelledException', () {
    test('carries a message', () {
      const err = ZigbaseCancelledException('Request was cancelled.');
      expect(err, isA<Exception>());
      expect(err.message, 'Request was cancelled.');
    });
  });

  group('parseErrorResponse', () {
    test('parses a zigbase error response body', () {
      final body = jsonEncode(
          {'code': 403, 'message': 'Forbidden.', 'data': <String, dynamic>{}});
      final err = parseErrorResponse(403, body, 'http://x/api/y');
      expect(err.status, 403);
      expect(err.message, 'Forbidden.');
      expect(err.data, isEmpty);
    });

    test('parses field-level error data', () {
      final body = jsonEncode({
        'message': 'Failed to validate the request.',
        'data': {
          'email': {'code': 'validation_required', 'message': 'Missing.'},
        },
      });
      final err = parseErrorResponse(400, body, 'http://x/api/y');
      expect(err.status, 400);
      expect(err.message, 'Failed to validate the request.');
      expect(err.data['email']?.code, 'validation_required');
      expect(err.data['email']?.message, 'Missing.');
    });

    test('falls back to reasonPhrase when body is not JSON', () {
      final err = parseErrorResponse(
        500,
        'oops',
        'http://x/api/y',
        reasonPhrase: 'Internal Server Error',
      );
      expect(err.status, 500);
      expect(err.message, 'Internal Server Error');
      expect(err.data, isEmpty);
    });

    test(
        'falls back to generic message when body is not JSON and no reasonPhrase',
        () {
      final err = parseErrorResponse(500, 'oops', 'http://x/api/y');
      expect(err.status, 500);
      expect(err.message, 'Request failed with status 500');
    });

    test('falls back to generic message when reasonPhrase is empty', () {
      final err =
          parseErrorResponse(502, 'oops', 'http://x/api/y', reasonPhrase: '');
      expect(err.message, 'Request failed with status 502');
    });
  });
}
