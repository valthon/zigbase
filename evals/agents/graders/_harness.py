"""Shared live-target harness primitives for migration graders."""

from __future__ import annotations

import json
import socket
import stat
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator, Protocol, TypeVar


EVAL_ENVIRONMENT = {
    "ZIGBASE_JWT_SECRET": "x" * 64,
    "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
    "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
}
MAX_HTTP_RESPONSE_BYTES = 1024 * 1024


class HttpResponseError(ValueError):
    """A live target returned a response the grader cannot safely inspect."""


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value}")


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def strict_json_loads(value: str | bytes) -> Any:
    """Parse RFC JSON while rejecting duplicate object keys and non-finite numbers."""
    return json.loads(
        value,
        parse_constant=_reject_json_constant,
        object_pairs_hook=_strict_object,
    )


def strict_utf8(payload: bytes, label: str) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{label} is not UTF-8") from exc


def read_bounded_regular(path: Path, maximum: int) -> bytes:
    """Read one regular file with a hard byte bound."""
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"{path} is not a regular file")
    if metadata.st_size > maximum:
        raise ValueError(f"{path} exceeds the {maximum}-byte limit")
    with path.open("rb") as stream:
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining and (chunk := stream.read(min(64 * 1024, remaining))):
            chunks.append(chunk)
            remaining -= len(chunk)
    payload = b"".join(chunks)
    if len(payload) > maximum:
        raise ValueError(f"{path} exceeds the {maximum}-byte limit")
    return payload


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


_HTTP_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _NoRedirectHandler()
)


class CommandRunner(Protocol):
    def run(
        self,
        argv: list[str],
        *,
        cwd: Path,
        env: dict[str, str] | None = None,
        timeout: int = 300,
    ) -> Any: ...


FailureT = TypeVar("FailureT")


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _bounded_body(response: Any, url: str) -> bytes:
    payload = response.read(MAX_HTTP_RESPONSE_BYTES + 1)
    if len(payload) > MAX_HTTP_RESPONSE_BYTES:
        raise HttpResponseError(
            f"{url} response exceeds the {MAX_HTTP_RESPONSE_BYTES}-byte limit"
        )
    return payload


def http_response(
    request: urllib.request.Request | str,
    timeout: float,
    *,
    include_error_status: bool,
) -> tuple[int, bytes, Any]:
    """Read the first HTTP response without redirects, with a bounded binary body."""
    url = request.full_url if isinstance(request, urllib.request.Request) else request
    try:
        with _HTTP_OPENER.open(request, timeout=timeout) as response:
            return response.status, _bounded_body(response, url), response.headers
    except urllib.error.HTTPError as error:
        if not include_error_status:
            raise
        with error:
            return error.code, _bounded_body(error, url), error.headers


def health_json(url: str, timeout: float) -> Any:
    status, payload, _ = http_response(url, timeout, include_error_status=False)
    if status != 200:
        raise HttpResponseError(
            f"{url} readiness response has HTTP status {status}, not 200"
        )
    try:
        value = strict_json_loads(strict_utf8(payload, f"{url} response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise HttpResponseError(f"{url} response is not strict JSON: {exc}") from exc
    if not isinstance(value, dict) or value.get("status") != "ok":
        raise HttpResponseError(f"{url} response does not report status 'ok'")
    return value


@contextmanager
def served_target(
    commands: CommandRunner,
    binary: str,
    workspace: Path,
    data: Path,
    port: int,
    health_getter: Callable[..., Any],
    wait_for_health: Callable[..., Any],
    failures: list[FailureT],
    check_start: Callable[[Any], None],
    teardown_failure: Callable[[Any], FailureT | None],
    *,
    serve_static: Path | None = None,
    health_attempts: int = 30,
) -> Iterator[str]:
    argv = [
        binary,
        "serve",
        "--background",
        "--insecure-cookies",
        "--http-port",
        str(port),
        "--data-dir",
        str(data),
    ]
    if serve_static is not None:
        argv.extend(("--serve-static", str(serve_static)))
    start_invoked = False
    try:
        start_invoked = True
        result = commands.run(
            argv,
            cwd=workspace,
            env=dict(EVAL_ENVIRONMENT),
            timeout=60,
        )
        check_start(result)
        base = f"http://127.0.0.1:{port}"
        wait_for_health(
            health_getter,
            f"{base}/api/health",
            health_attempts,
        )
        yield base
    finally:
        if start_invoked:
            try:
                stopped = commands.run(
                    [binary, "serve", "stop", "--data-dir", str(data)],
                    cwd=workspace,
                    env=dict(EVAL_ENVIRONMENT),
                    timeout=30,
                )
            except Exception as exc:
                stopped = exc
            if failure := teardown_failure(stopped):
                failures.append(failure)
