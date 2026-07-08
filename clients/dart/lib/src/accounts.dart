/// Multi-tenancy account activation (requires ZigBase >= 0.9.0 with
/// `.tenancy` enabled).
///
/// A port of `AccountsService` in `clients/typescript/src/accounts.ts`; the
/// wire envelope (`{account, role}`) is confirmed against `src/api/accounts.zig`.
library;

import 'transport.dart';

/// The active account scope returned by `POST /api/accounts/:id/activate`.
class AccountScope {
  final String account;
  final String role;

  AccountScope({required this.account, required this.role});

  factory AccountScope.fromJson(Map<String, dynamic> json) {
    return AccountScope(
      account: json['account'] as String,
      role: json['role'] as String,
    );
  }
}

/// Multi-tenancy account operations.
class AccountsService {
  final Transport _transport;

  AccountsService(this._transport);

  /// `POST /api/accounts/:id/activate` — verifies an ACTIVE membership, sets
  /// the signed `zb_account` cookie (same-origin browser apps), and returns
  /// the scope. 403 when not a member; 404 when tenancy is disabled. API/SSR
  /// clients should prefer a dedicated `X-Account-Id`-scoped client — the SDK
  /// never reads the cookie itself.
  Future<AccountScope> activate(String accountId) async {
    final res = await _transport.send(
      '/api/accounts/${Uri.encodeComponent(accountId)}/activate',
      method: 'POST',
    ) as Map<String, dynamic>;
    return AccountScope.fromJson(res);
  }
}
