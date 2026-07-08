/// Verified sender-identity management. `list` requires ZigBase >= 0.10.0
/// (the `{items}` envelope); `create`/`verify` exist as of 0.9.0. All three
/// verbs are account-scoped exactly like the record API.
///
/// A port of `SendersService` in `clients/typescript/src/senders.ts`. The
/// wire fields are snake_case (`src/api/senders.zig`): `verified_at` is
/// always present on the list endpoint (`TEXT NOT NULL DEFAULT ''`, so it is
/// `""` — never JSON `null` — for a pending identity) but absent on the
/// create response. Both cases are normalized to Dart's `verifiedAt == null`.
library;

import 'transport.dart';

/// One verified-sender identity of the active account.
class SenderIdentity {
  final String id;
  final String email;
  final String status;
  final String? verifiedAt;

  SenderIdentity({
    required this.id,
    required this.email,
    required this.status,
    this.verifiedAt,
  });

  factory SenderIdentity.fromJson(Map<String, dynamic> json) {
    final raw = json['verified_at'];
    return SenderIdentity(
      id: json['id'] as String,
      email: json['email'] as String,
      status: json['status'] as String,
      verifiedAt: (raw is String && raw.isNotEmpty) ? raw : null,
    );
  }
}

class SendersService {
  final Transport _transport;

  SendersService(this._transport);

  /// `GET /api/senders` — the active account's sender identities. Requires
  /// ZigBase >= 0.10.0.
  Future<List<SenderIdentity>> list() async {
    final res = await _transport.send('/api/senders') as Map<String, dynamic>;
    final rawItems = res['items'] as List<dynamic>? ?? const [];
    return rawItems
        .map((e) => SenderIdentity.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// `POST /api/senders` — request verification of a From address. The token
  /// is EMAILED to that address, never returned. 201 pending / 200
  /// already-verified; rejects with a 429 [ZigbaseException] when a re-send
  /// is throttled.
  Future<SenderIdentity> create(String email) async {
    final res = await _transport.send(
      '/api/senders',
      method: 'POST',
      body: {'email': email},
    ) as Map<String, dynamic>;
    return SenderIdentity.fromJson(res);
  }

  /// `POST /api/senders/:id/verify` — 404 for a wrong token/account/id
  /// (deliberate non-oracle).
  Future<bool> verify(String id, String token) async {
    final res = await _transport.send(
      '/api/senders/${Uri.encodeComponent(id)}/verify',
      method: 'POST',
      body: {'token': token},
    ) as Map<String, dynamic>;
    return res['verified'] as bool? ?? false;
  }
}
