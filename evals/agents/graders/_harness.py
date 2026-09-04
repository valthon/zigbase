"""Shared live-target harness primitives for migration graders."""

from __future__ import annotations

import json
import os
import socket
import stat
import tempfile
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator, Protocol, TypeVar

from tools.rails._core import strict_json_loads


EVAL_ENVIRONMENT = {
    "ZIGBASE_JWT_SECRET": "x" * 64,
    "ZIGBASE_SMTP_HOST": "smtp.example.invalid",
    "ZIGBASE_PUBLIC_URL": "https://eval.invalid",
}
MAX_HTTP_RESPONSE_BYTES = 1024 * 1024


def write_private_text(path: Path, payload: str) -> None:
    """Atomically replace one runner-owned private text artifact."""
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary: Path | None = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class HttpResponseError(ValueError):
    """A live target returned a response the grader cannot safely inspect."""


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


def read_regular_first_line(path: Path, maximum: int) -> bytes:
    """Read one bounded first line without loading the rest of a regular file."""
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"{path} is not a regular file")
    with path.open("rb") as stream:
        line = stream.readline(maximum + 1)
    if len(line) > maximum:
        raise ValueError(f"{path} first line exceeds the {maximum}-byte limit")
    return line


def canonical_executable(candidate: str | None) -> Path | None:
    """Resolve one executable once, returning no unresolved or non-executable path."""
    if not candidate:
        return None
    try:
        resolved = Path(candidate).resolve(strict=True)
    except OSError:
        return None
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        return None
    return resolved


def regular_file_inventory(
    root: Path,
    *,
    ignored: Callable[[Path], bool],
    maximum_file: int,
    maximum_total: int,
) -> dict[Path, tuple[Path, int]]:
    """Inventory a bounded regular-file tree, leaving domain errors to the caller."""
    files: dict[Path, tuple[Path, int]] = {}
    total = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ignored(relative):
            continue
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode) or not (
            stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
        ):
            raise ValueError(f"unsupported file type: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if metadata.st_size > maximum_file:
            raise ValueError(f"oversized file: {relative}")
        total += metadata.st_size
        if total > maximum_total:
            raise ValueError("file inventory exceeds its total byte limit")
        files[relative] = (path, metadata.st_size)
    return files


def require_command_success(
    result: Any,
    code: str,
    what: str,
    failure_factory: Callable[[str, str], Exception],
) -> None:
    """Raise the caller's domain failure when a command did not complete cleanly."""
    if result.timed_out:
        raise failure_factory(code, f"{what} timed out")
    if result.output_truncated:
        raise failure_factory(code, f"{what} output exceeded the capture limit")
    if result.returncode != 0:
        raise failure_factory(
            code,
            f"{what} failed ({result.returncode}): "
            f"{(result.stderr or result.stdout)[-400:]}",
        )


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


def json_http_request(
    method: str,
    url: str,
    *,
    token: str | None = None,
    body: Any = None,
    timeout: float = 15,
) -> tuple[int, bytes, Any]:
    """Send one JSON API request using the shared bounded, no-redirect transport."""
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    return http_response(request, timeout, include_error_status=True)


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
