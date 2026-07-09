"""Multi-tenancy account activation (requires ZigBase >= 0.9.0 with
`.tenancy` enabled).

Port of clients/typescript/src/accounts.ts (`AccountsService`); cross-checked
against clients/dart/lib/src/accounts.dart. The `{account, role}` envelope is
confirmed against src/api/accounts.zig.
"""

from __future__ import annotations

from typing import Any, cast

from zigbase._request import RequestSpec, encode_path_segment
from zigbase._transport import AsyncTransport, SyncTransport


def _activate_path(account_id: str) -> str:
    return f"/api/accounts/{encode_path_segment(account_id)}/activate"


class AccountsService:
    """`POST /api/accounts/:id/activate`, over a `SyncTransport`."""

    def __init__(self, transport: SyncTransport) -> None:
        self._transport = transport

    def activate(self, account_id: str) -> dict[str, Any]:
        """Verify an ACTIVE membership, set the signed `zb_account` cookie
        (same-origin browser apps), and return `{account, role}`. 403 when
        not a member; 404 when tenancy is disabled. API/SSR clients should
        prefer a dedicated `X-Account-Id`-scoped client -- the SDK never
        reads the cookie itself."""
        body = self._transport.request(RequestSpec(method="POST", path=_activate_path(account_id)))
        return cast(dict[str, Any], body)


class AsyncAccountsService:
    """`AccountsService`'s `asyncio` mirror, over an `AsyncTransport`."""

    def __init__(self, transport: AsyncTransport) -> None:
        self._transport = transport

    async def activate(self, account_id: str) -> dict[str, Any]:
        """See `AccountsService.activate`."""
        body = await self._transport.request(
            RequestSpec(method="POST", path=_activate_path(account_id))
        )
        return cast(dict[str, Any], body)


__all__ = ["AccountsService", "AsyncAccountsService"]
