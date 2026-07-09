"""Tests for zigbase.query, a port of clients/typescript/src/query.ts
(+ the named-placeholder `zbFilter` API and reject-don't-coerce hardening
from clients/dart/lib/src/query.dart).
"""

import math
from datetime import datetime, timedelta, timezone

import pytest

from zigbase.query import build_list_params, filter_value, format_date, vector_spec, zb_filter


class TestFilterValue:
    def test_passes_through_null_bool_finite_numbers_bare(self) -> None:
        assert filter_value(None) == "null"
        assert filter_value(True) == "true"
        assert filter_value(False) == "false"
        assert filter_value(5) == "5"
        assert filter_value(3.14) == "3.14"

    def test_integral_float_renders_bare_not_1_point_0(self) -> None:
        # Byte-parity with TS `String(value)` / Dart's stripped double.toString.
        assert filter_value(1.0) == "1"
        assert filter_value(2.5) == "2.5"
        assert filter_value(-0.0) == "0"

    def test_single_quotes_a_plain_string(self) -> None:
        assert filter_value("published") == "'published'"

    def test_escapes_an_embedded_single_quote(self) -> None:
        assert filter_value("O'Brien") == r"'O\'Brien'"

    def test_leaves_an_embedded_double_quote_literal(self) -> None:
        assert filter_value('say "hi"') == "'say \"hi\"'"

    def test_represents_a_value_with_both_single_and_double_quotes(self) -> None:
        assert filter_value('he said "hi" to O\'Brien') == "'he said \"hi\" to O\\'Brien'"

    def test_escapes_backslashes(self) -> None:
        assert filter_value(r"a\b") == r"'a\\b'"

    def test_escapes_control_characters(self) -> None:
        assert filter_value("a\nb\tc\rd") == r"'a\nb\tc\rd'"

    def test_neutralizes_an_injection_attempt(self) -> None:
        # The leading single quote is escaped, so the payload can never break
        # out of the single-quoted literal; the closing quote must never
        # appear unescaped anywhere in the output.
        evil = "' || 1=1 --"
        result = filter_value(evil)
        assert result == r"'\' || 1=1 --'"
        assert result[0] == "'"
        assert result[-1] == "'"
        # every quote strictly between the outer delimiters must be escaped
        inner = result[1:-1]
        i = 0
        while True:
            idx = inner.find("'", i)
            if idx == -1:
                break
            assert inner[idx - 1] == "\\", f"unescaped quote at {idx} in {inner!r}"
            i = idx + 1

    def test_serializes_datetime_as_single_quoted_utc_iso_string(self) -> None:
        d = datetime(2026, 6, 16, tzinfo=timezone.utc)
        assert filter_value(d) == "'2026-06-16T00:00:00.000Z'"

    def test_clamps_datetime_to_millisecond_precision(self) -> None:
        d = datetime(2026, 1, 2, 3, 4, 5, 678901, tzinfo=timezone.utc)
        assert filter_value(d) == "'2026-01-02T03:04:05.678Z'"

    def test_converts_a_non_utc_datetime_to_utc(self) -> None:
        d = datetime(2026, 1, 2, 0, tzinfo=timezone(timedelta(hours=-5)))
        assert filter_value(d) == "'2026-01-02T05:00:00.000Z'"

    def test_assumes_naive_datetime_is_already_utc(self) -> None:
        d = datetime(2026, 1, 2, 5)
        assert filter_value(d) == "'2026-01-02T05:00:00.000Z'"

    def test_raises_type_error_on_list_operand(self) -> None:
        with pytest.raises(TypeError, match=r"(?i)array"):
            filter_value([1, 2])
        with pytest.raises(TypeError, match=r"(?i)array"):
            filter_value(["a", "b"])

    def test_raises_type_error_on_dict_operand(self) -> None:
        with pytest.raises(TypeError, match=r"(?i)unsupported operand"):
            filter_value({"a": 1})

    def test_raises_type_error_on_non_finite_numbers(self) -> None:
        with pytest.raises(TypeError, match=r"(?i)non-finite"):
            filter_value(math.nan)
        with pytest.raises(TypeError, match=r"(?i)non-finite"):
            filter_value(math.inf)
        with pytest.raises(TypeError, match=r"(?i)non-finite"):
            filter_value(-math.inf)

    def test_raises_type_error_on_unsupported_type(self) -> None:
        with pytest.raises(TypeError, match=r"(?i)unsupported operand"):
            filter_value(object())

    def test_large_and_small_exponent_boundaries_match_js(self) -> None:
        # JS Number::toString notation-switch boundaries: fixed up to 1e21
        # (exclusive), exponential at/after; fixed down to 1e-6 (inclusive),
        # exponential below.
        assert filter_value(1e20) == "100000000000000000000"
        assert filter_value(1e21) == "1e+21"
        assert filter_value(1e-6) == "0.000001"
        assert filter_value(1e-7) == "1e-7"
        assert filter_value(0.1 + 0.2) == "0.30000000000000004"


class TestZbFilter:
    def test_interpolates_named_placeholders(self) -> None:
        assert (
            zb_filter("status = {:s} && n > {:n}", {"s": "pub", "n": 5})
            == "status = 'pub' && n > 5"
        )

    def test_supports_repeated_placeholders_and_static_text(self) -> None:
        assert (
            zb_filter("{:a} = {:a} && b = {:b}", {"a": "x", "b": True}) == "'x' = 'x' && b = true"
        )

    def test_raises_key_error_on_unknown_placeholder(self) -> None:
        with pytest.raises(KeyError):
            zb_filter("x = {:missing}", {})

    def test_raises_value_error_on_unused_param(self) -> None:
        with pytest.raises(ValueError, match=r"(?i)unused"):
            zb_filter("x = {:a}", {"a": 1, "b": 2})

    def test_passes_through_an_expression_with_no_placeholders(self) -> None:
        assert zb_filter('status = "published"', {}) == 'status = "published"'

    def test_injection_attempt_via_placeholder_stays_inert(self) -> None:
        assert zb_filter("name = {:v}", {"v": "' || 1=1 --"}) == r"name = '\' || 1=1 --'"


class TestFormatDate:
    def test_formats_aware_utc_datetime(self) -> None:
        assert format_date(datetime(2026, 6, 16, tzinfo=timezone.utc)) == "2026-06-16T00:00:00.000Z"

    def test_truncates_microseconds_to_milliseconds(self) -> None:
        d = datetime(2026, 1, 2, 3, 4, 5, 678901, tzinfo=timezone.utc)
        assert format_date(d) == "2026-01-02T03:04:05.678Z"

    def test_converts_non_utc_aware_datetime(self) -> None:
        d = datetime(2026, 1, 2, 0, tzinfo=timezone(timedelta(hours=-5)))
        assert format_date(d) == "2026-01-02T05:00:00.000Z"

    def test_assumes_naive_datetime_is_utc(self) -> None:
        assert format_date(datetime(2026, 1, 2, 5, 30, 1)) == "2026-01-02T05:30:01.000Z"


class TestVectorSpec:
    def test_formats_field_metric_json_array(self) -> None:
        # Byte-parity with TS `vectorSpec`, which serializes via
        # JSON.stringify: [1, 2.5] -> "[1,2.5]" (integral float bare).
        assert vector_spec("emb", [1.0, 2.5], metric="cosine") == "emb:cosine:[1,2.5]"

    def test_omits_metric_segment_when_absent(self) -> None:
        assert vector_spec("emb", [0.1, 0.2]) == "emb:[0.1,0.2]"

    def test_matches_typescript_fixture_values(self) -> None:
        assert vector_spec("embedding", [0.12, 0.04]) == "embedding:[0.12,0.04]"
        assert vector_spec("embedding", [1, 2], metric="cosine") == "embedding:cosine:[1,2]"
        assert vector_spec("embedding", [0.5], metric="l2") == "embedding:l2:[0.5]"

    def test_raises_type_error_on_non_finite_value(self) -> None:
        with pytest.raises(TypeError, match=r"(?i)non-finite"):
            vector_spec("e", [math.nan])
        with pytest.raises(TypeError, match=r"(?i)non-finite"):
            vector_spec("e", [math.inf])


class TestBuildListParams:
    def test_omits_all_absent_params(self) -> None:
        assert build_list_params() == {}

    def test_includes_only_provided_params_with_wire_names(self) -> None:
        params = build_list_params(
            filter="status = 'x'",
            sort="-created",
            expand="author",
            fields="id,title",
            search="hello",
            page=2,
            per_page=50,
            skip_total=True,
            vector="embedding:[0.1]",
        )
        assert params == {
            "filter": "status = 'x'",
            "sort": "-created",
            "expand": "author",
            "fields": "id,title",
            "search": "hello",
            "page": "2",
            "perPage": "50",
            "skipTotal": "true",
            "vector": "embedding:[0.1]",
        }

    def test_never_emits_empty_cursor_or_limit_when_absent(self) -> None:
        params = build_list_params(page=1, per_page=30)
        assert "cursor" not in params
        assert "limit" not in params

    def test_cursor_mode_params(self) -> None:
        params = build_list_params(cursor="abc123", limit=25, skip_total=False)
        assert params == {"cursor": "abc123", "limit": "25", "skipTotal": "false"}

    def test_empty_string_cursor_is_still_emitted(self) -> None:
        # An explicit empty cursor means "first page" in cursor mode and must
        # not be conflated with an absent (None) cursor.
        assert build_list_params(cursor="") == {"cursor": ""}
