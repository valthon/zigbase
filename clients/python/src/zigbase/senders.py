"""Verified sender-identity management. `list` requires ZigBase >= 0.10.0
(the `{items}` envelope); `create`/`verify` exist as of 0.9.0. All three
verbs are account-scoped exactly like the record API (`withAccount` / the
`zb_account` cookie / superuser header).

Port of clients/typescript/src/senders.ts (`SendersService`); cross-checked
against clients/dart/lib/src/senders.dart and src/api/senders.zig.
"""

from __future__ import annotations

from typing import Any, cast

from zigbase._request import RequestSpec, encode_path_segment
from zigbase._transport import AsyncTransport, SyncTransport


def _verify_path(sender_id: str) -> str:
    return f"/api/senders/{encode_path_segment(sender_id)}/verify"


def _unwrap_items(body: Any) -> list[dict[str, Any]]:
    envelope = cast(dict[str, Any], body)
    items = envelope.get("items")
    return list(items) if isinstance(items, list) else []


class SendersService:
    """Verified sender-identity management, over a `SyncTransport`."""

    def __init__(self, transport: SyncTransport) -> None:
        self._transport = transport

    def list(self) -> list[dict[str, Any]]:
        """`GET /api/senders` -- the active account's sender identities.
        Unwraps `{items}`. Requires ZigBase >= 0.10.0."""
        body = self._transport.request(RequestSpec(method="GET", path="/api/senders"))
        return _unwrap_items(body)

    def create(self, email: str) -> dict[str, Any]:
        """`POST /api/senders` -- request verification of a From address.
        The token is EMAILED to that address, never returned. 201 pending /
        200 already-verified; raises a 429 `ZigbaseError` when a re-send is
        throttled."""
        body = self._transport.request(
            RequestSpec(method="POST", path="/api/senders", body={"email": email})
        )
        return cast(dict[str, Any], body)

    def verify(self, sender_id: str, token: str) -> bool:
        """`POST /api/senders/:id/verify` -- confirm a pending identity.
        Returns the `verified` flag from the `{verified: bool}` response
        (200, not 204 -- src/api/senders.zig always answers with a body).
        404 for a wrong token/account/id (deliberate non-oracle)."""
        body = self._transport.request(
            RequestSpec(method="POST", path=_verify_path(sender_id), body={"token": token})
        )
        return bool(cast(dict[str, Any], body).get("verified", False))


class AsyncSendersService:
    """`SendersService`'s `asyncio` mirror, over an `AsyncTransport`."""

    def __init__(self, transport: AsyncTransport) -> None:
        self._transport = transport

    async def list(self) -> list[dict[str, Any]]:
        """See `SendersService.list`."""
        body = await self._transport.request(RequestSpec(method="GET", path="/api/senders"))
        return _unwrap_items(body)

    async def create(self, email: str) -> dict[str, Any]:
        """See `SendersService.create`."""
        body = await self._transport.request(
            RequestSpec(method="POST", path="/api/senders", body={"email": email})
        )
        return cast(dict[str, Any], body)

    async def verify(self, sender_id: str, token: str) -> bool:
        """See `SendersService.verify`."""
        body = await self._transport.request(
            RequestSpec(method="POST", path=_verify_path(sender_id), body={"token": token})
        )
        return bool(cast(dict[str, Any], body).get("verified", False))


__all__ = ["AsyncSendersService", "SendersService"]
