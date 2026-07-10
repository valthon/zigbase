# Python Client SDK SP1 (Base Client) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `clients/python/` — PyPI package `zigbase` 0.1.0, a feature-parity port of the **base tier** of `@zigbase/client` (REST + auth + OAuth2/PKCE + files + cursor pagination) with a sync `ZigBase` and async `AsyncZigBase` surface, unit + integration tests, a CI job, and synced docs. Realtime is SP2; typed codegen is SP3 — both out of scope here.

**Architecture:** Async-core dual surface over httpx: a pure request-spec core (`_request.py` builders, no I/O) consumed by two thin transports (`SyncTransport` over `httpx.Client`, `AsyncTransport` over `httpx.AsyncClient`) that own the 401 single-flight refresh and 429 backoff state machines. Each service module contains its sync and async variant side by side. Records are plain `dict[str, Any]`.

**Tech Stack:** Python ≥3.10 (developed under mise-pinned 3.13), runtime dep **httpx only**; dev: pytest, pytest-asyncio, ruff, mypy. Build backend: hatchling.

**Normative reference:** The TypeScript SDK at `clients/typescript/src/` is the authoritative behavior spec, exactly as it was for Dart. Where a task says "port `X.ts`", read that file (and its Dart port under `clients/dart/lib/src/` for a second worked example) and reproduce its wire behavior exactly, adapted to the Python signatures in the task's **Interfaces** block. Carry the Dart hardening improvements (they are part of the contract now): named-placeholder filter builder, malformed-error-`data` skipping, loud rejection of non-encodable body values, explicit `close()` ownership, millisecond-clamped UTC ISO-8601 dates, JS-JSON byte format for vector specs. The design spec is `docs/superpowers/specs/2026-07-09-python-sdk-design.md`.

## Global Constraints

- Package name `zigbase`, version `0.1.0`, path `clients/python/`, src layout `clients/python/src/zigbase/`.
- Python floor **3.10** (`requires-python = ">=3.10"`); all commands run as `mise exec python@3.13 -- python -m <cmd>` from `clients/python/` unless stated.
- Runtime dependency: **httpx only** (`httpx>=0.27,<1`). No pydantic, no websockets in SP1.
- All server paths root at `<base_url>/api/...`. Auth header `Authorization: Bearer <token>`. Bearer-only client: never send cookies, never send `X-CSRF-Token`.
- Updates are **PATCH** (never PUT). Side-effect success is **204** → return `None` without JSON-parsing. On 2xx parse JSON only if the body is non-empty.
- Error envelope: `{code, message, data}`; denial semantics: create → 403, view/update/delete on nonexistent-or-denied → 404. Never treat 404 as "definitely missing" in docs/tests.
- Cursor tokens are opaque: round-trip verbatim, never parse or synthesize.
- Gates at every commit, run from `clients/python/`: `ruff format --check .`, `ruff check .`, `mypy src`, `pytest -m "not integration" -q`.
- Commit after every task: `feat(python-sdk): ...` / `test(python-sdk): ...`, ending with the Claude co-author trailer.
- Public API symbols exactly as specified in **Interfaces** blocks — later tasks depend on the exact names.
- **Documented divergences from TS/Dart (deliberate, put them in the module docstrings and docs):** no `requestKey` dedup / `ZigbaseCancelledError` (Python's audiences don't need auto-cancel; use httpx-native `timeout=` per request instead of `signal`); realtime absent until SP2.
- Every Python source file's module docstring names its TS counterpart (e.g. `Port of clients/typescript/src/transport.ts`), as the Dart files do.

---

### Task 1: Package scaffold + toolchain

**Files:**
- Create: `clients/python/pyproject.toml`, `clients/python/README.md` (stub: name, one-paragraph description, "SP1 in development"), `clients/python/LICENSE` (copy `clients/typescript/LICENSE`), `clients/python/.gitignore`, `clients/python/src/zigbase/__init__.py`, `clients/python/src/zigbase/_version.py`, `clients/python/tests/test_smoke.py`

**Interfaces:**
- Produces: `__version__ = "0.1.0"` in `src/zigbase/_version.py`, re-exported from `zigbase.__init__`.

- [ ] **Step 1: Write scaffold files**

`clients/python/pyproject.toml`:
```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "zigbase"
version = "0.1.0"
description = "Official Python client for ZigBase - REST, auth, cursor pagination, and files."
readme = "README.md"
license = "Apache-2.0"
requires-python = ">=3.10"
authors = [{ name = "David J Parrott", email = "valthon@nothlav.net" }]
dependencies = ["httpx>=0.27,<1"]

[project.optional-dependencies]
dev = ["pytest>=8", "pytest-asyncio>=0.24", "ruff>=0.8", "mypy>=1.13"]

[project.urls]
Repository = "https://github.com/valthon/zigbase"

[tool.hatch.build.targets.wheel]
packages = ["src/zigbase"]

[tool.ruff]
line-length = 100
target-version = "py310"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "SIM", "RUF"]

[tool.mypy]
strict = true
python_version = "3.10"

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
markers = ["integration: requires a zigbase server binary (ZIGBASE_TEST_BINARY)"]
```

`.gitignore`: `__pycache__/`, `*.egg-info/`, `dist/`, `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/`.

`src/zigbase/_version.py`: `__version__ = "0.1.0"`.
`src/zigbase/__init__.py`: module docstring + `from zigbase._version import __version__` + `__all__ = ["__version__"]`.
`tests/test_smoke.py`:
```python
import zigbase


def test_exports_version() -> None:
    assert zigbase.__version__ == "0.1.0"
```

- [ ] **Step 2: Install and verify**

From `clients/python/`: `mise exec python@3.13 -- python -m pip install --quiet -e '.[dev]'`, then run all four gates (Global Constraints). Expected: PASS (1 test).

- [ ] **Step 3: Commit** (`feat(python-sdk): scaffold zigbase package`)

---

### Task 2: Errors + JWT utilities

**Files:**
- Create: `src/zigbase/errors.py`, `src/zigbase/_jwt.py`, `tests/test_errors.py`, `tests/test_jwt.py`
- Modify: `src/zigbase/__init__.py` (export `ZigbaseError`, `FieldError`)

**Interfaces (Produces):**
```python
# errors.py — port of clients/typescript/src/errors.ts
@dataclass(frozen=True)
class FieldError:
    code: str
    message: str

class ZigbaseError(Exception):
    status: int          # HTTP status; 0 = client-side protocol violation (non-advancing cursor)
    message: str
    data: dict[str, FieldError]
    url: str
    def __init__(self, *, status: int, message: str, data: dict[str, FieldError] | None = None, url: str) -> None: ...
    # str(e) == f"ZigbaseError({status}): {message} ({url})"

def parse_error_response(status: int, body_text: str, url: str, reason_phrase: str | None = None) -> ZigbaseError: ...

# _jwt.py — port of clients/typescript/src/jwt.ts
def decode_jwt_payload(token: str) -> dict[str, Any] | None: ...   # None on ANY malformed input
def is_token_expired(token: str, leeway_seconds: int = 0) -> bool: ...  # True when no/expired exp
```

`parse_error_response` parses `{message?, data?}` where `data` maps field → `{code, message}`; **skip** malformed `data` entries (Dart hardening) instead of defaulting; on non-JSON body fall back to `reason_phrase`, then `f"Request failed with status {status}"`. `decode_jwt_payload` base64url-decodes segment 1 with `=` padding, UTF-8, `json.loads`; any exception → `None`.

- [ ] **Step 1: Write failing tests** — valid error JSON with field data; malformed `data` entry skipped; non-JSON body → reason_phrase → generic fallback; `decode_jwt_payload` round-trips a hand-built token (`base64.urlsafe_b64encode(json.dumps({"id": "u1", "exp": 9999999999}).encode()).rstrip(b"=")` glued with dots, header/signature segments arbitrary); malformed → None; `is_token_expired`: far-future exp → False, past exp → True, missing exp → True, leeway respected.
- [ ] **Step 2: Run `pytest tests/test_errors.py tests/test_jwt.py -q`, verify FAIL** (import error).
- [ ] **Step 3: Implement both modules; export from `__init__.py`.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): error model and jwt utilities`)

---

### Task 3: Query helpers — filter builder, dates, vector, list params

**Files:**
- Create: `src/zigbase/query.py`, `tests/test_query.py`
- Modify: `src/zigbase/__init__.py` (export `zb_filter`)

**Interfaces (Produces):**
```python
# query.py — port of clients/typescript/src/query.ts (+ Dart lib/src/query.dart placeholders)
def filter_value(value: object) -> str: ...
def zb_filter(expr: str, params: Mapping[str, object]) -> str: ...
def format_date(dt: datetime) -> str: ...          # ms-clamped UTC ISO-8601, trailing 'Z'
def vector_spec(field: str, embedding: Sequence[float], *, metric: str | None = None) -> str: ...
def build_list_params(
    *, filter: str | None = None, sort: str | None = None, expand: str | None = None,
    fields: str | None = None, search: str | None = None,
    page: int | None = None, per_page: int | None = None,
    cursor: str | None = None, limit: int | None = None,
    skip_total: bool | None = None, vector: str | None = None,
) -> dict[str, str]: ...
```

Byte-parity rules (must match TS/Dart output exactly — the server lexer is the arbiter):
- `filter_value`: `str` → single-quoted with `\`, `'`, `\n`, `\t`, `\r` escaped; `bool` → `true`/`false`; `int`/finite `float` → bare (integral floats render bare: `1` not `1.0`); `None` → `null`; `datetime` → quoted `format_date`; list/dict/non-finite float → raise `TypeError` naming the offending value (Dart hardening: reject, don't coerce).
- `zb_filter("status = {:s} && n > {:n}", {"s": "it's", "n": 5})` → `status = 'it\'s' && n > 5`; unknown placeholder or unused param → `KeyError`/`ValueError`.
- `format_date`: microseconds truncated to milliseconds, always UTC, `YYYY-MM-DDTHH:MM:SS.mmmZ` (byte-for-byte JS `Date.toISOString()`); naive datetimes assumed UTC.
- `vector_spec`: renders the embedding with JS-JSON byte format (integral floats bare); read `clients/typescript/src/query.ts` for the exact `field:json[:limit]` spec string.
- `build_list_params`: emits wire param names (`perPage`, `skipTotal` as `true`/`false` strings, etc.); **omits** absent params entirely — never emit an empty `cursor`/`limit` (presence selects cursor mode).

- [ ] **Step 1: Write failing tests** — escaping cases incl. quote/backslash/newline injection attempts (assert the closing quote never appears unescaped); numeric/bool/None/datetime rendering; reject list/dict/NaN/inf; placeholder happy path + unknown/unused; `format_date` on a microsecond-precision aware and naive datetime; `vector_spec` byte-exactness vs a hardcoded expected string; `build_list_params` omission behavior.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement; export `zb_filter`.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): injection-safe filter builder and query helpers`)

---

### Task 4: Auth stores

**Files:**
- Create: `src/zigbase/auth_store.py`, `tests/test_auth_store.py`
- Modify: `src/zigbase/__init__.py` (export `AuthStore`, `MemoryAuthStore`, `FileAuthStore`)

**Interfaces (Produces):**
```python
# auth_store.py — port of clients/typescript/src/auth-store.ts
AuthChangeCallback = Callable[[str | None, dict[str, Any] | None], None]

class AuthStore(ABC):                      # base class with the onChange plumbing implemented
    @property
    def token(self) -> str | None: ...
    @property
    def record(self) -> dict[str, Any] | None: ...
    @property
    def is_valid(self) -> bool: ...        # token present and not is_token_expired (UX only)
    def save(self, token: str | None, record: dict[str, Any] | None) -> None: ...
    def clear(self) -> None: ...
    def on_change(self, cb: AuthChangeCallback) -> Callable[[], None]: ...  # returns unsubscribe

class MemoryAuthStore(AuthStore): ...      # default; in-process only

class FileAuthStore(AuthStore):            # JSON file persistence, the CLI/script story
    def __init__(self, path: str | os.PathLike[str]) -> None: ...  # loads eagerly; missing/corrupt file = empty
```

`FileAuthStore` writes `{"token": ..., "record": ...}` as JSON on every save/clear (clear writes nulls), creating parent dirs; unreadable/corrupt file on load = start empty (repo philosophy: unreadable = nonexistent). `save`/`clear` fire callbacks after state change; exceptions in one callback don't block others.

- [ ] **Step 1: Write failing tests** — memory save/clear round-trip; `is_valid` with valid/expired/absent token (build tokens as in Task 2); on_change fires on save and clear, unsubscribe works, one raising callback doesn't starve the next; FileAuthStore persists across instances, corrupt file → empty store, clear persists nulls.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): auth stores with change notification`)

---

### Task 5: Body encoding — JSON + multipart

**Files:**
- Create: `src/zigbase/_multipart.py`, `tests/test_multipart.py`

**Interfaces (Produces):**
```python
# _multipart.py — port of clients/typescript/src/records.ts (hasBlob/toFormData) + Dart encodeMultipart
FileArg = Union[IO[bytes], tuple[str, bytes], tuple[str, bytes, str]]  # file-like | (filename, content[, content_type])

def has_file(body: Mapping[str, Any]) -> bool: ...   # top-level values and top-level lists only

def encode_body(body: Mapping[str, Any]) -> EncodedBody: ...

@dataclass
class EncodedBody:
    json_body: dict[str, Any] | None      # set when no files
    fields: list[tuple[str, str]] | None  # multipart text parts (key repetition allowed)
    files: list[tuple[str, tuple[str, bytes, str | None]]] | None  # httpx files= format
```

Multipart field encoding (byte parity with TS `toFormData`): Python has no `undefined`, so the rule is **key absent = skipped, `None` → `""`** (document this divergence: TS distinguishes undefined/null; Python's `None` maps to TS `null`). `datetime` → `format_date`; nested dict/list-of-non-files → `json.dumps`; lists iterated element-wise (one part per element, key repeated); scalars → `str()` with bools as `true`/`false`. File content read **once** and buffered so transports can rebuild parts on retry (Dart hardening). Non-JSON-encodable value in the JSON path → `TypeError` naming the offending key (Dart hardening).

- [ ] **Step 1: Write failing tests** — no-file body passes through as json_body and rejects a non-encodable value naming the key; file at top level flips to multipart; list of files → repeated key; None → `""`; nested dict JSON-encoded; datetime formatted; bools lowercase; file-like buffered (second encode of same EncodedBody yields same bytes).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): body encoding with multipart auto-detection`)

---

### Task 6: Request spec + sync transport

**Files:**
- Create: `src/zigbase/_request.py`, `src/zigbase/_transport.py` (SyncTransport half), `tests/test_transport.py`

**Interfaces (Produces):**
```python
# _request.py — pure, no I/O
@dataclass
class RequestSpec:
    method: str                       # 'GET' | 'POST' | 'PATCH' | 'DELETE' | 'HEAD'
    path: str                         # '/api/...' (already URL-encoded segments)
    query: dict[str, str] | None = None
    body: Mapping[str, Any] | None = None   # encoded via _multipart.encode_body
    skip_auth: bool = False
    is_refresh: bool = False
    headers: dict[str, str] | None = None
    timeout: float | None = None

def encode_path_segment(s: str) -> str: ...   # urllib.parse.quote(s, safe="")

# _transport.py — port of clients/typescript/src/transport.ts
class SyncTransport:
    def __init__(self, base_url: str, auth_store: AuthStore, *,
                 auth_collection: str | None = None, auto_refresh: bool = False,
                 account_id: str | None = None, lang: str | None = None,
                 max_retries: int = 3, http_client: httpx.Client | None = None) -> None: ...
    def request(self, spec: RequestSpec) -> Any: ...   # parsed JSON | None (204/empty)
    def raw_request(self, spec: RequestSpec) -> httpx.Response: ...
    def close(self) -> None: ...      # closes http_client only if self-created
```

Behavior contract (read `transport.ts` and mirror; each rule below is a test):
1. Header assembly: `Authorization: Bearer <token>` unless `skip_auth` or no token; `Accept-Language` from `lang`; `X-Account-Id` from `account_id` unless the spec's headers already set it; per-spec headers win.
2. 2xx: 204 or empty body → `None`; else `json.loads`.
3. Non-2xx → raise `parse_error_response(...)` result.
4. **429 backoff**: for ALL methods (matching TS transport.ts:212 and Dart — a 429 is rejected before processing, so retrying a write cannot duplicate side effects); honor numeric `Retry-After` verbatim, else `min(2**attempt * 0.2, 30.0)` seconds; up to `max_retries`; make sleep injectable (module-level `_sleep = time.sleep`) so tests don't wait.
5. **401 single-flight refresh** (when `auto_refresh` and `auth_collection` set and not `spec.is_refresh` and token present): first 401 triggers `POST /api/collections/{auth_collection}/auth-refresh` (marked `is_refresh`) guarded by a `threading.Lock`; concurrent 401s wait on the same refresh; on success `auth_store.save(token, record)` and retry the original **once** (per-exchange `did_refresh` flag); refresh failure → original 401 propagates. A 401 from the refresh call itself propagates (no recursion).
6. Multipart: when `encode_body` yields files, pass httpx `data=`/`files=` and **never** set Content-Type manually.
7. Network errors (httpx.TransportError) propagate natively — never wrapped in ZigbaseError.

- [ ] **Step 1: Write failing tests** using `httpx.MockTransport` (inject via `http_client=httpx.Client(transport=httpx.MockTransport(handler))`) — one test per rule above, incl.: two threads hitting 401 simultaneously cause exactly one refresh call (count via handler); refresh-401 propagates; 429 with `Retry-After: 0` retried max_retries times then raises; PATCH is also retried on 429 (parity with TS/Dart — no idempotency guard).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement `_request.py` + `SyncTransport`.**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): sync transport with refresh and backoff state machines`)

---

### Task 7: Async transport

**Files:**
- Modify: `src/zigbase/_transport.py` (add AsyncTransport)
- Create: `tests/test_transport_async.py`

**Interfaces (Produces):**
```python
class AsyncTransport:
    # identical constructor signature with http_client: httpx.AsyncClient | None
    async def request(self, spec: RequestSpec) -> Any: ...
    async def raw_request(self, spec: RequestSpec) -> httpx.Response: ...
    async def aclose(self) -> None: ...
```

Same behavior contract as Task 6, with `asyncio.Lock` for single-flight and `_asleep = asyncio.sleep` injectable. Share every pure helper with SyncTransport (header assembly, response decoding, backoff computation live in module-level functions used by both) — the only duplicated code is the await-shaped orchestration.

- [ ] **Step 1: Write failing tests** — mirror Task 6's cases with `httpx.AsyncClient(transport=httpx.MockTransport(handler))`; single-flight test uses `asyncio.gather` of two concurrent 401-triggering requests.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement, refactoring shared pure logic out of SyncTransport as needed (Task 6 tests must stay green).**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): async transport`)

---

### Task 8: Collection service — CRUD + pagination

**Files:**
- Create: `src/zigbase/collection.py`, `tests/test_collection.py`
- Modify: `src/zigbase/__init__.py` (export `ListResult`, `CursorPage`)

**Interfaces (Produces):**
```python
# collection.py — port of clients/typescript/src/collection.ts (CRUD/pagination half)
@dataclass
class ListResult:
    page: int; per_page: int; total_items: int; total_pages: int
    items: list[dict[str, Any]]

@dataclass
class CursorPage:
    items: list[dict[str, Any]]
    next_cursor: str | None; prev_cursor: str | None
    has_next: bool; has_prev: bool
    total_items: int | None

class CollectionService:      # obtained via client.collection(name); holds SyncTransport + name
    def get_list(self, page: int = 1, per_page: int = 30, *, filter: str | None = None,
                 sort: str | None = None, expand: str | None = None, fields: str | None = None,
                 search: str | None = None, skip_total: bool = False,
                 vector: str | None = None) -> ListResult: ...
    def get_one(self, record_id: str, *, expand: str | None = None, fields: str | None = None) -> dict[str, Any]: ...
    def get_first_list_item(self, filter: str, **opts: Any) -> dict[str, Any]: ...
    def create(self, body: Mapping[str, Any], *, expand: str | None = None, fields: str | None = None) -> dict[str, Any]: ...
    def update(self, record_id: str, body: Mapping[str, Any], *, expand: str | None = None, fields: str | None = None) -> dict[str, Any]: ...
    def delete(self, record_id: str) -> None: ...
    def get_abilities(self, record_id: str) -> dict[str, bool]: ...   # {view, update, delete}
    def get_page(self, *, cursor: str | None = None, limit: int | None = None,
                 with_total: bool = False, **opts: Any) -> CursorPage: ...
    def iterate(self, *, batch: int = 100, **opts: Any) -> Iterator[dict[str, Any]]: ...
    def get_full_list(self, *, batch: int = 100, **opts: Any) -> list[dict[str, Any]]: ...

class AsyncCollectionService:  # same surface, async; iterate returns AsyncIterator[dict[str, Any]]
    ...
```

Wire rules: paths `/api/collections/{encode_path_segment(name)}/records[/{encode_path_segment(id)}[/abilities]]`; `get_first_list_item` = `get_list(1, 1, skip_total=True, ...)`, raise a synthesized `ZigbaseError(status=404, message="The requested resource wasn't found.", url=<list url>)` when empty; `iterate`/`get_full_list` follow `next_cursor` and raise `ZigbaseError(status=0, ...)` on a **non-advancing cursor** (empty page still claiming has_next, or a repeated cursor token); cursor mode params only sent when set.

- [ ] **Step 1: Write failing tests** (MockTransport handler asserting method/path/query and returning canned envelopes) — offset list parses `{page,perPage,totalItems,totalPages,items}` into snake_case; get_one/create(POST)/update(PATCH)/delete(204→None); abilities; get_first_list_item found + synthesized-404-when-empty; get_page round-trips opaque cursor verbatim; iterate crosses 3 pages; non-advancing cursor raises status 0; async variants for list/create/iterate.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement both classes (share pure envelope-parsing helpers).**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): collection CRUD and cursor pagination`)

---

### Task 9: Collection auth methods + PKCE

**Files:**
- Modify: `src/zigbase/collection.py` (auth half), Create: `src/zigbase/pkce.py`, `tests/test_collection_auth.py`, `tests/test_pkce.py`

**Interfaces (Produces):**
```python
# on CollectionService (sync shown; AsyncCollectionService mirrors with async/await)
@dataclass
class AuthResponse:
    token: str
    record: dict[str, Any] | None     # None for oauth2/complete
    meta: dict[str, Any] | None

def auth_with_password(self, identity: str, password: str) -> AuthResponse: ...   # skip_auth; saves store
def auth_refresh(self) -> AuthResponse: ...                                       # is_refresh; saves store
def list_auth_providers(self) -> list[dict[str, Any]]: ...                        # unwraps {items}
def oauth2_init(self, provider: str) -> dict[str, Any]: ...                       # {authURL, clientId, scopes, state}
def auth_with_oauth2(self, *, provider: str, code: str, code_verifier: str,
                     redirect_url: str, state: str | None = None) -> AuthResponse: ...  # skip_auth; token-only save
def logout(self) -> None: ...                                    # clears store even on failure (try/finally)
def request_verification(self, email: str) -> None: ...
def confirm_verification(self, token: str) -> None: ...          # skip_auth
def request_password_reset(self, email: str) -> None: ...
def confirm_password_reset(self, token: str, password: str) -> None: ...  # skip_auth
def change_password(self, record_id: str, old_password: str, new_password: str) -> dict[str, Any]: ...
def list_sessions(self) -> list[dict[str, Any]]: ...             # keys stay wire snake_case
def revoke_session(self, session_id: str) -> None: ...
def revoke_all_sessions(self) -> None: ...                       # clears store even on failure

# pkce.py — port of clients/typescript/src/pkce.ts
def generate_code_verifier(length: int = 64) -> str: ...          # secrets, unreserved charset
def code_challenge_s256(verifier: str) -> str: ...                # base64url(sha256), no padding
```

Endpoint paths/bodies exactly per `collection.ts`: `auth-with-password` body `{"identity", "password"}`; `change_password` = PATCH records/:id with `{"password", "oldPassword"}` and, when the store's principal is the target record, re-auth with the new password so the bearer session stays live (port the TS logic including which identity field it reuses).

- [ ] **Step 1: Write failing tests** — auth_with_password saves `{token, record}` to store and sends no bearer; auth_refresh sends bearer + is exempt from auto-refresh; logout clears store even when handler returns 500; oauth2 complete stores token with record=None; verification/reset call the right paths and return None on 204; change_password re-auths when self, doesn't when other; sessions list/revoke; pkce: verifier charset/length, S256 vector (`code_challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")` — compute expected once with hashlib in the test).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement (sync + async).**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): collection auth, sessions, and pkce`)

---

### Task 10: Files, accounts, analytics, senders services

**Files:**
- Create: `src/zigbase/files.py`, `src/zigbase/accounts.py`, `src/zigbase/analytics.py`, `src/zigbase/senders.py`, `tests/test_services.py`

**Interfaces (Produces):**
```python
# files.py — port of clients/typescript/src/files.ts
class FilesService:
    def get_url(self, record: Mapping[str, Any], filename: str, *, download: bool = False,
                thumb: str | None = None, token: str | None = None) -> str: ...
    def get_url_for(self, collection: str, record_id: str, filename: str, *, download: bool = False,
                    thumb: str | None = None, token: str | None = None) -> str: ...
    def get_token(self) -> str: ...        # POST /api/files/token → token

# accounts.py: class AccountsService: def activate(self, account_id: str) -> dict[str, Any]  # {account, role}
# analytics.py: class AnalyticsService: def events(self, **opts) -> CursorPage; def rollup(self, name: str, **opts) -> list[dict]
# senders.py: class SendersService: def list(self) -> list[dict]; def create(self, email: str) -> dict; def verify(self, sender_id: str, token: str) -> bool  # {verified} per senders.ts/senders.zig — never 204
# Each has an Async* mirror sharing the same request-building helpers.
```

`get_url` is a pure string builder (no request): `{base_url}/api/files/{col}/{rec}/{filename}` with each segment `encode_path_segment`-ed; query `download=1`, `thumb=<spec>`, `token=<t>`; `col` derives from `record.get("collectionId") or record.get("collectionName")` — raise `ValueError` if neither present. Port exact behavior/paths for the other three from `accounts.ts`/`analytics.ts`/`senders.ts` (all `{items}` envelopes unwrapped).

- [ ] **Step 1: Write failing tests** — URL building incl. encoding of a filename with spaces and a `thumb`+`token` combo; missing collection keys raises; get_token; accounts.activate path/shape; analytics events cursor envelope; senders list/create/verify(204).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement (sync + async).**
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): files, accounts, analytics, senders services`)

---

### Task 11: Client facades

**Files:**
- Create: `src/zigbase/client.py`, `tests/test_client.py`
- Modify: `src/zigbase/__init__.py` (export `ZigBase`, `AsyncZigBase`)

**Interfaces (Produces):**
```python
# client.py — port of clients/typescript/src/client.ts
class ZigBase:
    def __init__(self, base_url: str, *, auth_store: AuthStore | None = None,
                 auto_refresh: bool = False, auth_collection: str | None = None,
                 account_id: str | None = None, lang: str | None = None,
                 max_retries: int = 3, http_client: httpx.Client | None = None) -> None: ...
    base_url: str
    auth_store: AuthStore
    def collection(self, name: str) -> CollectionService: ...
    files: FilesService
    accounts: AccountsService
    analytics: AnalyticsService
    senders: SendersService
    def send(self, method: str, path: str, *, query: dict[str, str] | None = None,
             body: Mapping[str, Any] | None = None, headers: dict[str, str] | None = None) -> Any: ...
    def raw_request(self, method: str, path: str, **kw: Any) -> httpx.Response: ...
    def health(self) -> dict[str, Any]: ...            # GET /api/health
    def with_account(self, account_id: str) -> "ZigBase": ...  # sibling sharing auth_store + http client
    def close(self) -> None: ...
    def __enter__(self) -> "ZigBase": ...              # context manager closes on exit
    def __exit__(self, *exc: object) -> None: ...

class AsyncZigBase:  # same surface; aclose(), __aenter__/__aexit__, AsyncCollectionService etc.
    ...
```

Ownership contract (Dart hardening): a self-created httpx client is closed by `close()`; an injected one is not; `with_account` siblings share the parent's transport client and auth_store — closing the parent closes shared resources, and using a closed client raises httpx's own error (document; don't add extra guards). `base_url` is normalized (trailing `/` stripped) at construction.

- [ ] **Step 1: Write failing tests** — collection() returns service bound to the right name; health(); send() hits arbitrary path with auth header; with_account sends `X-Account-Id` while parent doesn't, shares auth state; context manager closes self-created client (request after exit raises) but leaves injected client open; async mirror for construction/health/aclose.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement; finalize `__init__.py` exports** (`ZigBase`, `AsyncZigBase`, `AuthStore`, `MemoryAuthStore`, `FileAuthStore`, `ZigbaseError`, `FieldError`, `zb_filter`, `ListResult`, `CursorPage`, `AuthResponse`, `__version__`).
- [ ] **Step 4: Run all gates, verify PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): ZigBase and AsyncZigBase client facades`)

---

### Task 12: Integration test suite (live server)

**Files:**
- Create: `tests/integration/__init__.py`, `tests/integration/conftest.py`, `tests/integration/test_crud_live.py`, `tests/integration/test_auth_live.py`, `tests/integration/test_files_live.py`

**Interfaces:**
- Consumes: the whole public API from Tasks 1–11.
- Produces: pytest fixtures `server_url` (session-scoped launched binary) and `client` / `async_client`.

Harness: read `clients/dart/test/integration/` (the Dart launch/bootstrap sequence) and `tests/admin/conftest.py` (the repo's canonical Python server-launch pattern: free port via `socket.bind(("127.0.0.1", 0))`, temp data dir, `--insecure-cookies`, poll `/api/health` until ready, superuser via `superuser create --email ... --password ...`) and port that harness. Binary path from `ZIGBASE_TEST_BINARY` env; **skip the whole directory** (`pytest.skip(allow_module_level=True)` in conftest via a collection hook) when unset. Mark every test `@pytest.mark.integration`. Bootstrap collections/rules the same way the Dart integration suite does (mirror its setup calls — superuser client creates a test collection with `@public` rules plus a `users` auth flow).

Coverage (each its own test): password auth → CRUD round-trip with filter built by `zb_filter` → cursor iterate over >2 pages (create ~70 records, batch=30) → PATCH partial update → delete returns None then get_one raises 404 → abilities → locked-collection create as anon raises 403 → file upload via multipart create + `files.get_url` fetch round-trip → auth_refresh rotates token → logout clears store. Run each flow through **both** `ZigBase` and `AsyncZigBase` where cheap (parametrize the client fixture).

- [ ] **Step 1: Write conftest + one smoke integration test (health).** Build the server first: `mise exec zig@0.16.0 -- zig build` (repo root), then `ZIGBASE_TEST_BINARY=$PWD/zig-out/bin/zigbase mise exec python@3.13 -- python -m pytest clients/python/tests/integration -q -m integration` (from repo root; note `pytest` for the SDK otherwise runs from `clients/python/`). Expected: PASS (1 test) — this task is harness-first, not strictly TDD-red, because the failure mode being designed against is environmental.
- [ ] **Step 2: Write the remaining live tests; run; fix SDK bugs they surface (each fix gets its own unit test too).**
- [ ] **Step 3: Verify unit suite still green and integration suite passes twice in a row (flake check).**
- [ ] **Step 4: Commit** (`test(python-sdk): live-server integration suite`)

---

### Task 13: CI job + release workflow + packaging polish

**Files:**
- Modify: `.github/workflows/ci.yml` (add `python-sdk` job)
- Create: `.github/workflows/release-python-sdk.yml`, `clients/python/CHANGELOG.md`, `clients/python/RELEASING.md`
- Modify: `clients/python/README.md` (full: install, quickstart sync+async, filter builder, auth, files, pagination — model on `clients/dart/README.md`)

**`python-sdk` job** (mirror the `dart-sdk` job shape exactly):
```yaml
python-sdk:
  runs-on: ubuntu-latest
  needs: build
  steps:
    - uses: actions/checkout@v4
    - uses: jdx/mise-action@v4
    - name: Download server binaries
      uses: actions/download-artifact@v4
      with: { name: zigbase-binaries, path: bin }
    - name: Prepare binaries
      run: chmod +x bin/* && echo "ZIGBASE_TEST_BINARY=$PWD/bin/zigbase" >> "$GITHUB_ENV"
    - name: Install
      run: mise exec python@3.13 -- python -m pip install --quiet -e 'clients/python[dev]'
    - name: Lint
      run: cd clients/python && mise exec python@3.13 -- python -m ruff format --check . && mise exec python@3.13 -- python -m ruff check .
    - name: Typecheck
      run: cd clients/python && mise exec python@3.13 -- python -m mypy src
    - name: Unit tests
      run: cd clients/python && mise exec python@3.13 -- python -m pytest -q -m "not integration"
    - name: Integration tests
      run: cd clients/python && mise exec python@3.13 -- python -m pytest -q -m integration tests/integration
```
(Adjust artifact name/paths to whatever `dart-sdk` actually uses — copy from the live `ci.yml`, it is the source of truth; the binary name inside the artifact must match what that job chmods.)

**`release-python-sdk.yml`**: trigger `push` tags `python-client-v*` (distinct prefix, like `dart-client-v*`). `verify` job: install `.[dev]` + `build`, run the four gates + unit tests, assert `pyproject.toml` version == `${GITHUB_REF_NAME#python-client-v}`, `python -m build`, `twine check dist/*`. `publish` job (`needs: verify`, `environment: pypi`, `permissions: id-token: write`): `pypa/gh-action-pypi-publish@release/v1` (OIDC trusted publishing — **no token**). RELEASING.md documents: PyPI trusted publisher must be configured for repo `valthon/zigbase`, workflow `release-python-sdk.yml`, environment `pypi`; **the first publish of a brand-new PyPI package can use a "pending publisher"** registered on PyPI before the package exists — document both that route and the manual-first-upload fallback, mirroring `clients/dart/RELEASING.md`'s structure. Do NOT tag/publish in SP1.

`CHANGELOG.md`: Keep-a-Changelog with an `## [Unreleased]` section (client convention — differs from the server changelog) listing the SP1 feature set.

- [ ] **Step 1: Write both workflow changes + CHANGELOG + RELEASING + full README.**
- [ ] **Step 2: Validate workflow YAML** (`mise exec python@3.13 -- python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); yaml.safe_load(open('.github/workflows/release-python-sdk.yml'))"` — install pyyaml if needed) and re-run the four local gates + full unit suite.
- [ ] **Step 3: Commit** (`ci(python-sdk): CI job and OIDC release workflow`)

---

### Task 14: Docs + changelog fragment + site sync

**Files:**
- Create: `docs/python-sdk.md`, `site/src/content/docs/python-sdk.md` (hand-synced copy), `changelog.d/python-sdk-base.md`
- Modify: root `README.md` (add Python to the client SDK list, wherever TS/Dart are mentioned), `docs/typescript-sdk.md`/`docs/dart-sdk.md` **only if** they contain a cross-SDK list that must now include Python (check; don't invent one).

`docs/python-sdk.md`: model directly on `docs/dart-sdk.md`'s structure (install, quickstart, auth incl. auto-refresh, records CRUD, filter builder + injection safety, pagination offset+cursor+iterate, files, OAuth2/PKCE, error handling, sync vs async guidance, documented divergences from TS: no request-key dedup, `timeout=` instead of `signal`, realtime "coming in SP2"). Site mirror: copy with the site's frontmatter conventions (check an existing `site/src/content/docs/*.md` header and match it).

`changelog.d/python-sdk-base.md`:
```markdown
### Features

- Python client SDK (`clients/python`, PyPI `zigbase` 0.1.0): sync `ZigBase` and async `AsyncZigBase` clients covering auth (password, refresh, OAuth2/PKCE, sessions), records CRUD with offset + cursor pagination and an injection-safe filter builder, file URLs/tokens, and accounts/analytics/senders services. Realtime and typed codegen tiers follow.
```

- [ ] **Step 1: Write all docs; verify the site builds** (`cd site && npm install && npm run build` via `mise exec node@24 --`). Expected: build succeeds, new page present in output.
- [ ] **Step 2: Grep check**: `grep -ri "python" README.md docs/framework.md | head` to confirm no other stale "SDKs: TypeScript and Dart"-style list was missed.
- [ ] **Step 3: Run the full unit suite once more from `clients/python/`.**
- [ ] **Step 4: Commit** (`docs(python-sdk): consumer guide, site mirror, changelog fragment`)

---

## Self-review notes (already applied)

- Spec coverage: packaging/naming (T1), errors (T2), query vocabulary + filter safety (T3), auth stores (T4), multipart (T5), transports + state machines (T6/7), records + cursor (T8), auth + PKCE (T9), files/other services (T10), facades + close story (T11), e2e vs real binary (T12), CI + OIDC release lane (T13), docs/site/changelog sync (T14). Pydantic/typed tier and realtime intentionally absent (SP3/SP2).
- The `[Unreleased]` changelog section applies ONLY to `clients/python/CHANGELOG.md` (client convention); the root changelog gets a `changelog.d/` fragment and never an Unreleased section.
- Type consistency: `AuthStore`/`MemoryAuthStore`/`FileAuthStore` (T4) consumed by T6/T11; `RequestSpec`/`encode_path_segment` (T6) consumed by T8–T11; `ListResult`/`CursorPage` (T8) consumed by T10 (analytics) and docs; `AuthResponse` defined in T9, exported in T11.
