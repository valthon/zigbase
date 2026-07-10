"""Tests for zigbase.typed metadata + wire coercion, a port of
clients/dart/lib/typed.dart (metadata + coercion + expand sections)."""

from __future__ import annotations

from typing import Any

import pytest

from zigbase.typed import (
    TYPED_CORE_VERSION,
    CollectionMeta,
    FieldMeta,
    FieldType,
    NumberMode,
    coerce_bool,
    coerce_float,
    coerce_float_list,
    coerce_int,
    coerce_int_list,
    coerce_str,
    coerce_str_list,
    encode_fixed,
    encode_int,
    expand_many,
    expand_one,
)


def test_typed_core_version() -> None:
    assert TYPED_CORE_VERSION == "0.1.0"


class TestFieldType:
    def test_is_str_enum_with_all_members(self) -> None:
        assert FieldType.TEXT == "text"
        assert FieldType.EDITOR == "editor"
        assert FieldType.EMAIL == "email"
        assert FieldType.URL == "url"
        assert FieldType.NUMBER == "number"
        assert FieldType.BOOLEAN == "boolean"
        assert FieldType.DATE == "date"
        assert FieldType.AUTODATE == "autodate"
        assert FieldType.SELECT == "select"
        assert FieldType.RELATION == "relation"
        assert FieldType.FILE == "file"
        assert FieldType.JSON == "json"


class TestNumberMode:
    def test_is_str_enum_with_all_members(self) -> None:
        assert NumberMode.FLOAT == "float"
        assert NumberMode.INTEGER == "integer"
        assert NumberMode.FIXED == "fixed"


class TestFieldMeta:
    def test_defaults(self) -> None:
        meta = FieldMeta(type=FieldType.TEXT)
        assert meta.type == FieldType.TEXT
        assert meta.multi is False
        assert meta.mode == NumberMode.FLOAT
        assert meta.scale is None

    def test_is_frozen(self) -> None:
        meta = FieldMeta(type=FieldType.TEXT)
        with pytest.raises(AttributeError):
            meta.multi = True  # type: ignore[misc]

    def test_full_construction(self) -> None:
        meta = FieldMeta(type=FieldType.NUMBER, multi=True, mode=NumberMode.FIXED, scale=2)
        assert meta.multi is True
        assert meta.mode == NumberMode.FIXED
        assert meta.scale == 2


class TestCollectionMeta:
    def test_defaults(self) -> None:
        meta = CollectionMeta(name="posts", fields={"title": FieldMeta(type=FieldType.TEXT)})
        assert meta.name == "posts"
        assert meta.file_fields == ()
        assert meta.expandable == ()
        assert meta.is_auth is False
        assert meta.searchable is None
        assert meta.tenant is None

    def test_is_frozen(self) -> None:
        meta = CollectionMeta(name="posts", fields={})
        with pytest.raises(AttributeError):
            meta.name = "other"  # type: ignore[misc]

    def test_field_returns_meta_for_known_field(self) -> None:
        title_meta = FieldMeta(type=FieldType.TEXT)
        meta = CollectionMeta(name="posts", fields={"title": title_meta})
        assert meta.field("title") is title_meta

    def test_field_returns_none_for_unknown_field(self) -> None:
        meta = CollectionMeta(name="posts", fields={})
        assert meta.field("missing") is None

    def test_full_construction(self) -> None:
        meta = CollectionMeta(
            name="users",
            fields={"email": FieldMeta(type=FieldType.EMAIL)},
            file_fields=("avatar",),
            expandable=("owner",),
            is_auth=True,
            searchable=("email",),
            tenant="org",
        )
        assert meta.file_fields == ("avatar",)
        assert meta.expandable == ("owner",)
        assert meta.is_auth is True
        assert meta.searchable == ("email",)
        assert meta.tenant == "org"


class TestCoerceInt:
    def test_accepts_int(self) -> None:
        assert coerce_int(42) == 42

    def test_accepts_whole_float(self) -> None:
        assert coerce_int(42.0) == 42

    def test_rejects_fractional_float(self) -> None:
        with pytest.raises(ValueError):
            coerce_int(9.99)

    def test_accepts_int_string(self) -> None:
        assert coerce_int("42") == 42

    def test_accepts_whole_decimal_string(self) -> None:
        assert coerce_int("42.0") == 42

    def test_rejects_fractional_string(self) -> None:
        with pytest.raises(ValueError):
            coerce_int("9.99")

    def test_empty_string_returns_fallback(self) -> None:
        assert coerce_int("", 7) == 7

    def test_unparseable_string_returns_fallback(self) -> None:
        assert coerce_int("not-a-number", 7) == 7

    def test_none_returns_fallback(self) -> None:
        assert coerce_int(None, 3) == 3

    def test_default_fallback_is_zero(self) -> None:
        assert coerce_int(None) == 0

    def test_bool_falls_through_to_fallback(self) -> None:
        # bool is a subclass of int in Python, but Dart's `v is int` check
        # excludes bool at the type-system level; a bool wire value isn't
        # produced by an int-mode field, so it isn't a valid int here either
        # — it falls through to `fallback` like any other unrecognized type.
        assert coerce_int(True, 9) == 9
        assert coerce_int(False, 9) == 9
        assert coerce_int(True) == 0


class TestCoerceFloat:
    def test_accepts_int(self) -> None:
        assert coerce_float(42) == 42.0

    def test_accepts_float(self) -> None:
        assert coerce_float(9.99) == 9.99

    def test_accepts_numeric_string(self) -> None:
        assert coerce_float("9.99") == 9.99

    def test_empty_string_returns_fallback(self) -> None:
        assert coerce_float("", 1.5) == 1.5

    def test_unparseable_string_returns_fallback(self) -> None:
        assert coerce_float("nope", 1.5) == 1.5

    def test_none_returns_fallback(self) -> None:
        assert coerce_float(None, 2.5) == 2.5

    def test_default_fallback_is_zero(self) -> None:
        assert coerce_float(None) == 0.0

    def test_bool_falls_through_to_fallback(self) -> None:
        # Same Dart-parity rationale as coerce_int: bool is not a valid
        # numeric wire value, so it falls through to `fallback`.
        assert coerce_float(True, 9.5) == 9.5
        assert coerce_float(False, 9.5) == 9.5


class TestCoerceStr:
    def test_accepts_str(self) -> None:
        assert coerce_str("hello") == "hello"

    def test_non_str_returns_fallback(self) -> None:
        assert coerce_str(42, "x") == "x"

    def test_none_returns_fallback(self) -> None:
        assert coerce_str(None) == ""

    def test_default_fallback_is_empty_string(self) -> None:
        assert coerce_str(123) == ""


class TestCoerceBool:
    def test_accepts_true(self) -> None:
        assert coerce_bool(True) is True

    def test_accepts_false(self) -> None:
        assert coerce_bool(False) is False

    def test_non_bool_returns_fallback(self) -> None:
        assert coerce_bool("true", False) is False
        assert coerce_bool(1, False) is False

    def test_none_returns_fallback(self) -> None:
        assert coerce_bool(None, True) is True

    def test_default_fallback_is_false(self) -> None:
        assert coerce_bool(None) is False


class TestCoerceStrList:
    def test_list_of_strings_passthrough(self) -> None:
        assert coerce_str_list(["a", "b"]) == ["a", "b"]

    def test_list_of_mixed_values_stringified(self) -> None:
        assert coerce_str_list(["a", 1, True]) == ["a", "1", "True"]

    def test_single_nonempty_string_wrapped(self) -> None:
        assert coerce_str_list("a") == ["a"]

    def test_empty_string_returns_empty_list(self) -> None:
        assert coerce_str_list("") == []

    def test_none_returns_empty_list(self) -> None:
        assert coerce_str_list(None) == []

    def test_empty_list_returns_empty_list(self) -> None:
        assert coerce_str_list([]) == []

    def test_scalar_non_string_returns_empty_list(self) -> None:
        assert coerce_str_list(42) == []


class TestCoerceIntList:
    def test_list_of_ints(self) -> None:
        assert coerce_int_list([1, 2, 3]) == [1, 2, 3]

    def test_list_of_decimal_strings(self) -> None:
        assert coerce_int_list(["1", "2.0"]) == [1, 2]

    def test_list_with_fractional_element_raises(self) -> None:
        with pytest.raises(ValueError):
            coerce_int_list([1, "2.5"])

    def test_none_returns_empty_list(self) -> None:
        assert coerce_int_list(None) == []

    def test_scalar_returns_empty_list(self) -> None:
        assert coerce_int_list(5) == []

    def test_empty_list_returns_empty_list(self) -> None:
        assert coerce_int_list([]) == []

    def test_bool_element_falls_through_to_fallback(self) -> None:
        assert coerce_int_list([1, True, 3]) == [1, 0, 3]


class TestCoerceFloatList:
    def test_list_of_numbers(self) -> None:
        assert coerce_float_list([1, 2.5, "3.5"]) == [1.0, 2.5, 3.5]

    def test_none_returns_empty_list(self) -> None:
        assert coerce_float_list(None) == []

    def test_scalar_returns_empty_list(self) -> None:
        assert coerce_float_list(5.0) == []

    def test_empty_list_returns_empty_list(self) -> None:
        assert coerce_float_list([]) == []

    def test_bool_element_falls_through_to_fallback(self) -> None:
        assert coerce_float_list([1.0, False]) == [1.0, 0.0]


class TestEncodeInt:
    def test_encodes_positive_int(self) -> None:
        assert encode_int(42) == "42"

    def test_encodes_negative_int(self) -> None:
        assert encode_int(-7) == "-7"

    def test_encodes_zero(self) -> None:
        assert encode_int(0) == "0"

    def test_none_returns_none(self) -> None:
        assert encode_int(None) is None


class TestEncodeFixed:
    def test_rounds_to_scale(self) -> None:
        assert encode_fixed(9.99, 2) == "9.99"

    def test_pads_to_scale(self) -> None:
        assert encode_fixed(5, 2) == "5.00"

    def test_scale_zero(self) -> None:
        assert encode_fixed(5.4, 0) == "5"

    def test_none_returns_none(self) -> None:
        assert encode_fixed(None, 2) is None

    def test_exact_tie_rounds_half_up(self) -> None:
        # 0.125 is exactly representable in binary float, so this is a true
        # tie at the rendered scale; Dart's toStringAsFixed rounds it up.
        assert encode_fixed(0.125, 2) == "0.13"

    def test_apparent_tie_below_the_binary_value_rounds_down(self) -> None:
        # 2.675 is NOT exactly representable: its nearest binary float is
        # ~2.67499999999999982..., i.e. strictly below the tie, so it rounds
        # down to "2.67" — matching Dart's toStringAsFixed on the same
        # binary double rather than the decimal literal a naive
        # str-then-round approach would see.
        assert encode_fixed(2.675, 2) == "2.67"


def _from_record(r: Any) -> dict[str, Any]:
    return dict(r)


class TestExpandOne:
    def test_present_single_expand(self) -> None:
        record = {"id": "1", "expand": {"owner": {"id": "u1", "name": "Ada"}}}
        result = expand_one(record, "owner", _from_record)
        assert result == {"id": "u1", "name": "Ada"}

    def test_absent_key_returns_none(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {}}
        assert expand_one(record, "owner", _from_record) is None

    def test_no_expand_block_returns_none(self) -> None:
        record: dict[str, Any] = {"id": "1"}
        assert expand_one(record, "owner", _from_record) is None

    def test_expand_value_not_a_mapping_returns_none(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {"owner": [1, 2]}}
        assert expand_one(record, "owner", _from_record) is None

    def test_expand_block_not_a_mapping_returns_none(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": "nope"}
        assert expand_one(record, "owner", _from_record) is None


class TestExpandMany:
    def test_present_list_expand(self) -> None:
        record = {
            "id": "1",
            "expand": {"tags": [{"id": "t1"}, {"id": "t2"}]},
        }
        result = expand_many(record, "tags", _from_record)
        assert result == [{"id": "t1"}, {"id": "t2"}]

    def test_absent_key_returns_empty_list(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {}}
        assert expand_many(record, "tags", _from_record) == []

    def test_no_expand_block_returns_empty_list(self) -> None:
        record: dict[str, Any] = {"id": "1"}
        assert expand_many(record, "tags", _from_record) == []

    def test_expand_value_not_a_list_returns_empty_list(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {"tags": {"id": "t1"}}}
        assert expand_many(record, "tags", _from_record) == []

    def test_non_mapping_items_are_skipped(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {"tags": [{"id": "t1"}, "bad", 5]}}
        assert expand_many(record, "tags", _from_record) == [{"id": "t1"}]

    def test_empty_expand_block_key_returns_empty_list(self) -> None:
        record: dict[str, Any] = {"id": "1", "expand": {"tags": []}}
        assert expand_many(record, "tags", _from_record) == []
