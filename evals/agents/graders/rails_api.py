"""Deterministic artifact and live-behavior grader for the Rails API migration.

The four grades answer four different questions, and each is meant to be able to fail
on its own:

* ``completion`` — did the agent produce an honest, complete migration record? Bound to
  the snapshot it was made from, every blocker decided with a rationale, and the scope
  gate answered. A Rails migration that quietly implies it moved the frontend fails
  here however good the data is.
* ``rules_locked`` — is the public surface exactly the one that was reviewed? Blank is
  Locked in ZigBase, so the risk is not omission but an unreviewed ``@public``.
* ``tests_green`` — does the boundary the agent wrote pass, and does the running target
  actually enforce the semantics the guide demands, including the denied cases?
* ``deployed`` — does a fresh target survive the rehearsal: restart with the rehashed
  credential intact, and a backup restored into a *second* target.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import stat
import string
import tempfile
from pathlib import Path
from typing import Any, Callable

from tools.rails import rails2zb

from ..result import EvalFailure
from . import GradeReport
from ._harness import (
    EVAL_ENVIRONMENT,
    canonical_executable,
    free_port,
    health_json,
    json_http_request,
    read_bounded_regular,
    regular_file_inventory,
    require_command_success,
    served_target,
    strict_json_loads,
    strict_utf8,
)
from .genesis import (
    Commands,
    DoctorReport,
    GradeFailure,
    SubprocessCommands,
    _failure,
    _wait_http,
    parse_doctor_ndjson,
    prepare_grader_scratch,
)

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SOURCE_FILE_BYTES = 16 * 1024 * 1024
MAX_SOURCE_TOTAL_BYTES = 64 * 1024 * 1024
PINNED_SOURCE = (
    Path(__file__).resolve().parents[1] / "scenarios/rails-api/fixture/source"
)


#: Every row of the frozen snapshot, including the club `default_scope` hides. A
#: migration that reads through the model loses that one and looks correct doing it.
EXPECTED_ROWS = {
    "clubs": 3,
    "comments": 3,
    "events": 3,
    "flags": 2,
    "memberships": 4,
    "notifications": 1,
    "posts": 4,
    "users": 4,
}

#: Anonymous signup, and nothing else. The recorded HTTP corpus exercises it.
EXPECTED_PUBLIC = frozenset({("users", "create")})

#: The agent's own report. Exact: an extra field is drift, a missing one is a claim
#: withheld.
REPORT_FIELDS = {
    "zigbaseRailsMigrationReport",
    "railsVersion",
    "sourceMode",
    "bundle",
    "frontend",
    "publicRules",
    "checks",
    "unresolved",
    "rollback",
}

REQUIRED_CHECKS = {
    "scope",
    "bundle",
    "determinism",
    "rules",
    "auth",
    "rehash",
    "authorization",
    "parity",
    "timestamps",
    "files",
    "restart",
    "restore",
}

#: Nothing that could carry a credential belongs in a report that gets pasted around.
#: These are the SHAPES of credential material — a whole hash, a PEM block's header —
#: never a name or a bare prefix: "bcrypt digests rehash to $argon2id on first login"
#: describes the migration and carries nothing, and the first versions of this check
#: failed it on "$argon2" (#494). The snapshot's actual digests and seed passwords are
#: matched by value below; these catch a credential of the same kind from anywhere.
#: `$zblegacy$` is `crypto.zig`'s tag, `$zblegacy$<alg>$<hash>`, and its only
#: algorithm is bcrypt, so it is listed ahead of the bcrypt shape it contains.
#:
#: A bcrypt hash is a 22-character salt and a 31-character hash. The shape takes the
#: salt and at least one hash character, so a digest cut short after its salt still
#: fails, while the format named ("$2a$04$...") or a salt alone passes. Periods alone
#: after the salt count as sentence punctuation; a suffix must contain at least one
#: other bcrypt character to count as hash content. An argon2 PHC
#: string is matched with its version optional and its parameters in any order and
#: number (`t=2,m=65536,p=1`, `p=1,keyid=AA`), but only with a salt of at least 11 and a
#: hash of at least 16 characters, so a placeholder such as "...$salt$hash" passes.
BCRYPT_HASH = r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{22}\.*[/A-Za-z0-9][./A-Za-z0-9]*"
FORBIDDEN_REPORT_SHAPES = (
    ("a $zblegacy$ password hash", re.compile(r"\$zblegacy\$bcrypt\$" + BCRYPT_HASH)),
    ("a bcrypt password hash", re.compile(BCRYPT_HASH)),
    (
        "an argon2 password hash",
        re.compile(
            r"\$argon2(?:id|i|d)(?:\$v=\d+)?\$[a-z]+=[^$,]+(?:,[a-z]+=[^$,]+)*"
            r"\$[A-Za-z0-9+/]{11,}\$[A-Za-z0-9+/]{16,}"
        ),
    ),
    ("a PEM block", re.compile(r"-----BEGIN [A-Z0-9 ]+-----")),
)

#: The secret material the snapshot hands the agent, as `config/application.rb` sets it.
#: `verify_source` has already proved `source/` is the shipped snapshot, so these are
#: its values exactly; a test pins them to the fixture's text.
#:
#: The report is checked for these VALUES, never for their names. The prompt tells the
#: agent not to claim `secret_key_base`-derived material survives, so a correct report
#: names it to deny it, and the first version of this check — a substring test on the
#: name — failed exactly that report (#494). A name says nothing a reader can use; the
#: value is the leak, and it leaks whatever the wording around it.
SOURCE_SECRET_KEY_BASE = "0" * 64
SOURCE_ENCRYPTION_KEYS = (
    "fixture_primary_key_0000000000000000",
    "fixture_deterministic_key_00000000000",
    "fixture_key_derivation_salt_000000000",
)

#: `app/services/auth_token.rb`: a user's API token is `<id>.<hex HMAC-SHA256 of
#: "bookclub-token:<id>" keyed by secret_key_base>`.
API_TOKEN_MESSAGE = "bookclub-token:{}"

#: The recorded HTTP cases that create an account or log one in. Their passwords are the
#: plaintext credentials of the snapshot's users, and each signup takes the next id.
SIGNUP_PATH = "/api/v1/users"
LOGIN_PATH = "/api/v1/sessions"

#: secret_key_base is sixty-four "0"s, the same run as a null SHA-256 digest, an all-zero
#: 32-byte value in hex, or 64 whitespace-separated zero counts. Its bytes alone cannot
#: tell those apart, so its raw form is the leak only where the report ties it to the
#: key, in one of two ways (see `_leaked_secret_key_base`):
#:
#: - assigned: the name, then only assignment or bracket punctuation and the words
#:   "is", "was", "equals" or "value", then a run of 64 or more zeros —
#:   `secret_key_base=000…`, `"secret_key_base": "000…"`, `secret_key_base => 000…`,
#:   `ENV["SECRET_KEY_BASE"]=000…`, `secret_key_base (value 000…)`,
#:   `secret_key_base is 000…`. Whatever follows the run, a reader can paste the key.
#: - nearby: within one phrase of the name, a WINDOW of 64 zeros inside a run — whole
#:   groups of zeros between separators adding up to exactly 64, with no hex digit
#:   just outside it. "000…\n0 errors" holds the key followed by a count; "0" * 128,
#:   one unbroken group, is a longer value that does not, and neither does a run that
#:   is part of a longer hex value (`f000…`, `000…a`).
#:
#: Its hex and base64 forms are long and distinctive, and are matched unconditionally.
#: A description of the value ("sixty-four zeros", Ruby's `"0" * 64`) is not its bytes
#: and is not checked: the check is for material a reader can paste, not for prose.
SECRET_KEY_BASE_NAME = re.compile(r"secret[\s_-]*key[\s_-]*base", re.IGNORECASE)
SECRET_KEY_BASE_ASSIGNED = re.compile(
    r"""[\s"'`=:>()\[\]]*(?:(?:is|was|equals|value)\b[\s"'`=:>()\[\]]*)*(?=0)""",
    re.IGNORECASE,
)
ZERO_RUN = re.compile(r"0(?:[\s:_-]*0)*")
ZERO_GROUP = re.compile(r"0+")
SECRET_KEY_BASE_NAME_WINDOW = 100

#: Separators a hex value survives being spelled with: `de:ad`, `de-ad`, `de ad`.
#: Folded needles are compared after these are removed and case is dropped.
FOLDED_SEPARATORS = re.compile(r"[\s:-]")

#: A field's strings are scanned run together as well as one by one, joined with this:
#: not a hex digit, a base64 character or a zero, so the join itself never completes a
#: value — "secret_key_base" + "000…" must not read as the hex run "e000…" — and it is
#: a folded separator, so a hex value split across two strings is still one value.
FIELD_JOIN = "\n"

#: A claim that the frontend moved, and the negations that contain one verbatim.
#: Substring matching alone inverts meaning: "no frontend is migrated" is an honest
#: denial that CONTAINS "frontend is migrated", and the first version of this grader
#: rejected it as the very claim it was denying. Each claim is only a claim when no
#: negation immediately precedes it.
FRONTEND_CLAIMS = (
    "views were migrated",
    "views are migrated",
    "frontend was migrated",
    "frontend is migrated",
    "migrated the frontend",
    "migrated the views",
)

#: Words that turn a claim into its denial when they appear shortly before it. A
#: negation is not always adjacent — "no Rails frontend is migrated" puts a word in
#: between — so the few preceding words are searched rather than just the last one.
CLAIM_NEGATIONS = frozenset({"no", "not", "never", "nothing", "none", "neither"})
NEGATION_WINDOW = 4

#: Any of these says the frontend did not move. Requiring one exact phrase would fail
#: correct reports on wording, which measures the agent's phrasing rather than its work.
FRONTEND_DENIALS = (
    "not migrated",
    "never migrated",
    "were not ported",
    "not ported",
    "no frontend",
    "nothing was migrated from",
    "no rails frontend",
    "no presentation",
)

#: The rehearsal runs offline against a disposable target. A fixed secret keeps the
#: rehash-survives-restart check meaningful: a fresh one each boot would invalidate
#: every token and mask a credential that did not actually migrate.

LOGIN_EMAIL = "ada@example.test"
LOGIN_PASSWORD = "ada-password-1"

#: A second migrated user, who owns none of ada's rows. Owner-scoping is only
#: observable from an actor with nothing to see.
OTHER_EMAIL = "brian@example.test"
OTHER_PASSWORD = "brian-password-2"

#: `clubs.id=1` as the source recorded it (db/seeds.rb). Compared literally: a
#: `startswith("20")` check matched ZigBase's own write-time value and so could not
#: fail until the next century.
SEEDED_CLUB_CREATED = "2024-01-15T10:00:00Z"

#: The one Active Storage attachment in the snapshot, at the path the file route serves
#: it from once `install-files` has placed it.
MIGRATED_FILE_PATH = "/api/files/posts/1/morning-pages-cover.png"


def _json(path: Path, label: str) -> Any:
    try:
        raw = read_bounded_regular(path, MAX_JSON_BYTES)
        return strict_json_loads(strict_utf8(raw, str(path)))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            f"completion.{label}_unreadable", f"{label} is unreadable: {exc}"
        ) from exc


def _source_files(root: Path) -> dict[Path, tuple[Path, int]]:
    try:
        return regular_file_inventory(
            root,
            ignored=lambda relative: (
                "__pycache__" in relative.parts
                or relative.suffix in {".pyc", ".pyo"}
                or relative.name.endswith(("-wal", "-shm"))
            ),
            maximum_file=MAX_SOURCE_FILE_BYTES,
            maximum_total=MAX_SOURCE_TOTAL_BYTES,
        )
    except ValueError as exc:
        raise GradeFailure("source.changed", f"source snapshot changed: {exc}") from exc
    except OSError as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot inspect source: {exc}"
        ) from exc


def _verify_frozen_source(source: Path) -> None:
    expected = _source_files(PINNED_SOURCE)
    actual = _source_files(source)
    if set(expected) != set(actual) or any(
        actual[relative][1] != expected_size
        for relative, (_, expected_size) in expected.items()
    ):
        raise GradeFailure("source.changed", "source snapshot differs from the fixture")
    try:
        for relative, (expected_path, _) in expected.items():
            if read_bounded_regular(
                expected_path, MAX_SOURCE_FILE_BYTES
            ) != read_bounded_regular(actual[relative][0], MAX_SOURCE_FILE_BYTES):
                raise GradeFailure(
                    "source.changed", f"source artifact changed: {relative}"
                )
    except GradeFailure:
        raise
    except (OSError, ValueError) as exc:
        raise GradeFailure("source.unreadable", f"cannot read source: {exc}") from exc


def verify_source(source: Path) -> dict[str, Any]:
    """The snapshot must be exactly the one shipped, and still observed.

    The prompt says to leave `source/` byte-for-byte unchanged. An agent that edited the
    inventory to make a blocker disappear would otherwise grade as a clean migration.
    """
    freeze = _json(source / "freeze.json", "freeze")
    if freeze.get("rails_version") != "8.1.3.1":
        raise GradeFailure(
            "source.wrong_revision",
            f"the snapshot reports Rails {freeze.get('rails_version')!r}, not 8.1.3.1",
        )
    _verify_frozen_source(source)
    loaded = rails2zb.load_source(source)
    rails2zb.require_sqlite(loaded)
    if loaded.mode != "observed":
        raise GradeFailure(
            "source.not_observed",
            f"the inventory is {loaded.mode!r}; an inferred one may not be reported as observed",
        )
    return {"inventory_sha256": rails2zb._inventory_digest(loaded), "mode": loaded.mode}


def _schema_public_rules(schema: Any) -> frozenset[tuple[str, str]]:
    """(collection, action) for every rule the emitted schema leaves open to anyone."""
    collections = schema.get("collections") if isinstance(schema, dict) else None
    if not isinstance(collections, list):
        raise GradeFailure(
            "completion.schema_shape", "schema.json has no collections array"
        )
    return frozenset(
        (collection["name"], key[: -len("Rule")])
        for collection in collections
        for key, value in collection.items()
        if key.endswith("Rule") and value == rails2zb.PUBLIC_RULE
    )


def load_reviewed_public_inventory(path: Path) -> frozenset[tuple[str, str]]:
    """`security/public-rules.json` — the compact reviewed contract, exactly."""
    value = _json(path, "public_rules")
    if not isinstance(value, dict) or set(value) != {"zigbasePublicRules", "rules"}:
        raise GradeFailure(
            "rules.inventory_shape",
            "public-rules.json must carry exactly zigbasePublicRules and rules",
        )
    if value["zigbasePublicRules"] != 1:
        raise GradeFailure(
            "rules.inventory_version", "unsupported public-rules version"
        )
    rules = value["rules"]
    if not isinstance(rules, list) or not all(isinstance(name, str) for name in rules):
        raise GradeFailure("rules.inventory_shape", "rules must be an array of strings")
    parsed = set()
    for name in rules:
        collection, _, action = name.partition(".")
        if not collection or not action:
            raise GradeFailure(
                "rules.inventory_shape", f"{name!r} is not `collection.action`"
            )
        parsed.add((collection, action))
    return frozenset(parsed)


def _validate_report(workspace: Path) -> dict[str, Any]:
    report = _json(workspace / "migration" / "report.json", "report")
    if not isinstance(report, dict):
        raise GradeFailure("completion.report_shape", "report.json must be an object")
    if set(report) != REPORT_FIELDS:
        missing = sorted(REPORT_FIELDS - set(report))
        extra = sorted(set(report) - REPORT_FIELDS)
        raise GradeFailure(
            "completion.report_fields",
            f"report field drift — missing={missing} extra={extra}",
        )
    if report["zigbaseRailsMigrationReport"] != 1:
        raise GradeFailure("completion.report_version", "unsupported report version")
    if report["sourceMode"] != "observed":
        raise GradeFailure(
            "completion.report_inferred",
            "an inferred inventory may not be reported as observed",
        )
    if report["unresolved"]:
        raise GradeFailure(
            "completion.unresolved",
            f"the migration reports unresolved work: {report['unresolved']}",
        )
    missing_checks = REQUIRED_CHECKS - set(report["checks"])
    if missing_checks:
        raise GradeFailure(
            "completion.checks", f"checks omitted: {sorted(missing_checks)}"
        )
    if report["bundle"] != "migration/bundle":
        raise GradeFailure(
            "completion.report_bundle",
            f"the report points at {report['bundle']!r}; the bundle this grader read is "
            f"migration/bundle, so the report describes something else",
        )
    if not str(report["rollback"]).strip():
        raise GradeFailure("completion.rollback", "the rollback unit is not described")

    frontend = str(report["frontend"])
    if not frontend.strip():
        raise GradeFailure(
            "completion.scope_gate",
            "the report does not state what happened to the Rails frontend",
        )
    lowered = " ".join(frontend.lower().split())
    for claim in FRONTEND_CLAIMS:
        index = lowered.find(claim)
        while index != -1:
            preceding = lowered[:index].split()[-NEGATION_WINDOW:]
            if not CLAIM_NEGATIONS.intersection(preceding):
                raise GradeFailure(
                    "completion.scope_gate",
                    f"the report claims Rails views or frontend behavior were "
                    f"migrated: {claim!r}",
                )
            index = lowered.find(claim, index + 1)
    if not any(denial in lowered for denial in FRONTEND_DENIALS):
        raise GradeFailure(
            "completion.scope_gate",
            "the report must say plainly that the Rails frontend did not migrate",
        )

    texts = _report_texts(report)
    for text in texts:
        for label, shape in FORBIDDEN_REPORT_SHAPES:
            if shape.search(text):
                raise GradeFailure(
                    "completion.report_secret", f"the report carries {label}"
                )
    needles = _source_secret_needles(workspace / "source")
    for text in texts:
        leaked = _leaked_secret(text, needles)
        if leaked is not None:
            raise GradeFailure("completion.report_secret", f"the report carries {leaked}")
    return report


def _fold(text: str) -> str:
    return FOLDED_SEPARATORS.sub("", text.lower())


def _leaked_secret(text: str, needles: list[tuple[str, str, str]]) -> str | None:
    """The label of the first secret value `text` carries, or None."""
    candidates = {
        "folded": (_fold(text),),
        # A password is a phrase: matched whole, in any case, but never with its
        # separators folded away — "ada: password 1 of 4" is not "ada-password-1".
        "lower": (text.lower(),),
        # Base64 is case-sensitive and may be wrapped across lines.
        "exact": (text, "".join(text.split())),
    }
    for label, needle, mode in needles:
        if any(needle in candidate for candidate in candidates[mode]):
            return label
    if _leaked_secret_key_base(text):
        return "secret_key_base"
    return None


def _leaked_secret_key_base(text: str) -> bool:
    """Whether `text` ties a run of zeros to secret_key_base's name (see `ZERO_RUN`)."""
    length = len(SOURCE_SECRET_KEY_BASE)
    names = [match.span() for match in SECRET_KEY_BASE_NAME.finditer(text)]
    for _, name_end in names:
        assigned = SECRET_KEY_BASE_ASSIGNED.match(text, name_end)
        if assigned is not None:
            run = ZERO_RUN.match(text, assigned.end())
            if run is not None and run.group().count("0") >= length:
                return True
    if not names:
        return False
    for run in ZERO_RUN.finditer(text):
        groups = [group.span() for group in ZERO_GROUP.finditer(text, *run.span())]
        for first in range(len(groups)):
            zeros = 0
            for last in range(first, len(groups)):
                zeros += groups[last][1] - groups[last][0]
                if zeros >= length:
                    break
            if zeros != length:
                continue
            start, end = groups[first][0], groups[last][1]
            if (start > 0 and text[start - 1] in string.hexdigits) or (
                end < len(text) and text[end] in string.hexdigits
            ):
                continue
            if any(
                max(start - name_end, name_start - end) <= SECRET_KEY_BASE_NAME_WINDOW
                for name_start, name_end in names
            ):
                return True
    return False


def _base64_needles(raw: bytes) -> set[str]:
    """Every base64 run that encodes `raw` wherever it sits in a longer byte string.

    A value base64'd inside something bigger (`secret_key_base=…`, `1.<hex>`) lands at
    one of three alignments. At each, the characters whose six bits all come from `raw`
    are the same whatever surrounds it; those, in the standard and URL-safe alphabets,
    are the needles. Unpadded by construction: padding is not part of the value.
    """
    found = set()
    for offset in range(3):
        encoded = base64.b64encode(bytes(offset) + raw + bytes(2)).decode()
        first = -(-offset * 8 // 6)  # the first character starting at or after raw
        last = (offset + len(raw)) * 8 // 6  # one past the last one ending inside it
        core = encoded[first:last]
        found.add(core)
        found.add(core.translate(str.maketrans("+/", "-_")))
    return found


def _source_secret_needles(source: Path) -> list[tuple[str, str, str]]:
    """(label, needle, mode) for every secret value the snapshot holds.

    A "folded" needle (a hex value, a key, a digest) is compared case- and
    separator-insensitively (see `_fold`); a "lower" one (a password) whole and
    case-insensitively; an "exact" one (base64) exactly. Every value is searched raw,
    as hex of its bytes and as base64 at every alignment — except secret_key_base's raw
    form, whose 64 zeros `_leaked_secret_key_base` matches only where the report ties
    them to its name.

    The values are secret_key_base and the three Active Record encryption keys as
    `application.rb` sets them; each user's API-token signature, derived as
    `auth_token.rb` derives it, for every user the snapshot holds AND every user its
    recorded HTTP cases sign up (their ids continue the users sequence); each stored
    bcrypt digest, its hash part and its salt with the hash's start; and the
    plaintext password of every recorded successful signup and login. Only the token's signature is searched, since the id
    half is not secret; its hex text's base64 also covers base64 of the whole token.
    """
    users, signups, passwords = _source_accounts(source)
    # (label, bytes, how the bytes are matched as text a report could quote, or None)
    values: list[tuple[str, bytes, str | None]] = [
        ("secret_key_base", SOURCE_SECRET_KEY_BASE.encode(), None)
    ]
    values += [
        ("an Active Record encryption key", key.encode(), "folded")
        for key in SOURCE_ENCRYPTION_KEYS
    ]
    for user_id in [user_id for user_id, _ in users] + list(
        range(signups[0] + 1, signups[0] + 1 + signups[1])
    ):
        signature = hmac.new(
            SOURCE_SECRET_KEY_BASE.encode(),
            API_TOKEN_MESSAGE.format(user_id).encode(),
            hashlib.sha256,
        ).digest()
        label = f"user {user_id}'s secret_key_base-derived API token"
        values.append((label, signature, None))
        values.append((f"{label} (hex text)", signature.hex().encode(), "folded"))
    for user_id, digest in users:
        label = f"user {user_id}'s password digest"
        values.append((label, digest.encode(), "folded"))
        # The 31-character hash after "$2a$04$" and the 22-character salt, and the
        # salt with the hash's first 8 characters: a digest cut short, without its
        # "$2a$04$" (with it, `BCRYPT_HASH` already refuses the cut digest).
        values.append((f"{label} (hash part)", digest[29:].encode(), "folded"))
        values.append((f"{label} (salt and hash start)", digest[7:37].encode(), "folded"))
    values += [
        ("a seed account's plaintext password", password.encode(), "lower")
        for password in passwords
    ]

    needles: dict[tuple[str, str], str] = {}
    for label, raw, text_mode in values:
        if text_mode == "lower":
            needles.setdefault((raw.decode().lower(), "lower"), label)
        elif text_mode == "folded":
            needles.setdefault((_fold(raw.decode()), "folded"), label)
        needles.setdefault((raw.hex(), "folded"), f"{label} (hex)")
        for encoded in sorted(_base64_needles(raw)):
            needles.setdefault((encoded, "exact"), f"{label} (base64)")
    return [(label, needle, mode) for (needle, mode), label in needles.items()]


def _source_accounts(
    source: Path,
) -> tuple[list[tuple[int, str]], tuple[int, int], list[str]]:
    """The snapshot's credentials: (users, (sequence, signups), passwords).

    `users` is (id, password_digest) for every row of the frozen database, opened
    `immutable=1` so SQLite creates no `-shm`/`-wal` sidecars: grading must leave
    `source/` byte-for-byte unchanged, as the prompt asks of the agent. `sequence` is
    the users table's last assigned id and `signups` the number of accounts the
    recorded HTTP cases create after it. `passwords` are the plaintext passwords of the
    recorded signups and logins that succeeded — a failed one's password ("wrong") is
    nobody's credential.
    """
    database = (source / "db" / "development.sqlite3").resolve()
    try:
        connection = sqlite3.connect(f"{database.as_uri()}?immutable=1", uri=True)
        try:
            users = [
                (int(user_id), str(digest))
                for user_id, digest in connection.execute(
                    "SELECT id, password_digest FROM users ORDER BY id"
                ).fetchall()
            ]
            sequence = connection.execute(
                "SELECT seq FROM sqlite_sequence WHERE name = 'users'"
            ).fetchone()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot read the snapshot's users: {exc}"
        ) from exc
    last = int(sequence[0]) if sequence else max((u for u, _ in users), default=0)

    path = source / "http" / "cases.json"
    try:
        cases = strict_json_loads(
            strict_utf8(read_bounded_regular(path, MAX_JSON_BYTES), str(path))
        )["cases"]
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot read the snapshot's HTTP cases: {exc}"
        ) from exc
    signups = 0
    passwords: list[str] = []
    for case in cases:
        if (
            not isinstance(case, dict)
            or case.get("method") != "POST"
            or case.get("path") not in (SIGNUP_PATH, LOGIN_PATH)
            or not 200 <= (case.get("expect") or {}).get("status", 0) < 300
        ):
            continue
        signups += case["path"] == SIGNUP_PATH
        body = case.get("body") or {}
        password = (body.get("user") or body).get("password")
        if isinstance(password, str) and password not in passwords:
            passwords.append(password)
    return users, (last, signups), passwords


def _report_texts(report: dict[str, Any]) -> list[str]:
    """Every string in the report, plus each field's strings joined by `FIELD_JOIN`.

    Keys are included, so no field escapes the scan; a hex or base64 value split across
    two strings of one field ("1.b44d", "c560…") is still the value.
    """
    texts = []
    for key, item in report.items():
        strings = _report_strings(key) + _report_strings(item)
        texts += strings
        if len(strings) > 2:
            texts.append(FIELD_JOIN.join(strings[1:]))
    return texts


def _report_strings(value: Any) -> list[str]:
    """Every string in `value`, dict keys included."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [
            text
            for key, item in value.items()
            for text in (*_report_strings(key), *_report_strings(item))
        ]
    if isinstance(value, list):
        return [s for item in value for s in _report_strings(item)]
    return []


def _verify_determinism(workspace: Path, source: Path) -> None:
    """Re-extract and compare, rather than believe the report.

    The prompt demands a bundle that is byte-identical across two separate runs and the
    report must list a `determinism` check — but a check nobody performs is a claim, and
    this grader was accepting the word for the deed. Extraction is offline and cheap, so
    the honest thing is to do it again.

    It extracts from a scratch copy: reading the WAL-mode snapshot in place leaves
    `-wal`/`-shm` sidecars in `source/`, which the prompt says to leave byte-for-byte
    unchanged and which the agent's own boundary test, run last, may check (#494). The
    checks that guard `source/` itself have already run against the original.
    """
    decisions = rails2zb.load_decisions(workspace / "decisions.json")
    with tempfile.TemporaryDirectory(dir=workspace) as scratch:
        copy = Path(scratch) / "source"
        shutil.copytree(source, copy, symlinks=True)
        loaded = rails2zb.load_source(copy)
        second = Path(scratch) / "bundle"
        try:
            rails2zb.extract(loaded, decisions, second)
        except rails2zb.RailsError as exc:
            raise GradeFailure(
                "completion.not_reproducible",
                f"the bundle could not be produced again from the same inputs: {exc}",
            ) from exc
        recorded = _json(workspace / "migration" / "bundle" / "hashes.json", "hashes")[
            "outputs"
        ]
        repeated = _json(second / "hashes.json", "hashes")["outputs"]
        if {e["path"]: e["sha256"] for e in recorded} != {
            e["path"]: e["sha256"] for e in repeated
        }:
            raise GradeFailure(
                "completion.nondeterministic",
                "a second extraction from the same source and decisions produced "
                "different bytes",
            )


def _verify_decisions(workspace: Path, source: Path) -> None:
    """Every blocker decided, with a rationale, against THIS snapshot's findings."""
    decisions = rails2zb.load_decisions(workspace / "decisions.json")
    findings = rails2zb.build_findings(rails2zb.load_source(source))
    try:
        rails2zb.reconcile(findings, decisions, artifact_root=workspace)
    except rails2zb.RailsError as exc:
        raise GradeFailure(
            "completion.decisions", f"decisions do not reconcile: {exc}"
        ) from exc
    thin = sorted(
        fid
        for fid, decision in decisions.items()
        if len(decision.rationale.strip()) < 12
    )
    if thin:
        raise GradeFailure(
            "completion.rationales",
            f"these decisions carry no usable rationale: {thin[:5]}",
        )


def _verify_bundle(
    workspace: Path, source: Path, expected_inventory: str
) -> dict[str, Any]:
    bundle = workspace / "migration" / "bundle"
    emitted = _json(bundle / "report.json", "bundle_report")
    if emitted.get("inventorySha256") != expected_inventory:
        raise GradeFailure(
            "completion.bundle_unbound",
            "the bundle was not built from this snapshot's inventory",
        )
    hashes = _json(bundle / "hashes.json", "hashes")
    if (
        not isinstance(hashes, dict)
        or set(hashes) != {"zigbaseRailsHashes", "outputs"}
        or hashes["zigbaseRailsHashes"] != 1
        or not isinstance(hashes["outputs"], list)
    ):
        raise GradeFailure(
            "completion.bundle_unattested", "hashes.json has an invalid envelope"
        )
    recorded: dict[str, tuple[int, str]] = {}
    for index, entry in enumerate(hashes["outputs"]):
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json output {index} has an invalid shape",
            )
        relative, size, digest = entry["path"], entry["bytes"], entry["sha256"]
        relative_path = Path(relative) if isinstance(relative, str) else Path()
        if (
            not isinstance(relative, str)
            or not relative
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or "\\" in relative
            or "\x00" in relative
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size < 0
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json output {index} has invalid values",
            )
        if relative in recorded:
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json repeats output path {relative!r}",
            )
        recorded[relative] = (size, digest)
    on_disk: dict[str, tuple[Path, int]] = {}
    total = 0
    try:
        for path in bundle.rglob("*"):
            relative = path.relative_to(bundle).as_posix()
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not (
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
            ):
                raise GradeFailure(
                    "completion.bundle_unsafe", f"unsafe bundle artifact: {relative}"
                )
            if stat.S_ISDIR(metadata.st_mode) or path.name == "hashes.json":
                continue
            if metadata.st_size > MAX_SOURCE_FILE_BYTES:
                raise GradeFailure(
                    "completion.bundle_unsafe", f"oversized bundle artifact: {relative}"
                )
            total += metadata.st_size
            if total > MAX_SOURCE_TOTAL_BYTES:
                raise GradeFailure(
                    "completion.bundle_unsafe", "migration bundle is oversized"
                )
            on_disk[relative] = (path, metadata.st_size)
    except OSError as exc:
        raise GradeFailure(
            "completion.bundle_unsafe", f"cannot inspect migration bundle: {exc}"
        ) from exc
    if set(recorded) != set(on_disk):
        raise GradeFailure(
            "completion.bundle_unattested",
            "hashes.json does not cover exactly the bundle's outputs",
        )
    for relative, (recorded_size, digest) in recorded.items():
        if on_disk[relative][1] != recorded_size:
            raise GradeFailure(
                "completion.bundle_corrupt",
                f"{relative} does not match its recorded size",
            )
        try:
            payload = read_bounded_regular(on_disk[relative][0], MAX_SOURCE_FILE_BYTES)
        except (OSError, ValueError) as exc:
            raise GradeFailure(
                "completion.bundle_unsafe",
                f"cannot safely read bundle artifact {relative}: {exc}",
            ) from exc
        if hashlib.sha256(payload).hexdigest() != digest:
            raise GradeFailure(
                "completion.bundle_corrupt",
                f"{relative} does not match its recorded hash",
            )
    counts = {entry["collection"]: entry["rows"] for entry in emitted["collections"]}
    if counts != EXPECTED_ROWS:
        raise GradeFailure(
            "completion.rows",
            f"row counts do not match the snapshot: {counts} != {EXPECTED_ROWS}",
        )
    return emitted


def inspect_completion(
    workspace: Path,
) -> tuple[dict[str, Any] | None, list[EvalFailure]]:
    """Everything gradeable without a running target."""
    failures: list[EvalFailure] = []
    try:
        source = workspace / "source"
        verified = verify_source(source)
        report = _validate_report(workspace)
        _verify_decisions(workspace, source)
        emitted = _verify_bundle(workspace, source, verified["inventory_sha256"])
        _verify_determinism(workspace, source)

        if report["railsVersion"] != emitted["railsVersion"]:
            raise GradeFailure(
                "completion.version_mismatch",
                "the report and the bundle disagree about the Rails version",
            )

        return report, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("completion.error", f"{type(exc).__name__}: {exc}"))
    return None, failures


def inspect_rules(workspace: Path, report: dict[str, Any] | None) -> list[EvalFailure]:
    """Whether the public surface is the reviewed one — on its own.

    Split out of `inspect_completion` deliberately. These raise `rules.*`, and
    `completion` is false whenever a `rules.*` failure appears, so leaving them inside
    the completion pass meant a purely authorization defect also sank an otherwise
    honest and complete migration record. Two grades moving for one fault tells the
    reader less than either grade alone.
    """
    failures: list[EvalFailure] = []
    try:
        schema = _json(workspace / "migration" / "bundle" / "schema.json", "schema")
        public = _schema_public_rules(schema)
        reviewed = load_reviewed_public_inventory(
            workspace / "security" / "public-rules.json"
        )
        if public != reviewed:
            raise GradeFailure(
                "rules.unreviewed_public",
                f"the schema grants {sorted(public)} but {sorted(reviewed)} was reviewed",
            )
        if public != EXPECTED_PUBLIC:
            raise GradeFailure(
                "rules.unexpected_public",
                f"the public surface is {sorted(public)}, not {sorted(EXPECTED_PUBLIC)}",
            )
        if report is not None and set(report["publicRules"]) != {
            f"{c}.{a}" for c, a in reviewed
        }:
            raise GradeFailure(
                "rules.report_drift",
                "the report's publicRules and the reviewed inventory disagree",
            )
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("rules.error", f"{type(exc).__name__}: {exc}"))
    return failures


def _binary(binary_path: str | None = None) -> str:
    candidate = binary_path or os.environ.get("ZIGBASE_EVAL_BINARY")
    if not candidate:
        raise GradeFailure(
            "rehearsal.binary_missing",
            "ZIGBASE_EVAL_BINARY is not set; the rehearsal needs the pinned binary",
        )
    resolved = canonical_executable(candidate)
    if resolved is None:
        raise GradeFailure(
            "rehearsal.binary_missing", f"no regular executable binary at {candidate}"
        )
    return str(resolved)


def _request(
    method: str, url: str, *, token: str | None = None, body: Any = None
) -> tuple[int, bytes]:
    status, payload, _ = json_http_request(method, url, token=token, body=body)
    return status, payload


def _response_json(payload: bytes, code: str) -> dict[str, Any]:
    try:
        value = strict_json_loads(strict_utf8(payload, f"{code} response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(code, "target returned malformed JSON") from exc
    if not isinstance(value, dict):
        raise GradeFailure(code, "target response is not a JSON object")
    return value


def _run_ok(result: Any, code: str, what: str) -> None:
    require_command_success(result, code, what, GradeFailure)


def _check_rehearsal_start(result: Any) -> None:
    _run_ok(result, "rehearsal.serve", "starting the rehearsal server")


def _rehearsal_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "tests.teardown",
            f"the rehearsal server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure(
            "tests.teardown",
            "the rehearsal server did not stop; a later run would find the data dir "
            "owned by an orphan",
        )
    )


def _check_deployment_start(result: Any) -> None:
    _run_ok(result, "deployment.serve", "starting a server on the restored copy")


def _deployment_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "deployment.teardown",
            f"the restored server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure("deployment.teardown", "the restored server did not stop")
    )


def probe_behavior(
    base: str, *, http_request: Callable[..., tuple[int, bytes]] = _request
) -> None:
    """The semantics the guide demands, against a running target.

    Verified against the real server rather than assumed, because the first version of
    this function asserted the wrong thing: it expected `401` for an unauthenticated
    list. ZigBase does not answer `401` there — an access rule that hides every row is
    not an authentication failure, so the list succeeds and is EMPTY. That is precisely
    the semantic the guide tells the operator not to "fix", and encoding it backwards
    here would have failed every correct migration.
    """
    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": LOGIN_EMAIL, "password": LOGIN_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "parity.legacy_login",
            f"the migrated bcrypt credential did not log in ({status})",
        )
    token = _response_json(payload, "parity.legacy_login").get("token")
    if not token:
        raise GradeFailure("parity.legacy_login", "login returned no token")

    # A rule that hides every row: 200 and an empty array, never 401 or 403.
    status, payload = http_request("GET", f"{base}/api/collections/posts/records")
    if status != 200:
        raise GradeFailure(
            "parity.empty_list",
            f"an unauthenticated list returned {status}; a rule hiding every row "
            f"answers 200 with an empty array",
        )
    if _response_json(payload, "parity.empty_list").get("items") != []:
        raise GradeFailure("parity.empty_list", "an unauthenticated list leaked rows")

    # A single record the caller may not see is CONCEALED, not announced.
    status, _ = http_request("GET", f"{base}/api/collections/posts/records/1")
    if status != 404:
        raise GradeFailure(
            "parity.concealment",
            f"a record the caller may not see returned {status}; it must be 404",
        )

    # Owner-scoping, from BOTH sides. Asserting only that the owner sees their row is
    # satisfied by a rule that scopes nothing — every row in this collection belongs to
    # the login user — so the load-bearing half is the second actor seeing none.
    status, payload = http_request(
        "GET", f"{base}/api/collections/notifications/records", token=token
    )
    if status != 200:
        raise GradeFailure(
            "parity.owner_scope", f"an owner-scoped list returned {status}, not 200"
        )
    if (
        len(_response_json(payload, "parity.owner_scope").get("items") or [])
        != EXPECTED_ROWS["notifications"]
    ):
        raise GradeFailure(
            "parity.owner_scope", "the owner cannot see their own notification"
        )

    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": OTHER_EMAIL, "password": OTHER_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "parity.legacy_login",
            f"the second migrated credential did not log in ({status})",
        )
    other = _response_json(payload, "parity.legacy_login").get("token")
    status, payload = http_request(
        "GET", f"{base}/api/collections/notifications/records", token=other
    )
    if status != 200 or (
        _response_json(payload, "parity.owner_scope").get("items") or []
    ):
        raise GradeFailure(
            "parity.owner_scope",
            "a second actor can see notifications belonging to someone else",
        )

    # An Active Storage blob the install placed, fetched over the file route. The
    # installer's return value was discarded and no probe touched a blob, so `files`
    # was a claim: an empty manifest installs zero files and reports success.
    status, payload = http_request("GET", f"{base}{MIGRATED_FILE_PATH}", token=token)
    if status != 200 or not payload:
        raise GradeFailure(
            "parity.files",
            f"the migrated attachment did not serve from {MIGRATED_FILE_PATH} ({status})",
        )
    # And the file route is rule-scoped like the record it hangs off: the owning post is
    # visible only to an authenticated caller, so an anonymous fetch is concealed rather
    # than served. Installing the bytes is not the same as protecting them.
    status, _ = http_request("GET", f"{base}{MIGRATED_FILE_PATH}")
    if status != 404:
        raise GradeFailure(
            "parity.files",
            f"an anonymous fetch of a migrated attachment returned {status}; the file "
            f"route must conceal it as 404 like the record it belongs to",
        )

    # Public signup exists, and still validates.
    status, _ = http_request(
        "POST",
        f"{base}/api/collections/users/records",
        body={"email": "not-an-email"},
    )
    if status not in (400, 422):
        raise GradeFailure(
            "parity.validation",
            f"an invalid signup returned {status}, not a validation failure",
        )


def _inspect_database(data_dir: Path) -> None:
    """Timestamps and the rehash, read from the target rather than from a summary."""
    database = data_dir / "data.db"
    if not database.is_file():
        raise GradeFailure("rehearsal.no_database", f"no target database at {database}")
    connection = sqlite3.connect(database)
    try:
        digest = connection.execute(
            "SELECT passwordHash FROM users WHERE email = ?", (LOGIN_EMAIL,)
        ).fetchone()
        if not digest:
            raise GradeFailure(
                "rehearsal.missing_user", f"{LOGIN_EMAIL} did not migrate"
            )
        if not str(digest[0]).startswith("$argon2"):
            raise GradeFailure(
                "rehearsal.no_rehash",
                "the legacy bcrypt digest was not rehashed to argon2id on login",
            )
        # Counts from the target's own tables, not from a rule-scoped list: `flags` and
        # `notifications` are owner-scoped, so an HTTP count measures what one actor may
        # see and would read 1 of 2 flags as a missing row. The guide says to verify
        # counts directly rather than trust a summary; this is that.
        for collection, expected in sorted(EXPECTED_ROWS.items()):
            actual = connection.execute(
                f'SELECT COUNT(*) FROM "{collection}"'  # noqa: S608 - fixed names
            ).fetchone()[0]
            if actual != expected:
                raise GradeFailure(
                    "rehearsal.target_rows",
                    f"{collection} holds {actual} rows on the target, not {expected}",
                )

        created = connection.execute(
            "SELECT created FROM clubs WHERE id = '1'"
        ).fetchone()
        if not created or str(created[0]) != SEEDED_CLUB_CREATED:
            raise GradeFailure(
                "rehearsal.timestamps",
                f"clubs.1 was imported with created={created and created[0]!r}, not the "
                f"source's {SEEDED_CLUB_CREATED!r}; --preserve-timestamps did not apply",
            )
    finally:
        connection.close()


def run_rehearsal(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    *,
    port_picker: Callable[[], int] = free_port,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[..., dict[str, int]] = rails2zb.install_files,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
) -> tuple[bool, DoctorReport | None, list[EvalFailure]]:
    failures: list[EvalFailure] = []
    doctor: DoctorReport | None = None
    try:
        binary = _binary(binary_path)
        bundle = workspace / "migration" / "bundle"
        target = workspace / ".rehearsal" / "data"
        target.mkdir(parents=True, exist_ok=True)
        # `_grader_environment` points HOME and TMPDIR at these, and the runner creates
        # them when it stages a workspace — but a grader pointed at an existing
        # workspace has no runner behind it, and facil.io needs a real TMPDIR to open
        # its cluster socket. Without them `serve` dies with a FATAL nobody would trace
        # back to a missing directory.
        prepare_grader_scratch(workspace)
        env = dict(EVAL_ENVIRONMENT)

        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    "--data-dir",
                    str(target),
                    "--dry-run",
                    str(bundle / "schema.json"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.schema_dry_run",
            "the schema dry run",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    "--data-dir",
                    str(target),
                    str(bundle / "schema.json"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.schema_apply",
            "applying the schema",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--data-dir",
                    str(target),
                    "--collection",
                    "users",
                    "--legacy-hashes",
                    "bcrypt",
                    "--preserve-timestamps",
                    str(bundle / "auth" / "users.ndjson"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.auth_import",
            "importing auth",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--data-dir",
                    str(target),
                    "--manifest",
                    str(bundle / "manifest.json"),
                    "--preserve-timestamps",
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.data_import",
            "importing ordinary data",
        )
        # `install_files(bundle, source_root, data_dir)`: the blobs are read from the
        # frozen snapshot and placed under the target's own storage layout.
        file_installer(bundle, workspace / "source", target)

        doctor_result = commands.run(
            [binary, "doctor", "--data-dir", str(target), "--production", "--json"],
            cwd=workspace,
            env=env,
        )
        # `doctor` exits non-zero when it finds errors, which is a finding rather than a
        # crash — but truncated output silently loses the summary line and surfaces as a
        # malformed-NDJSON failure that reads like the target's fault.
        if doctor_result.output_truncated:
            raise GradeFailure(
                "rules.doctor_truncated",
                "doctor output was truncated, so its summary cannot be trusted",
            )
        doctor = parse_doctor_ndjson(doctor_result.stdout)

        with served_target(
            commands,
            binary,
            workspace,
            target,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_rehearsal_start,
            _rehearsal_teardown_failure,
            health_attempts=health_attempts,
        ) as base:
            # `--background` rather than a Popen: `serve` DETACHES on its own inside any
            # AI-agent environment (src/serve_control.zig sniffs CLAUDECODE and friends),
            # so a foreground child forks and exits and `terminate()` kills a corpse --
            # leaving a live server holding the port and the data dir, and letting the
            # restore copy a database out from under a running writer. Going through
            # `commands.run` also keeps the server on the same allowlisted environment
            # every other command gets, so `doctor` judges the configuration that is
            # actually serving.
            behavior_probe(base)
            database_inspector(target)
        return True, doctor, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("rehearsal.error", f"{type(exc).__name__}: {exc}"))
    return False, doctor, failures


def run_agent_boundary(
    workspace: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
) -> tuple[bool, list[EvalFailure]]:
    """Run mutable agent-authored code only after every trusted live probe is done."""
    failures: list[EvalFailure] = []
    try:
        binary = _binary(binary_path)
        result = commands.run(
            [
                "python3",
                "-m",
                "unittest",
                "discover",
                "-s",
                "tests",
                "-p",
                "test_migration.py",
            ],
            cwd=workspace,
            env={**EVAL_ENVIRONMENT, "ZIGBASE_BINARY": binary},
        )
        _run_ok(result, "tests.boundary_failed", "the agent's migration boundary")
        return True, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, TypeError, ValueError) as exc:
        failures.append(
            _failure("tests.boundary_error", f"{type(exc).__name__}: {exc}")
        )
    return False, failures


def run_restore(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = free_port,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
    restore_probe: Callable[..., None] = None,  # type: ignore[assignment]
    database_inspector: Callable[..., None] = _inspect_database,
) -> tuple[bool, list[EvalFailure]]:
    """The rehearsal's last obligation: the target survives being restored elsewhere.

    ZigBase has no `backup` subcommand and does not need one — for SQLite the documented
    portable backup is a stop and a copy of the whole data directory, which captures
    `data.db`, its WAL state, uploaded files and `.jwt_secret` together
    (docs/deployment.md). Anything less is not a rollback unit: restore the database
    without `.jwt_secret` and every migrated session is void.

    So this copies the rehearsed target, verifies its database directly, boots a server
    on the copy, and proves the migrated credential still logs in there. Authorization
    semantics stay in ``tests_green``; repeating one here would let one rule defect sink
    two supposedly independent grades. A backup that cannot serve is not a backup.
    """
    failures: list[EvalFailure] = []
    try:
        binary = _binary(binary_path)
        target = workspace / ".rehearsal" / "data"
        second = workspace / ".rehearsal" / "restored"
        if not target.is_dir():
            raise GradeFailure(
                "deployment.no_target", "the rehearsal left no target to restore from"
            )
        if second.exists():
            shutil.rmtree(second)
        shutil.copytree(target, second)
        # Completeness by comparison, not by naming files. The data dir holds `data.db`,
        # its WAL state, uploaded files and — only when the server generated rather than
        # was given one — `.jwt_secret`. Requiring that filename fails a deployment
        # whose secret comes from the environment, which is the ordinary production
        # shape; requiring the copy to match the original catches a partial backup
        # either way.
        # No `original - copied` comparison: `copytree` produced `second` from `target`
        # two statements earlier, so comparing them compares a directory with its own
        # copy and can only ever pass. What is worth proving is that the copy SERVES.
        if not (second / "data.db").is_file():
            raise GradeFailure(
                "deployment.incomplete_unit", "the copied backup has no data.db"
            )

        with served_target(
            commands,
            binary,
            workspace,
            second,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_deployment_start,
            _deployment_teardown_failure,
            health_attempts=health_attempts,
        ) as base:
            database_inspector(second)
            (restore_probe or _probe_restored)(base)
        return True, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("deployment.error", f"{type(exc).__name__}: {exc}"))
    return False, failures


def _probe_restored(
    base: str, *, http_request: Callable[..., tuple[int, bytes]] = _request
) -> None:
    """The restored copy must serve the migration, not merely boot."""
    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": LOGIN_EMAIL, "password": LOGIN_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "deployment.restored_login",
            f"the migrated credential did not log in against the restored copy ({status})",
        )
    if not _response_json(payload, "restore.legacy_login").get("token"):
        raise GradeFailure(
            "deployment.restored_login",
            "login against the restored copy returned no token",
        )


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    port_picker: Callable[[], int] = free_port,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[..., dict[str, int]] = rails2zb.install_files,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
    restore_probe: Callable[..., None] | None = None,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = commands or SubprocessCommands(artifacts)

    report, completion_failures = inspect_completion(workspace)
    rules_failures = inspect_rules(workspace, report)
    failures = list(completion_failures) + list(rules_failures)

    tests_green, doctor, rehearsal_failures = run_rehearsal(
        workspace,
        artifacts,
        commands,
        port_picker=port_picker,
        binary_path=binary_path,
        behavior_probe=behavior_probe,
        database_inspector=database_inspector,
        file_installer=file_installer,
        health_getter=health_getter,
        health_attempts=health_attempts,
    )
    failures.extend(rehearsal_failures)

    deployed, restore_failures = run_restore(
        workspace,
        artifacts,
        commands,
        binary_path=binary_path,
        port_picker=port_picker,
        health_getter=health_getter,
        health_attempts=health_attempts,
        restore_probe=restore_probe,
        database_inspector=database_inspector,
    )
    failures.extend(restore_failures)

    boundary_green, boundary_failures = run_agent_boundary(
        workspace, commands, binary_path=binary_path
    )
    failures.extend(boundary_failures)
    tests_green = tests_green and boundary_green

    # `rules_locked` does not depend on the rehearsal reaching doctor. Every step before
    # the doctor call — schema apply, either import — used to leave `doctor` None and so
    # sink this grade alongside `tests_green`, which says nothing about authorization.
    # The static half stands on its own; doctor only ever tightens it.
    rules_locked = not rules_failures and (
        doctor is None
        or (doctor.public_rules == EXPECTED_PUBLIC and doctor.errors == 0)
    )
    completion = report is not None and not any(
        failure.code.startswith(("completion.", "source."))
        for failure in completion_failures
    )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
