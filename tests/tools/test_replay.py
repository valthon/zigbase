"""Unit tests for the parity-replay harness. Pure functions only — no network."""

import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys

import pytest

SPEC = pathlib.Path(__file__).resolve().parents[2] / "tools" / "replay" / "zb_replay.py"
spec = importlib.util.spec_from_file_location("zb_replay", SPEC)
zr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zr)


def test_subset_matches_extra_keys_but_not_missing_or_different():
    assert zr.diff_subset({"a": 1}, {"a": 1, "b": 2}) == []
    assert zr.diff_subset({}, {"a": 1}) == []
    assert zr.diff_subset({"a": 1}, {"a": 2}) == [
        {"path": "a", "expected": 1, "actual": 2}
    ]
    assert zr.diff_subset({"a": 1}, {"b": 1}) == [
        {"path": "a", "expected": 1, "actual": None, "message": "missing key"}
    ]


def test_null_expectation_passes_only_when_the_key_is_actually_present():
    # (a) expected null, key present and null -> no diff: a real null survived the migration.
    assert zr.diff_subset({"deletedAt": None}, {"deletedAt": None}) == []
    # (b) expected null, key absent entirely -> a diff: dict.get(k) would silently return
    # None for a missing key too, so without the sentinel a dropped nullable field passes.
    assert zr.diff_subset({"deletedAt": None}, {}) == [
        {
            "path": "deletedAt",
            "expected": None,
            "actual": None,
            "message": "missing key",
        }
    ]
    # (c) same absent-vs-null distinction nested inside an object inside an array.
    exp = {"items": [{"title": "x", "deletedAt": None}]}
    assert zr.diff_subset(exp, {"items": [{"title": "x", "deletedAt": None}]}) == []
    assert zr.diff_subset(exp, {"items": [{"title": "x"}]}) == [
        {
            "path": "items.0.deletedAt",
            "expected": None,
            "actual": None,
            "message": "missing key",
        }
    ]


def test_subset_recurses_into_objects_and_arrays():
    exp = {"items": [{"title": "x"}, {"title": "y"}]}
    assert (
        zr.diff_subset(
            exp, {"items": [{"title": "x", "id": "1"}, {"title": "y", "id": "2"}]}
        )
        == []
    )
    d = zr.diff_subset(exp, {"items": [{"title": "x"}, {"title": "ZZ"}]})
    assert d == [{"path": "items.1.title", "expected": "y", "actual": "ZZ"}]


def test_a_shorter_actual_array_is_a_failure_but_a_longer_one_is_not():
    assert zr.diff_subset({"i": [1, 2]}, {"i": [1, 2, 3]}) == []
    d = zr.diff_subset({"i": [1, 2]}, {"i": [1]})
    assert d == [
        {"path": "i.1", "expected": 2, "actual": None, "message": "missing key"}
    ]


def test_a_missing_null_array_element_is_a_failure_not_a_silent_pass():
    # A `None` element is a legitimate expectation (e.g. a nullable array entry survived the
    # migration as-is). Without the `_MISSING` sentinel, `actual[i] if i < len(actual) else
    # None` collapses "index absent" and "index holds null" — a migration that drops the
    # element entirely would satisfy an expectation of `[None]` against `[]`. It must not.
    assert zr.diff_subset({"i": [None]}, {"i": []}) == [
        {"path": "i.0", "expected": None, "actual": None, "message": "missing key"}
    ]
    assert zr.diff_subset({"i": [None]}, {"i": [None]}) == []


def test_volatile_keys_are_stripped_recursively():
    got = zr.strip_volatile(
        {"id": "x", "title": "t", "items": [{"id": "y", "created": "now", "n": 1}]},
        zr.DEFAULT_VOLATILE,
    )
    assert got == {"title": "t", "items": [{"n": 1}]}


def test_placeholders_resolve_from_vars_and_an_unknown_one_raises():
    assert zr.substitute("Bearer {{token}}", {"token": "abc"}) == "Bearer abc"
    assert zr.substitute({"h": "{{a}}/{{b}}"}, {"a": "1", "b": "2"}) == {"h": "1/2"}
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{missing}}", {})


def test_a_var_value_containing_a_placeholder_does_not_loop_forever():
    # `substitute` re-scans the string after every expansion (so "{{a}}" -> "{{b}}" -> "c"
    # resolves in one call). A --var value that itself contains a literal "{{...}}" would
    # otherwise re-match on every pass and never terminate — it must raise instead of hang.
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{a}}", {"a": "{{a}}"})
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{a}}", {"a": "{{b}}", "b": "{{a}}"})
    # A legitimate multi-hop chain that DOES bottom out still resolves, well under the cap.
    assert zr.substitute("{{a}}", {"a": "{{b}}", "b": "{{c}}", "c": "done"}) == "done"


def test_many_distinct_placeholders_in_one_string_resolve_without_hitting_the_cap():
    # The pass cap bounds nesting DEPTH, not the number of distinct placeholders expanded —
    # a captured URL or body can legitimately contain more of them than MAX_SUBSTITUTION_PASSES.
    variables = {f"v{i}": str(i) for i in range(15)}
    template = "".join(f"{{{{v{i}}}}}" for i in range(15))
    expected = "".join(str(i) for i in range(15))
    assert zr.substitute(template, variables) == expected

    # A self-referential var among otherwise-fine placeholders still raises: it's genuine
    # non-convergence, not just "many placeholders".
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{x}}", {"x": "{{x}}"})


def test_parse_capture_rejects_a_case_without_an_id_or_with_a_duplicate(tmp_path):
    p = tmp_path / "c.ndjson"
    p.write_text(json.dumps({"method": "GET", "path": "/x"}) + "\n")
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))
    p.write_text(
        "\n".join(
            [
                json.dumps({"id": "a", "method": "GET", "path": "/x"}),
                json.dumps({"id": "a", "method": "GET", "path": "/y"}),
            ]
        )
        + "\n"
    )
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))


@pytest.mark.parametrize(
    ("case", "message"),
    [
        ([], "must be a JSON object"),
        ({"id": 1, "method": "GET", "path": "/x"}, "unique"),
        ({"id": " padded ", "method": "GET", "path": "/x"}, "unique"),
        ({"id": "x", "method": "GET bad", "path": "/x"}, "method"),
        ({"id": "x", "method": "GET", "path": "relative"}, "absolute path"),
        ({"id": "x", "method": "GET", "path": "//authority"}, "absolute path"),
        ({"id": "x", "method": "GET", "path": "/a//b"}, "absolute path"),
        ({"id": "x", "method": "GET", "path": "/x?q=1"}, "without a query"),
        ({"id": "x", "method": "GET", "path": "/x#part"}, "fragment"),
        ({"id": "x", "method": "GET", "path": "/x\\y"}, "backslash"),
        ({"id": "x", "method": "GET", "path": "/a/../b"}, "dot segment"),
        ({"id": "x", "method": "GET", "path": "/a/%2e/b"}, "dot segment"),
        ({"id": "x", "method": "GET", "path": "/a%2fb"}, "encoded separator"),
        ({"id": "x", "method": "GET", "path": "/a%5Cb"}, "encoded separator"),
        ({"id": "x", "method": "GET", "path": "/a/%252f/b"}, "alternate encoding"),
        ({"id": "x", "method": "GET", "path": "/a/%41"}, "alternate encoding"),
        ({"id": "x", "method": "GET", "path": "/a/raw-é"}, "alternate encoding"),
        ({"id": "x", "method": "GET", "path": "/a/{id}"}, "placeholder"),
        ({"id": "x", "method": "GET", "path": "/a/{{bad-name}}"}, "placeholder"),
        ({"id": "x", "method": "GET", "path": "/x\n"}, "control character"),
        (
            {
                "id": "x",
                "method": "GET",
                "path": "/x",
                "expect": {"status": True},
            },
            "expect.status must be an integer",
        ),
        (
            {"id": "x", "method": "GET", "path": "/x", "query": {"n": 1}},
            "query must be an object of strings",
        ),
        (
            {"id": "x", "method": "GET", "path": "/x", "headers": []},
            "headers must be an object of strings",
        ),
        (
            {
                "id": "x",
                "method": "GET",
                "path": "/x",
                "expect": {"status": 99},
            },
            "between 100 and 599",
        ),
    ],
)
def test_capture_loader_rejects_invalid_case_shapes(tmp_path, case, message):
    capture = tmp_path / "capture.ndjson"
    capture.write_text(json.dumps(case) + "\n")

    with pytest.raises(zr.ReplayError, match=message):
        zr.load_capture(str(capture))


def test_capture_loader_preserves_null_expect_as_absent(tmp_path):
    capture = tmp_path / "capture.ndjson"
    case = {"id": "health", "method": "GET", "path": "/api/health", "expect": None}
    capture.write_text(json.dumps(case) + "\n")

    assert zr.load_capture(str(capture)) == [case]


@pytest.mark.parametrize("mode", ["capture", "requests"])
@pytest.mark.parametrize("separator", ["\u0085", "\u2028", "\u2029"])
def test_capture_loader_keeps_unicode_line_separators_inside_json_strings(
    tmp_path, mode, separator
):
    capture = tmp_path / "capture.ndjson"
    case = {
        "id": "unicode-body",
        "method": "POST",
        "path": "/echo",
        "body": {"text": f"left{separator}right"},
    }
    capture.write_text(json.dumps(case, ensure_ascii=False) + "\n", encoding="utf-8")

    assert zr.load_capture(str(capture), mode=mode) == [case]


def test_capture_loader_accepts_exact_path_placeholders(tmp_path):
    capture = tmp_path / "capture.ndjson"
    case = {
        "id": "record",
        "method": "GET",
        "path": "/api/records/{{record_id}}",
    }
    capture.write_text(json.dumps(case) + "\n")

    assert zr.load_capture(str(capture)) == [case]


@pytest.mark.parametrize(
    "value",
    ["../admin", "%2Fadmin", "%252f", "x?query", "x#fragment", r"x\y", "raw-é"],
)
def test_substituted_paths_are_revalidated_before_network_io(monkeypatch, value):
    opened = []
    monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: opened.append(True))
    case = {
        "id": "record",
        "method": "GET",
        "path": "/api/records/{{record_id}}",
    }

    with pytest.raises(zr.ReplayError, match="canonical absolute path"):
        zr.send("http://backend.invalid", case, {"record_id": value}, 1.0)

    assert opened == []


def test_send_resolved_rejects_an_unresolved_path_placeholder(monkeypatch):
    opened = []
    monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: opened.append(True))

    with pytest.raises(zr.ReplayError, match="unresolved placeholder"):
        zr.send_resolved(
            "http://backend.invalid",
            {"id": "record", "method": "GET", "path": "/records/{{id}}"},
            1.0,
        )

    assert opened == []


@pytest.mark.parametrize(
    ("headers", "message"),
    [
        ({"Bad Header": "value"}, "header name"),
        ({"X-Value": "ok\r\nInjected: yes"}, "header value"),
        ({"X-Value": "nul\x00byte"}, "header value"),
    ],
)
def test_substituted_headers_are_revalidated_before_network_io(
    monkeypatch, headers, message
):
    opened = []
    monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: opened.append(True))
    case = {
        "id": "headers",
        "method": "GET",
        "path": "/headers",
    }
    name, value = next(iter(headers.items()))
    case["headers"] = {name: "{{value}}"}

    with pytest.raises(zr.ReplayError, match=message):
        zr.send("http://backend.invalid", case, {"value": value}, 1.0)

    assert opened == []


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (
            b'{"id":"x","id":"y","method":"GET","path":"/x"}\n',
            "duplicate JSON key",
        ),
        (
            b'{"id":"x","method":"GET","path":"/x","body":NaN}\n',
            "non-finite JSON number",
        ),
        (b"\xff\xfe\n", "not UTF-8"),
    ],
)
def test_capture_loader_rejects_ambiguous_or_non_rfc_input(tmp_path, payload, message):
    capture = tmp_path / "capture.ndjson"
    capture.write_bytes(payload)

    with pytest.raises(zr.ReplayError, match=message):
        zr.load_capture(str(capture))


def test_capture_loader_enforces_its_bound_before_parsing(tmp_path, monkeypatch):
    capture = tmp_path / "capture.ndjson"
    capture.write_text('{"id":"x","method":"GET","path":"/x"}\n')
    monkeypatch.setattr(zr, "MAX_CAPTURE_BYTES", 8)

    with pytest.raises(zr.ReplayError, match="exceeds the 8-byte limit"):
        zr.load_capture(str(capture))


def test_capture_loader_validates_status_control_semantics_but_requests_mode_does_not(
    tmp_path,
):
    capture = tmp_path / "capture.ndjson"
    case = {
        "id": "concealed",
        "method": "GET",
        "path": "/posts/private",
        "expect": {"status": 200, "control": "denied"},
    }
    capture.write_text(json.dumps(case) + "\n")

    with pytest.raises(zr.ReplayError, match="incompatible with status 200"):
        zr.load_capture(str(capture))
    assert zr.load_capture(str(capture), mode="requests") == [case]


def test_single_file_copy_retains_the_documented_standalone_cli(tmp_path):
    copied = tmp_path / "zb_replay.py"
    shutil.copy2(SPEC, copied)

    result = subprocess.run(
        [sys.executable, str(copied), "--help"],
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "record" in result.stdout and "replay" in result.stdout


def test_compare_builds_a_finding_with_status_and_body_differences():
    case = {"id": "c1", "expect": {"status": 200, "bodySubset": {"a": 1}}}
    ok = zr.compare(case, 200, {"a": 1, "b": 9})
    assert ok["result"] == "pass" and ok["diff"] == []
    bad = zr.compare(case, 404, {"a": 2})
    assert bad["result"] == "fail"
    assert bad["status"] == {"expected": 200, "actual": 404}
    assert bad["diff"] == [{"path": "a", "expected": 1, "actual": 2}]


@pytest.mark.parametrize("payload", [b'{"value":NaN}', b'{"value":1,"value":2}'])
def test_non_rfc_json_responses_are_preserved_as_raw_text(monkeypatch, payload):
    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, _limit=None):
            return payload

    monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: Response())

    status, body = zr.send_resolved(
        "http://backend.invalid",
        {"id": "strict", "method": "GET", "path": "/strict"},
        1.0,
    )
    assert status == 200
    assert body == payload.decode()


def test_redirects_are_observed_without_following_or_forwarding_headers(monkeypatch):
    requests = []

    def redirect_response(request, **_kwargs):
        requests.append(request)
        raise zr.urllib.error.HTTPError(
            request.full_url,
            302,
            "Found",
            {"Location": "https://other.invalid/collect"},
            io.BytesIO(b'{"redirect":true}'),
        )

    monkeypatch.setattr(zr, "_open_url", redirect_response)
    status, body = zr.send_resolved(
        "http://backend.invalid",
        {
            "id": "redirect",
            "method": "POST",
            "path": "/signin",
            "headers": {"Authorization": "Bearer secret"},
        },
        1.0,
    )
    assert status == 302
    assert body == {"redirect": True}
    assert len(requests) == 1
    assert requests[0].get_header("Authorization") == "Bearer secret"
    assert (
        zr._NoRedirect().redirect_request(
            requests[0],
            None,
            302,
            "Found",
            {},
            "https://other.invalid/collect",
        )
        is None
    )


def test_replay_transport_ignores_ambient_proxy_configuration(tmp_path):
    environment = os.environ.copy()
    environment.update(
        {
            "HTTP_PROXY": "http://proxy.invalid:8080",
            "HTTPS_PROXY": "http://proxy.invalid:8080",
            "http_proxy": "http://proxy.invalid:8080",
            "https_proxy": "http://proxy.invalid:8080",
        }
    )
    completed = subprocess.run(
        [
            sys.executable,
            "-c",
            "from tools.replay import zb_replay; "
            "print([type(h).__name__ for h in zb_replay._NO_REDIRECT_OPENER.handlers])",
        ],
        cwd=SPEC.parents[2],
        env=environment,
        text=True,
        capture_output=True,
        check=True,
    )
    assert "ProxyHandler" not in completed.stdout


@pytest.mark.parametrize("http_error", [False, True])
def test_response_body_size_is_bounded_on_success_and_http_error(
    monkeypatch, http_error
):
    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, limit):
            return b"oversized"[:limit]

    monkeypatch.setattr(zr, "MAX_RESPONSE_BYTES", 4)
    if http_error:
        monkeypatch.setattr(
            zr,
            "_open_url",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(
                zr.urllib.error.HTTPError(
                    "http://backend.invalid/x",
                    400,
                    "Bad Request",
                    {},
                    io.BytesIO(b"oversized"),
                )
            ),
        )
    else:
        monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: Response())

    with pytest.raises(zr.ReplayError, match="response exceeds the 4-byte limit"):
        zr.send_resolved(
            "http://backend.invalid",
            {"id": "bounded", "method": "GET", "path": "/x"},
            1.0,
        )


@pytest.mark.parametrize("http_error", [False, True])
def test_invalid_utf8_response_is_a_protocol_error(monkeypatch, http_error):
    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, _limit):
            return b"\xff"

    if http_error:
        monkeypatch.setattr(
            zr,
            "_open_url",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(
                zr.urllib.error.HTTPError(
                    "http://backend.invalid/x",
                    400,
                    "Bad Request",
                    {},
                    io.BytesIO(b"\xff"),
                )
            ),
        )
    else:
        monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: Response())

    with pytest.raises(zr.ReplayError, match="response is not UTF-8"):
        zr.send_resolved(
            "http://backend.invalid",
            {"id": "utf8", "method": "GET", "path": "/x"},
            1.0,
        )


@pytest.mark.parametrize("payload", [b'{"value":NaN}', b'{"value":1,"value":2}'])
def test_record_emits_strict_capture_when_backend_response_is_not_rfc_json(
    tmp_path, monkeypatch, payload
):
    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self, _limit=None):
            return payload

    requests = tmp_path / "requests.ndjson"
    requests.write_text('{"id":"strict","method":"GET","path":"/strict"}\n')
    capture = tmp_path / "capture.ndjson"
    monkeypatch.setattr(zr, "_open_url", lambda *_args, **_kwargs: Response())

    assert (
        zr.main(
            [
                "record",
                "--base-url",
                "http://old.invalid",
                "--requests",
                str(requests),
                "--out",
                str(capture),
            ]
        )
        == 0
    )
    recorded = json.loads(capture.read_text(), parse_constant=zr._reject_json_constant)
    assert recorded["expect"]["bodySubset"] == payload.decode()


def test_artifact_writer_rejects_non_finite_values_without_replacing_output(tmp_path):
    output = tmp_path / "capture.ndjson"
    output.write_text("previous complete capture\n")

    with pytest.raises(zr.ReplayError, match="cannot write capture"):
        zr._write_capture_atomic(output, [{"value": float("nan")}])

    assert output.read_text() == "previous complete capture\n"
    assert list(tmp_path.glob(".capture.ndjson.*.tmp")) == []


@pytest.mark.parametrize("command", ["record", "replay"])
def test_empty_inputs_are_tool_failures_and_preserve_existing_outputs(
    tmp_path, monkeypatch, command
):
    source = tmp_path / "empty.ndjson"
    source.write_text("\n\n")
    output = tmp_path / ("capture.ndjson" if command == "record" else "findings.ndjson")
    output.write_text("previous complete artifact\n")
    sends = []
    monkeypatch.setattr(zr, "send", lambda *_args: sends.append(True))
    argv = (
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(source),
            "--out",
            str(output),
        ]
        if command == "record"
        else [
            "replay",
            str(source),
            "--base-url",
            "http://new.invalid",
            "--out",
            str(output),
        ]
    )

    assert zr.main(argv) == 1
    assert sends == []
    assert output.read_text() == "previous complete artifact\n"


def test_record_preserves_the_producer_control_while_refreshing_response_expectations(
    tmp_path, monkeypatch, capsys
):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps(
            {
                "id": "concealed-post",
                "method": "GET",
                "path": "/posts/private",
                "expect": {
                    "status": 200,
                    "bodySubset": {"stale": True},
                    "control": "denied",
                },
            }
        )
        + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    monkeypatch.setattr(
        zr, "send", lambda *_args: (404, {"code": "not_found", "id": "volatile"})
    )

    rc = zr.main(
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(requests),
            "--out",
            str(capture),
        ]
    )

    assert rc == 0
    assert json.loads(capsys.readouterr().out)["recorded"] == 1
    recorded = json.loads(capture.read_text())
    assert recorded["expect"] == {
        "status": 404,
        "bodySubset": {"code": "not_found"},
        "control": "denied",
    }


@pytest.mark.parametrize(
    ("status", "controls"),
    [
        (200, {"allowed"}),
        (204, {"allowed"}),
        (302, {"allowed", "journey"}),
        (400, {"denied", "validation"}),
        (401, {"denied"}),
        (403, {"denied"}),
        (404, {"denied"}),
        (409, {"validation"}),
        (422, {"validation"}),
        (500, set()),
    ],
)
def test_record_control_status_classification(status, controls):
    assert zr.allowed_controls_for_status(status) == controls
    for control in controls:
        zr.validate_recorded_control("case", status, control)


@pytest.mark.parametrize(
    ("status", "control"),
    [(200, "denied"), (302, "validation"), (404, "allowed"), (500, "allowed")],
)
def test_record_rejects_a_control_incompatible_with_the_recorded_status(
    status, control
):
    with pytest.raises(
        zr.ReplayError, match=rf"incompatible with recorded status {status}"
    ):
        zr.validate_recorded_control("case", status, control)


def test_record_command_refuses_to_write_an_incompatible_control(
    tmp_path, monkeypatch, capsys
):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps(
            {
                "id": "concealed-post",
                "method": "GET",
                "path": "/posts/private",
                "expect": {"control": "allowed"},
            }
        )
        + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    monkeypatch.setattr(zr, "send", lambda *_args: (404, {"code": "not_found"}))

    rc = zr.main(
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(requests),
            "--out",
            str(capture),
        ]
    )

    assert rc == 1
    assert (
        "control 'allowed' is incompatible with recorded status 404"
        in capsys.readouterr().err
    )
    assert not capture.exists()


@pytest.mark.parametrize(
    "expect",
    [[], {"control": None}, {"control": ""}, {"control": "mystery"}],
)
def test_record_prevalidates_all_control_shapes_before_sending_or_truncating(
    tmp_path, monkeypatch, expect
):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps({"id": "valid", "method": "GET", "path": "/ok"})
        + "\n"
        + json.dumps(
            {"id": "invalid", "method": "GET", "path": "/bad", "expect": expect}
        )
        + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    capture.write_text("existing capture\n")
    sends = []
    monkeypatch.setattr(zr, "send", lambda *_args: sends.append(True))

    rc = zr.main(
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(requests),
            "--out",
            str(capture),
        ]
    )

    assert rc == 1
    assert sends == []
    assert capture.read_text() == "existing capture\n"


def test_record_status_failure_does_not_leave_a_partial_capture(tmp_path, monkeypatch):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps({"id": "first", "method": "GET", "path": "/ok"})
        + "\n"
        + json.dumps(
            {
                "id": "second",
                "method": "GET",
                "path": "/concealed",
                "expect": {"control": "allowed"},
            }
        )
        + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    capture.write_text("existing capture\n")
    responses = iter([(200, {}), (404, {})])
    monkeypatch.setattr(zr, "send", lambda *_args: next(responses))

    rc = zr.main(
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(requests),
            "--out",
            str(capture),
        ]
    )

    assert rc == 1
    assert capture.read_text() == "existing capture\n"


def test_record_atomic_replace_failure_preserves_existing_capture(
    tmp_path, monkeypatch
):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps({"id": "one", "method": "GET", "path": "/ok"}) + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    capture.write_text("existing capture\n")
    monkeypatch.setattr(zr, "send", lambda *_args: (200, {}))
    monkeypatch.setattr(
        zr.os,
        "replace",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            PermissionError("replace denied")
        ),
    )

    rc = zr.main(
        [
            "record",
            "--base-url",
            "http://old.invalid",
            "--requests",
            str(requests),
            "--out",
            str(capture),
        ]
    )

    assert rc == 1
    assert capture.read_text() == "existing capture\n"
    assert list(tmp_path.glob(".capture.ndjson.*.tmp")) == []


@pytest.mark.parametrize("existing_mode", [None, 0o644])
def test_recorded_capture_is_private_on_create_and_rewrite(
    tmp_path, monkeypatch, existing_mode
):
    requests = tmp_path / "requests.ndjson"
    requests.write_text(
        json.dumps({"id": "one", "method": "GET", "path": "/ok"}) + "\n"
    )
    capture = tmp_path / "capture.ndjson"
    if existing_mode is not None:
        capture.write_text("old capture\n")
        capture.chmod(existing_mode)
    monkeypatch.setattr(zr, "send", lambda *_args: (200, {}))

    assert (
        zr.main(
            [
                "record",
                "--base-url",
                "http://old.invalid",
                "--requests",
                str(requests),
                "--out",
                str(capture),
            ]
        )
        == 0
    )
    assert stat.S_IMODE(capture.stat().st_mode) == 0o600


def test_replay_exits_1_when_every_case_dies_in_transport(
    tmp_path, monkeypatch, capsys
):
    # The tool ran, but the target never answered a single request — there's nothing to
    # judge, so this is a tool/environment failure (exit 1), not a parity finding.
    cap = tmp_path / "cap.ndjson"
    cap.write_text(
        json.dumps(
            {"id": "c1", "method": "GET", "path": "/x", "expect": {"status": 200}}
        )
        + "\n"
    )
    out = tmp_path / "findings.ndjson"

    def fake_send(base_url, case, variables, timeout):
        raise zr.ReplayError(f"{case['id']}: connection refused")

    monkeypatch.setattr(zr, "send", fake_send)
    rc = zr.main(
        ["replay", str(cap), "--base-url", "http://dead.invalid", "--out", str(out)]
    )

    assert rc == 1
    captured = capsys.readouterr()
    summary = json.loads(captured.out)
    assert summary["total"] == 1 and summary["passed"] == 0
    assert summary["failed"] == 0 and summary["errors"] == 1
    assert "unreachable" in captured.err


def test_replay_exits_2_when_some_cases_pass_and_one_dies_in_transport(
    tmp_path, monkeypatch, capsys
):
    # A vanished endpoint alongside working ones is parity signal, not a tool failure —
    # the run exercised the target and found something a human should look at (exit 2).
    cap = tmp_path / "cap.ndjson"
    cap.write_text(
        "\n".join(
            [
                json.dumps(
                    {
                        "id": "c1",
                        "method": "GET",
                        "path": "/ok",
                        "expect": {"status": 200},
                    }
                ),
                json.dumps(
                    {
                        "id": "c2",
                        "method": "GET",
                        "path": "/gone",
                        "expect": {"status": 200},
                    }
                ),
            ]
        )
        + "\n"
    )
    out = tmp_path / "findings.ndjson"

    def fake_send(base_url, case, variables, timeout):
        if case["id"] == "c1":
            return 200, {}
        raise zr.ReplayError(f"{case['id']}: connection refused")

    monkeypatch.setattr(zr, "send", fake_send)
    rc = zr.main(
        ["replay", str(cap), "--base-url", "http://mixed.invalid", "--out", str(out)]
    )

    assert rc == 2
    summary = json.loads(capsys.readouterr().out)
    assert summary["total"] == 2
    assert summary["passed"] == 1 and summary["failed"] == 0 and summary["errors"] == 1


def test_replay_findings_replace_failure_preserves_the_previous_complete_run(
    tmp_path, monkeypatch, capsys
):
    capture = tmp_path / "capture.ndjson"
    capture.write_text(
        json.dumps(
            {
                "id": "health",
                "method": "GET",
                "path": "/health",
                "expect": {"status": 200},
            }
        )
        + "\n"
    )
    findings = tmp_path / "findings.ndjson"
    findings.write_text("previous complete findings\n")
    monkeypatch.setattr(zr, "send", lambda *_args: (200, {}))
    monkeypatch.setattr(
        zr.os,
        "replace",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            PermissionError("replace denied")
        ),
    )

    rc = zr.main(
        [
            "replay",
            str(capture),
            "--base-url",
            "http://new.invalid",
            "--out",
            str(findings),
        ]
    )

    assert rc == 1
    assert findings.read_text() == "previous complete findings\n"
    assert list(tmp_path.glob(".findings.ndjson.*.tmp")) == []
    assert "cannot write findings" in capsys.readouterr().err


@pytest.mark.parametrize("existing_mode", [None, 0o640, 0o644])
def test_replay_findings_are_atomic_and_always_private(
    tmp_path, monkeypatch, existing_mode
):
    capture = tmp_path / "capture.ndjson"
    capture.write_text(
        json.dumps(
            {
                "id": "health",
                "method": "GET",
                "path": "/health",
                "expect": {"status": 200},
            }
        )
        + "\n"
    )
    findings = tmp_path / "findings.ndjson"
    if existing_mode is not None:
        findings.write_text("old\n")
        findings.chmod(existing_mode)
    monkeypatch.setattr(zr, "send", lambda *_args: (200, {}))

    assert (
        zr.main(
            [
                "replay",
                str(capture),
                "--base-url",
                "http://new.invalid",
                "--out",
                str(findings),
            ]
        )
        == 0
    )
    assert stat.S_IMODE(findings.stat().st_mode) == 0o600
    assert json.loads(findings.read_text()) == {
        "id": "health",
        "result": "pass",
        "diff": [],
    }
