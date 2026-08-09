"""Tests for zigbase.errors, a port of clients/typescript/src/errors.ts."""

import json

from zigbase.errors import FieldError, ZigbaseError, parse_error_response


class TestZigbaseError:
    def test_captures_status_message_data_url(self) -> None:
        err = ZigbaseError(
            status=400,
            message="Failed to validate the request.",
            data={"email": FieldError(code="validation_required", message="Missing.")},
            url="http://x/api/collections/users/records",
        )
        assert isinstance(err, Exception)
        assert err.status == 400
        assert err.message == "Failed to validate the request."
        assert err.data["email"].code == "validation_required"
        assert err.data["email"].message == "Missing."
        assert err.url == "http://x/api/collections/users/records"

    def test_str_includes_status_message_and_url(self) -> None:
        err = ZigbaseError(status=400, message="Bad request.", url="http://x/api/y")
        assert str(err) == "ZigbaseError(400): Bad request. (http://x/api/y)"

    def test_data_defaults_to_empty_dict(self) -> None:
        err = ZigbaseError(status=500, message="oops", url="http://x")
        assert err.data == {}


class TestParseErrorResponse:
    def test_parses_a_zigbase_error_response_body(self) -> None:
        body = json.dumps({"status": 403, "code": "forbidden", "message": "Forbidden.", "data": {}})
        err = parse_error_response(403, body, "http://x/api/y")
        assert err.status == 403
        assert err.message == "Forbidden."
        assert err.data == {}
        # The frozen machine code must survive the transport.
        assert err.code == "forbidden"

    def test_exposes_a_bespoke_code_so_callers_never_match_on_message(self) -> None:
        body = json.dumps(
            {
                "status": 403,
                "code": "email_not_verified",
                "message": "Email not verified.",
                "data": {},
            }
        )
        err = parse_error_response(403, body, "http://x/api/y")
        # Same status as a plain `forbidden`; only `code` tells them apart.
        assert err.status == 403
        assert err.code == "email_not_verified"

    def test_ignores_a_non_string_code(self) -> None:
        # Pre-unification servers put the integer HTTP status in `code`.
        body = json.dumps({"code": 403, "message": "Forbidden."})
        err = parse_error_response(403, body, "http://x/api/y")
        assert err.code == ""

    def test_code_is_empty_when_body_is_not_json(self) -> None:
        err = parse_error_response(502, "oops", "http://x/api/y")
        assert err.code == ""

    def test_parses_field_level_error_data(self) -> None:
        body = json.dumps(
            {
                "message": "Failed to validate the request.",
                "data": {"email": {"code": "validation_required", "message": "Missing."}},
            }
        )
        err = parse_error_response(400, body, "http://x/api/y")
        assert err.status == 400
        assert err.message == "Failed to validate the request."
        assert err.data["email"].code == "validation_required"
        assert err.data["email"].message == "Missing."

    def test_falls_back_to_reason_phrase_when_body_is_not_json(self) -> None:
        err = parse_error_response(
            500, "oops", "http://x/api/y", reason_phrase="Internal Server Error"
        )
        assert err.status == 500
        assert err.message == "Internal Server Error"
        assert err.data == {}

    def test_falls_back_to_generic_message_when_no_reason_phrase(self) -> None:
        err = parse_error_response(500, "oops", "http://x/api/y")
        assert err.status == 500
        assert err.message == "Request failed with status 500"

    def test_falls_back_to_generic_message_when_reason_phrase_is_empty(self) -> None:
        err = parse_error_response(502, "oops", "http://x/api/y", reason_phrase="")
        assert err.message == "Request failed with status 502"

    def test_skips_a_malformed_field_error_entry(self) -> None:
        body = json.dumps(
            {
                "message": "Failed to validate the request.",
                "data": {
                    "email": {"code": "validation_required", "message": "Missing."},
                    "title": "not-an-object",
                    "age": {"code": 123, "message": "Bad."},
                    "views": {"code": "invalid"},
                },
            }
        )
        err = parse_error_response(400, body, "http://x/api/y")
        assert list(err.data.keys()) == ["email"]
        assert err.data["email"].code == "validation_required"
        assert "title" not in err.data
        assert "age" not in err.data
        assert "views" not in err.data

    def test_ignores_non_dict_data_field(self) -> None:
        body = json.dumps({"message": "oops", "data": "not-a-dict"})
        err = parse_error_response(400, body, "http://x/api/y")
        assert err.data == {}

    def test_ignores_non_string_message_field(self) -> None:
        body = json.dumps({"message": 12345})
        err = parse_error_response(400, body, "http://x/api/y", reason_phrase="Bad Request")
        assert err.message == "Bad Request"
