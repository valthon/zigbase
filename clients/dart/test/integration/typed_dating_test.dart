/// Typed-tier e2e: drives the generated dating client
/// (`test/codegen/dating/zbase.gen.dart`) against the live `dating-server`
/// binary (the dating fixture, schema baked in). Mirrors the TypeScript
/// `clients/typescript/test/integration/dating.integration.test.ts`.
///
/// Guarded on `ZIGBASE_TEST_DATING_BINARY` — unset ⇒ a clean no-op skip, so
/// plain `dart test` stays green.
///
/// Run: `ZIGBASE_TEST_DATING_BINARY=/abs/path/to/dating-server \
///   dart test --tags integration test/integration/typed_dating_test.dart`.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../codegen/dating/zbase.gen.dart' as api;
import 'harness.dart';

/// Poll until [cond] is true or [timeout] elapses (no fixed sleeps).
Future<void> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timeout waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  final datingBin = datingBinaryPath;
  if (datingBin == null) {
    print('skipped: ZIGBASE_TEST_DATING_BINARY unset');
    return;
  }

  late TestServer server;

  setUpAll(() async {
    server = await startServer(bin: datingBin);
  });
  tearDownAll(() async {
    await server.stop();
  });

  /// Register a profile (public signup) and authenticate it.
  Future<({api.ZbClient zb, api.Profile profile})> authedProfile(
      String email) async {
    final zb = api.createClient(server.baseUrl);
    final profile = await zb.profiles.create(api.ProfileCreate(
      email: email,
      password: 'member-pass-1',
      passwordConfirm: 'member-pass-1',
      name: email.split('@').first,
      age:
          25, // int-mode field: server stores decimal; typed client coerces back
    ));
    await zb.profiles.authWithPassword(email, 'member-pass-1');
    return (zb: zb, profile: profile);
  }

  test(
      'CRUD + nested-relation filter + expand (single & multi) + native cursor',
      () async {
    final s = await authedProfile('crud@d.app');
    final zb = s.zb;
    final profile = s.profile;
    addTearDown(zb.close);

    // age is int-mode: the typed record exposes it as a Dart int.
    expect(profile.age, isA<int>());
    expect(profile.age, 25);

    final t1 = await zb.tags.create(const api.TagCreate(label: 'hiking'));
    final t2 = await zb.tags.create(const api.TagCreate(label: 'coffee'));

    final p1 = await zb.photos.create(api.PhotoCreate(
      owner: profile.id,
      caption: 'trail',
      tags: [t1.id, t2.id],
    ));
    await zb.photos.create(api.PhotoCreate(
      owner: profile.id,
      caption: 'espresso',
      tags: [t2.id],
    ));
    expect(p1.id, isNotEmpty);

    // nested-relation filter via the typed fluent builder: owner.name ~ '...'.
    final byOwner = await zb.photos
        .getList(where: (p) => p.owner.rel((o) => o.name.like(profile.name)));
    expect(byOwner.items.length, 2);

    // expand single (owner -> Profile) and multi (tags -> Tag[]).
    final withOwner = await zb.photos.getOne(p1.id, expand: ['owner']);
    expect(withOwner.expand.owner?.id, profile.id);
    final withTags = await zb.photos.getOne(p1.id, expand: ['tags']);
    expect(
      withTags.expand.tags.map((t) => t.label).toList()..sort(),
      ['coffee', 'hiking'],
    );

    // update + delete.
    final upd =
        await zb.photos.update(p1.id, const api.PhotoUpdate(caption: 'summit'));
    expect(upd.caption, 'summit');
    await zb.photos.delete(p1.id);
    final remaining =
        await zb.photos.getList(where: (p) => p.owner.eq(profile.id));
    expect(remaining.items.length, 1);

    // native cursor: walk the 2 tags one per page.
    final page1 = await zb.tags.getPage(sort: '-created', limit: 1);
    expect(page1.items.length, 1);
    expect(page1.hasNext, true);
    final page2 = await zb.tags
        .getPage(sort: '-created', limit: 1, cursor: page1.nextCursor);
    expect(page2.items.first.id, isNot(page1.items.first.id));
  });

  test('int/fixed coercion round-trips through the wire (fixed price)',
      () async {
    final s = await authedProfile('fixed@d.app');
    final zb = s.zb;
    addTearDown(zb.close);

    final sub = await zb.subscriptions.create(api.SubscriptionCreate(
      profile: s.profile.id,
      plan: api.SubscriptionPlan.premium,
      price:
          9.99, // fixed(2): encoded as '9.99' on write, parsed back to double
      renewsAt: '2026-01-01 00:00:00.000Z',
      active: true,
    ));
    expect(sub.price, 9.99);
    expect(sub.plan, api.SubscriptionPlan.premium);
    expect(sub.active, true);

    final read = await zb.subscriptions.getOne(sub.id);
    expect(read.price, 9.99);
  });

  test('realtime create -> typed event', () async {
    final s = await authedProfile('rt@d.app');
    final zb = s.zb;
    addTearDown(zb.close);

    final events = <String>[];
    final off = await zb.photosRealtime
        .subscribe((e) => events.add('${e.action}:${e.record.id}'));
    final made = await zb.photos
        .create(api.PhotoCreate(owner: s.profile.id, caption: 'live'));
    await waitFor(() => events.contains('create:${made.id}'));
    await off();
    expect(events.contains('create:${made.id}'), true);
  });

  test(
      'files: public avatar via fileUrl; private photo gated, accessible only with a token',
      () async {
    final s = await authedProfile('files@d.app');
    final zb = s.zb;
    final profile = s.profile;
    addTearDown(zb.close);

    // public avatar on the (public) profile -> fileUrl is fetchable anonymously.
    final withAvatar = await zb.profiles.update(
      profile.id,
      api.ProfileUpdate(
        avatar: http.MultipartFile.fromBytes('avatar', [1, 2, 3, 4],
            filename: 'a.png'),
      ),
    );
    final avatarUrl =
        zb.profiles.fileUrl(withAvatar, field: api.ProfileFileField.avatar);
    final pub = await http.get(Uri.parse(avatarUrl));
    expect(pub.statusCode, 200);

    // private photo: owner-only view -> the image file is gated by the viewRule.
    final priv = await zb.privatePhotos.create(api.PrivatePhotoCreate(
      owner: profile.id,
      image: http.MultipartFile.fromBytes('image', [5, 6, 7, 8],
          filename: 'secret.png'),
      caption: 'hidden',
    ));
    final privUrlNoTok =
        zb.privatePhotos.fileUrl(priv, field: api.PrivatePhotoFileField.image);
    final anon = await http.get(Uri.parse(privUrlNoTok));
    expect(anon.statusCode, isNot(200));

    // with a fresh file-access token (owner is authed), the file is fetchable.
    final token = await zb.raw.files.getToken();
    final privUrlTok = zb.privatePhotos
        .fileUrl(priv, field: api.PrivatePhotoFileField.image, token: token);
    final ok = await http.get(Uri.parse(privUrlTok));
    expect(ok.statusCode, 200);
  });
}
