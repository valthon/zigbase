"""Tests for zigbase._multipart, a port of `hasBlob`/`toFormData` in
clients/typescript/src/records.ts + the buffer-once-for-retry and
loud-rejection hardening from clients/dart/lib/src/records.dart.
"""

import io
import json
from datetime import datetime, timezone

import pytest

from zigbase._multipart import encode_body, has_file


class TestHasFile:
    def test_false_for_plain_body(self) -> None:
        assert has_file({"title": "hi", "count": 3}) is False

    def test_true_for_top_level_file_like(self) -> None:
        assert has_file({"avatar": io.BytesIO(b"data")}) is True

    def test_true_for_top_level_file_tuple(self) -> None:
        assert has_file({"avatar": ("a.png", b"data")}) is True

    def test_true_for_file_inside_top_level_list(self) -> None:
        assert has_file({"attachments": [io.BytesIO(b"data")]}) is True

    def test_false_for_nested_file_not_at_top_level(self) -> None:
        # A file buried inside a nested dict is not detected -- only top-level
        # values/lists are scanned, matching hasBlob's shallow scan.
        assert has_file({"meta": {"avatar": io.BytesIO(b"data")}}) is False


class TestEncodeBodyJsonPath:
    def test_no_file_body_passes_through_as_json_body(self) -> None:
        result = encode_body({"title": "hi", "count": 3, "ok": True, "nothing": None})
        assert result.json_body == {"title": "hi", "count": 3, "ok": True, "nothing": None}
        assert result.fields is None
        assert result.files is None

    def test_rejects_non_encodable_value_naming_the_key(self) -> None:
        with pytest.raises(TypeError, match="bad_key"):
            encode_body({"good_key": "ok", "bad_key": {1, 2, 3}})

    def test_rejects_non_finite_float_naming_the_key(self) -> None:
        # NaN/Infinity survive json.dumps's default allow_nan=True and
        # produce RFC-8259-invalid JSON the server would reject opaquely;
        # query.filter_value already rejects these elsewhere in the SDK.
        with pytest.raises(TypeError, match="bad_key"):
            encode_body({"good_key": "ok", "bad_key": float("nan")})
        with pytest.raises(TypeError, match="bad_key"):
            encode_body({"good_key": "ok", "bad_key": float("inf")})

    def test_json_path_formats_nested_datetime(self) -> None:
        dt = datetime(2024, 3, 1, 12, 30, 45, 123000, tzinfo=timezone.utc)
        result = encode_body({"when": dt, "meta": {"when": dt}})
        assert result.json_body == {
            "when": "2024-03-01T12:30:45.123Z",
            "meta": {"when": "2024-03-01T12:30:45.123Z"},
        }


class TestEncodeBodyMultipartPath:
    def test_file_at_top_level_flips_to_multipart(self) -> None:
        result = encode_body({"title": "hi", "avatar": io.BytesIO(b"bytes")})
        assert result.json_body is None
        assert result.files is not None
        assert result.fields is not None
        assert ("title", "hi") in result.fields
        assert len(result.files) == 1
        key, (filename, content, content_type) = result.files[0]
        assert key == "avatar"
        assert content == b"bytes"
        assert content_type is None
        assert isinstance(filename, str) and filename

    def test_file_tuple_with_filename_and_content_type(self) -> None:
        result = encode_body({"avatar": ("pic.png", b"bytes", "image/png")})
        assert result.files == [("avatar", ("pic.png", b"bytes", "image/png"))]

    def test_list_of_files_repeats_the_key(self) -> None:
        result = encode_body(
            {
                "attachments": [
                    ("a.txt", b"aaa"),
                    ("b.txt", b"bbb"),
                ]
            }
        )
        assert result.files is not None
        assert [f[0] for f in result.files] == ["attachments", "attachments"]
        assert result.files[0][1] == ("a.txt", b"aaa", None)
        assert result.files[1][1] == ("b.txt", b"bbb", None)

    def test_none_becomes_empty_string_field(self) -> None:
        result = encode_body({"nothing": None, "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        assert ("nothing", "") in result.fields

    def test_none_inside_a_list_is_dropped(self) -> None:
        result = encode_body({"tags": ["a", None, "b"], "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        tag_fields = [f for f in result.fields if f[0] == "tags"]
        assert tag_fields == [("tags", "a"), ("tags", "b")]

    def test_nested_dict_is_json_encoded_as_one_field(self) -> None:
        result = encode_body({"meta": {"a": 1, "b": "x"}, "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        meta_fields = [f for f in result.fields if f[0] == "meta"]
        assert len(meta_fields) == 1
        assert json.loads(meta_fields[0][1]) == {"a": 1, "b": "x"}

    def test_datetime_field_is_formatted(self) -> None:
        dt = datetime(2024, 3, 1, 12, 30, 45, 123000, tzinfo=timezone.utc)
        result = encode_body({"when": dt, "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        assert ("when", "2024-03-01T12:30:45.123Z") in result.fields

    def test_bools_render_as_lowercase(self) -> None:
        result = encode_body({"a": True, "b": False, "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        assert ("a", "true") in result.fields
        assert ("b", "false") in result.fields

    def test_scalars_use_str(self) -> None:
        result = encode_body({"n": 5, "f": 3.5, "avatar": io.BytesIO(b"x")})
        assert result.fields is not None
        assert ("n", "5") in result.fields
        assert ("f", "3.5") in result.fields

    def test_file_like_content_is_buffered_for_reuse(self) -> None:
        result = encode_body({"avatar": io.BytesIO(b"payload-bytes")})
        assert result.files is not None
        first = result.files[0][1][1]
        second = result.files[0][1][1]
        assert first == second == b"payload-bytes"

    def test_nested_non_json_encodable_value_names_the_key(self) -> None:
        with pytest.raises(TypeError, match="meta"):
            encode_body({"meta": {"bad": {1, 2, 3}}, "avatar": io.BytesIO(b"x")})

    def test_nested_non_finite_float_names_the_key(self) -> None:
        with pytest.raises(TypeError, match="meta"):
            encode_body({"meta": {"bad": float("nan")}, "avatar": io.BytesIO(b"x")})
