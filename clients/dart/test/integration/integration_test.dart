/// End-to-end integration suite: drives the public Dart SDK against a real
/// `zigbase serve` process. Guarded on `ZIGBASE_TEST_BINARY` — when it is
/// unset the whole file is a clean no-op (a printed skip, not a failure), so
/// plain `dart test` stays green without the toolchain.
///
/// Run: `ZIGBASE_TEST_BINARY=/abs/path/to/zigbase dart test --tags integration`.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'harness.dart';

/// A @public base collection with the field shape the tests exercise: a
/// required text `title`, a numeric `views`, and a single-select `cover` file.
Map<String, dynamic> _postsDefinition(String name) => {
      'name': name,
      'type': 'base',
      'fields': [
        {
          'id': '',
          'name': 'title',
          'type': 'text',
          'required': true,
          'options': <String, dynamic>{}
        },
        {
          'id': '',
          'name': 'views',
          'type': 'number',
          'options': <String, dynamic>{}
        },
        {
          'id': '',
          'name': 'cover',
          'type': 'file',
          'options': {'maxSelect': 1}
        },
      ],
      'listRule': '@public',
      'viewRule': '@public',
      'createRule': '@public',
      'updateRule': '@public',
      'deleteRule': '@public',
    };

void main() {
  // Skip guard: no binary => this file does nothing at all (no failing tests).
  if (Platform.environment['ZIGBASE_TEST_BINARY'] == null) {
    print('skipped: ZIGBASE_TEST_BINARY unset');
    return;
  }

  late TestServer server;
  late String suToken;

  setUpAll(() async {
    server = await startServer();
    suToken = await superuserToken(server);
    await createCollection(server, suToken, _postsDefinition('posts'));
    await createCollection(server, suToken, _postsDefinition('feed'));
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('health check via client.send', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final health =
        await client.send('GET', '/api/health') as Map<String, dynamic>;
    expect(health['status'], 'ok');
  });

  test('superuser authWithPassword on _superusers', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final auth = await client
        .collection('_superusers')
        .authWithPassword(server.superuserEmail, server.superuserPassword);
    expect(auth.token, isNotEmpty);
    expect(client.authStore.token, auth.token);
    expect(auth.record?.getString('email'), server.superuserEmail);
  });

  test('CRUD round-trip against a live collection', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final posts = client.collection('posts');

    final created = await posts.create({'title': 'Hello', 'views': 3});
    expect(created.id, isNotEmpty);
    expect(created.getString('title'), 'Hello');
    expect(created.getInt('views'), 3);

    final fetched = await posts.getOne(created.id);
    expect(fetched.getString('title'), 'Hello');

    final updated = await posts.update(created.id, {'title': 'Renamed'});
    expect(updated.getString('title'), 'Renamed');

    await posts.delete(created.id);
    await expectLater(
      posts.getOne(created.id),
      throwsA(isA<ZigbaseException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('zbFilter round-trips a single-quoted value to the server', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final posts = client.collection('posts');

    final target = await posts.create({'title': "O'Brien", 'views': 100});
    await posts.create({'title': 'Smith', 'views': 101});

    final list = await posts.getList(
      filter: zbFilter('title = {:t}', {'t': "O'Brien"}),
    );
    expect(list.items.map((r) => r.id), [target.id]);
    expect(list.items.first.getString('title'), "O'Brien");
  });

  test('offset getList reports totals across pages', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final posts = client.collection('offsetposts');
    // Provision a dedicated collection so counts are deterministic.
    await createCollection(server, suToken, _postsDefinition('offsetposts'));

    for (var i = 0; i < 5; i++) {
      await posts.create({'title': 'Post $i', 'views': i});
    }

    final p1 = await posts.getList(page: 1, perPage: 2, sort: 'views');
    final p2 = await posts.getList(page: 2, perPage: 2, sort: 'views');
    expect(p1.items.length, 2);
    expect(p2.items.length, 2);
    expect(p1.totalItems, 5);
    expect(p1.totalPages, 3);

    final filtered = await posts.getList(filter: 'views >= 2', sort: '-views');
    expect(filtered.items.length, 3);
    expect(filtered.items.first.getInt('views'), 4);
  });

  test('cursor getPage + iterate cover >=3 pages of >=25 records', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final posts = client.collection('cursorposts');
    await createCollection(server, suToken, _postsDefinition('cursorposts'));

    const seedCount = 25;
    for (var i = 0; i < seedCount; i++) {
      await posts.create({'title': 'C$i', 'views': i});
    }

    // Page manually with a small limit so we span >= 3 pages.
    final seen = <String>[];
    var pages = 0;
    var page =
        await posts.getPage(limit: 10, sort: '-created', withTotal: true);
    expect(page.totalItems, seedCount);
    for (;;) {
      pages += 1;
      for (final rec in page.items) {
        seen.add(rec.id);
      }
      final next = page.nextCursor;
      if (!page.hasNext || next == null || next.isEmpty) break;
      page = await posts.getPage(cursor: next, limit: 10, sort: '-created');
    }
    expect(pages, greaterThanOrEqualTo(3));
    expect(seen.length, seedCount);
    expect(seen.toSet().length, seedCount, reason: 'no overlap across pages');

    // iterate yields every record exactly once.
    final iterated = <String>[];
    await for (final rec in posts.iterate(batch: 10, sort: 'views')) {
      iterated.add(rec.id);
    }
    expect(iterated.length, seedCount);
    expect(iterated.toSet().length, seedCount);
  });

  test('authRefresh mints a fresh token for the superuser', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final su = client.collection('_superusers');
    await su.authWithPassword(server.superuserEmail, server.superuserPassword);
    final refreshed = await su.authRefresh();
    expect(refreshed.token, isNotEmpty);
    expect(client.authStore.token, refreshed.token);
    // The refreshed token still works for an authenticated call.
    final health =
        await client.send('GET', '/api/health') as Map<String, dynamic>;
    expect(health['status'], 'ok');
  });

  test('file upload (MultipartFile) + fetch bytes via files.getUrl', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);
    final posts = client.collection('posts');

    final file = http.MultipartFile.fromString(
      'cover',
      'hello-file',
      filename: 'cover.txt',
    );
    final rec = await posts.create({'title': 'With cover', 'cover': file});
    final coverName = rec.getString('cover');
    expect(coverName, isNotNull,
        reason: 'server should store the uploaded file');

    // The create response doesn't echo collectionId/collectionName, so build
    // the URL from the explicit (collection, recordId, filename) triple — the
    // same shape the TS integration test uses.
    final url = client.files.getUrlFor('posts', rec.id, coverName!);
    // Plain HTTP GET — no auth needed for a @public collection's file.
    final res = await http.get(Uri.parse(url));
    expect(res.statusCode, 200);
    expect(res.body, 'hello-file');
  });

  test('realtime subscribe delivers a create event within 10s', () async {
    final client = ZigbaseClient(server.baseUrl);
    addTearDown(client.close);

    final events = <RecordEvent>[];
    final unsub = await client.realtime.subscribe('feed', events.add);

    final created =
        await client.collection('feed').create({'title': 'RT', 'views': 1});

    // Poll for delivery with a hard 10s ceiling.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (events.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(events, isNotEmpty, reason: 'create event not delivered within 10s');
    expect(events.first.action, 'create');
    expect(events.first.record.id, created.id);
    await unsub();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
