"""Tests for zigbase.auth_store, a port of clients/typescript/src/auth-store.ts."""

import base64
import json
import os
import stat
import time
from pathlib import Path
from typing import Any

from zigbase.auth_store import AuthStore, FileAuthStore, MemoryAuthStore


def _make_jwt(payload: dict[str, object]) -> str:
    header = base64.urlsafe_b64encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()).rstrip(
        b"="
    )
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=")
    return f"{header.decode()}.{body.decode()}.sig"


def _valid_token() -> str:
    return _make_jwt({"id": "u1", "exp": int(time.time()) + 3600})


def _expired_token() -> str:
    return _make_jwt({"id": "u1", "exp": int(time.time()) - 10})


class TestMemoryAuthStoreRoundTrip:
    def test_starts_empty(self) -> None:
        store = MemoryAuthStore()
        assert store.token is None
        assert store.record is None
        assert store.is_valid is False

    def test_save_then_clear_round_trips(self) -> None:
        store = MemoryAuthStore()
        token = _valid_token()
        record = {"id": "u1", "email": "a@b.com"}

        store.save(token, record)
        assert store.token == token
        assert store.record == record

        store.clear()
        assert store.token is None
        assert store.record is None

    def test_save_accepts_a_none_record(self) -> None:
        store = MemoryAuthStore()
        token = _valid_token()
        store.save(token, None)
        assert store.token == token
        assert store.record is None


class TestIsValid:
    def test_true_for_a_valid_unexpired_token(self) -> None:
        store = MemoryAuthStore()
        store.save(_valid_token(), None)
        assert store.is_valid is True

    def test_false_for_an_expired_token(self) -> None:
        store = MemoryAuthStore()
        store.save(_expired_token(), None)
        assert store.is_valid is False

    def test_false_when_no_token_is_present(self) -> None:
        store = MemoryAuthStore()
        assert store.is_valid is False


class TestOnChange:
    def test_fires_on_save(self) -> None:
        store = MemoryAuthStore()
        calls: list[tuple[str | None, dict[str, Any] | None]] = []
        store.on_change(lambda token, record: calls.append((token, record)))

        token = _valid_token()
        store.save(token, {"id": "u1"})

        assert calls == [(token, {"id": "u1"})]

    def test_fires_on_clear(self) -> None:
        store = MemoryAuthStore()
        store.save(_valid_token(), {"id": "u1"})
        calls: list[tuple[str | None, dict[str, Any] | None]] = []
        store.on_change(lambda token, record: calls.append((token, record)))

        store.clear()

        assert calls == [(None, None)]

    def test_fires_after_state_has_already_changed(self) -> None:
        store = MemoryAuthStore()
        observed: list[str | None] = []

        def listener(token: str | None, record: dict[str, Any] | None) -> None:
            observed.append(store.token)

        store.on_change(listener)
        token = _valid_token()
        store.save(token, None)

        assert observed == [token]

    def test_unsubscribe_stops_further_notifications(self) -> None:
        store = MemoryAuthStore()
        calls: list[str | None] = []
        unsubscribe = store.on_change(lambda token, record: calls.append(token))

        store.save(_valid_token(), None)
        unsubscribe()
        store.clear()

        assert len(calls) == 1

    def test_a_raising_listener_does_not_block_the_next_listener(self) -> None:
        store = MemoryAuthStore()
        calls: list[str] = []

        def bad_listener(token: str | None, record: dict[str, Any] | None) -> None:
            raise RuntimeError("boom")

        def good_listener(token: str | None, record: dict[str, Any] | None) -> None:
            calls.append("called")

        store.on_change(bad_listener)
        store.on_change(good_listener)

        store.save(_valid_token(), None)

        assert calls == ["called"]


class TestFileAuthStore:
    def test_starts_empty_when_file_is_missing(self, tmp_path: Path) -> None:
        store = FileAuthStore(tmp_path / "auth.json")
        assert store.token is None
        assert store.record is None

    def test_save_persists_to_disk_and_creates_parent_dirs(self, tmp_path: Path) -> None:
        path = tmp_path / "nested" / "dir" / "auth.json"
        store = FileAuthStore(path)
        token = _valid_token()
        record = {"id": "u1"}

        store.save(token, record)

        assert path.exists()
        on_disk = json.loads(path.read_text(encoding="utf-8"))
        assert on_disk == {"token": token, "record": record}

    def test_persists_across_instances(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        token = _valid_token()
        record = {"id": "u1"}
        FileAuthStore(path).save(token, record)

        reloaded = FileAuthStore(path)

        assert reloaded.token == token
        assert reloaded.record == record

    def test_clear_persists_nulls(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        store = FileAuthStore(path)
        store.save(_valid_token(), {"id": "u1"})

        store.clear()

        on_disk = json.loads(path.read_text(encoding="utf-8"))
        assert on_disk == {"token": None, "record": None}

        reloaded = FileAuthStore(path)
        assert reloaded.token is None
        assert reloaded.record is None

    def test_corrupt_file_starts_empty(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        path.write_text("{not valid json", encoding="utf-8")

        store = FileAuthStore(path)

        assert store.token is None
        assert store.record is None

    def test_non_object_json_starts_empty(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        path.write_text("[1, 2, 3]", encoding="utf-8")

        store = FileAuthStore(path)

        assert store.token is None
        assert store.record is None

    def test_non_utf8_bytes_start_empty(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        # e.g. a file truncated mid-write by a crash -- not valid UTF-8 at all.
        path.write_bytes(b"\xff\xfe\x00\x01garbage-not-utf8")

        store = FileAuthStore(path)

        assert store.token is None
        assert store.record is None

    def test_unreadable_file_starts_empty(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        path.mkdir()  # a directory where a file is expected -> unreadable as a file

        store = FileAuthStore(path)

        assert store.token is None
        assert store.record is None

    def test_on_change_still_fires_for_a_file_backed_store(self, tmp_path: Path) -> None:
        store = FileAuthStore(tmp_path / "auth.json")
        calls: list[str | None] = []
        store.on_change(lambda token, record: calls.append(token))

        token = _valid_token()
        store.save(token, None)

        assert calls == [token]

    def test_save_creates_the_file_with_owner_only_permissions(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        store = FileAuthStore(path)

        store.save(_valid_token(), {"id": "u1"})

        mode = stat.S_IMODE(os.stat(path).st_mode)
        assert mode == 0o600

    def test_clear_preserves_owner_only_permissions(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        store = FileAuthStore(path)
        store.save(_valid_token(), {"id": "u1"})

        store.clear()

        mode = stat.S_IMODE(os.stat(path).st_mode)
        assert mode == 0o600

    def test_overwriting_an_existing_store_replaces_content_atomically(
        self, tmp_path: Path
    ) -> None:
        path = tmp_path / "auth.json"
        store = FileAuthStore(path)
        store.save(_valid_token(), {"id": "u1", "email": "old@example.com"})

        second_token = _valid_token()
        store.save(second_token, {"id": "u1", "email": "new@example.com"})

        on_disk = json.loads(path.read_text(encoding="utf-8"))
        assert on_disk == {
            "token": second_token,
            "record": {"id": "u1", "email": "new@example.com"},
        }

    def test_save_leaves_no_leftover_temp_file(self, tmp_path: Path) -> None:
        path = tmp_path / "auth.json"
        store = FileAuthStore(path)

        store.save(_valid_token(), {"id": "u1"})

        leftovers = [p for p in tmp_path.iterdir() if p.name != "auth.json"]
        assert leftovers == []


class TestAuthStoreIsAbstractBase:
    def test_memory_and_file_stores_are_auth_stores(self, tmp_path: Path) -> None:
        assert isinstance(MemoryAuthStore(), AuthStore)
        assert isinstance(FileAuthStore(tmp_path / "auth.json"), AuthStore)
