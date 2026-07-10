"""Tests for the `zigbase.typed` fluent filter DSL (Expr/FieldExpr and its
per-type subclasses), a port of `clients/dart/lib/typed.dart:202-305` and its
test `clients/dart/test/typed_where_test.dart` — mirrored byte-for-byte on
compiled output where Dart and Python share the same case."""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum

import pytest

from zigbase.query import format_date
from zigbase.typed import (
    BoolFieldExpr,
    DateFieldExpr,
    EnumFieldExpr,
    NumFieldExpr,
    RelFieldExpr,
    StringFieldExpr,
)


class Status(str, Enum):
    DRAFT = "draft"
    PUBLISHED = "published"


def _status_wire(s: Status) -> str:
    return s.value


# A minimal generated-style fields builder for a `users` collection, used as
# the nested-relation target below (mirrors `UserFields` in the Dart test).
class UserFields:
    def __init__(self, prefix: str = "") -> None:
        self.prefix = prefix

    @property
    def name(self) -> StringFieldExpr:
        return StringFieldExpr(f"{self.prefix}name")

    @property
    def age(self) -> NumFieldExpr:
        return NumFieldExpr(f"{self.prefix}age")


# A minimal generated-style fields builder for a `posts` collection with a
# nested `author` relation to `users` (mirrors `PostFields` in the Dart test).
class PostFields:
    def __init__(self, prefix: str = "") -> None:
        self.prefix = prefix

    @property
    def title(self) -> StringFieldExpr:
        return StringFieldExpr(f"{self.prefix}title")

    @property
    def status(self) -> EnumFieldExpr[Status]:
        return EnumFieldExpr(f"{self.prefix}status", _status_wire)

    @property
    def price(self) -> NumFieldExpr:
        return NumFieldExpr(f"{self.prefix}price")

    @property
    def active(self) -> BoolFieldExpr:
        return BoolFieldExpr(f"{self.prefix}active")

    @property
    def published_at(self) -> DateFieldExpr:
        return DateFieldExpr(f"{self.prefix}publishedAt")

    @property
    def author(self) -> RelFieldExpr[UserFields]:
        return RelFieldExpr(f"{self.prefix}author", UserFields)


f = PostFields()


class TestScalarOperators:
    def test_string_comparisons_and_pattern_match(self) -> None:
        assert f.title.eq("hi").compile() == "title = 'hi'"
        assert f.title.neq("hi").compile() == "title != 'hi'"
        assert f.title.like("foo").compile() == "title ~ 'foo'"
        assert f.title.nlike("foo").compile() == "title !~ 'foo'"

    def test_string_ordering(self) -> None:
        assert f.title.gt("a").compile() == "title > 'a'"
        assert f.title.gte("a").compile() == "title >= 'a'"
        assert f.title.lt("z").compile() == "title < 'z'"
        assert f.title.lte("z").compile() == "title <= 'z'"

    def test_number_comparisons(self) -> None:
        assert f.price.gte(10).compile() == "price >= 10"
        assert f.price.lt(2.5).compile() == "price < 2.5"
        assert f.price.gt(1).compile() == "price > 1"
        assert f.price.lte(9).compile() == "price <= 9"

    def test_bool_eq(self) -> None:
        assert f.active.eq(True).compile() == "active = true"
        assert f.active.neq(False).compile() == "active != false"

    def test_all_eight_ops_via_op_map(self) -> None:
        assert f.price.eq(1).compile() == "price = 1"
        assert f.price.neq(1).compile() == "price != 1"
        assert f.price.gt(1).compile() == "price > 1"
        assert f.price.gte(1).compile() == "price >= 1"
        assert f.price.lt(1).compile() == "price < 1"
        assert f.price.lte(1).compile() == "price <= 1"
        assert f.title.like("x").compile() == "title ~ 'x'"
        assert f.title.nlike("x").compile() == "title !~ 'x'"


class TestDunderSugar:
    def test_eq_ne_dunders_return_expr(self) -> None:
        assert (f.title == "hi").compile() == "title = 'hi'"
        assert (f.title != "hi").compile() == "title != 'hi'"

    def test_ordering_dunders_return_expr(self) -> None:
        assert (f.price > 1).compile() == "price > 1"
        assert (f.price >= 1).compile() == "price >= 1"
        assert (f.price < 1).compile() == "price < 1"
        assert (f.price <= 1).compile() == "price <= 1"

    def test_reflected_comparison_direction(self) -> None:
        # `10 <= f.age` has no int.__le__ for a FieldExpr operand, so Python
        # falls back to the reflected method on the right operand:
        # `f.age.__ge__(10)` -> "age >= 10", NOT "age <= 10".
        # Constant-on-the-left is the point of this test, not a style slip.
        age = NumFieldExpr("age")
        assert (10 <= age).compile() == "age >= 10"  # noqa: SIM300
        assert (10 < age).compile() == "age > 10"  # noqa: SIM300
        assert (10 >= age).compile() == "age <= 10"  # noqa: SIM300
        assert (10 > age).compile() == "age < 10"  # noqa: SIM300

    def test_fieldexpr_is_unhashable(self) -> None:
        # Overriding __eq__ makes FieldExpr instances throwaway builders, not
        # dict-key/set-member material — documented in FieldExpr's docstring.
        with pytest.raises(TypeError):
            hash(f.title)


class TestEnumField:
    def test_eq_neq_in_list_serialize_via_wire_of(self) -> None:
        assert f.status.eq(Status.PUBLISHED).compile() == "status = 'published'"
        assert f.status.neq(Status.DRAFT).compile() == "status != 'draft'"
        assert (
            f.status.in_list([Status.DRAFT, Status.PUBLISHED]).compile()
            == "status in ('draft', 'published')"
        )

    def test_eq_dunder_also_serializes_via_wire_of(self) -> None:
        # Regression guard: EnumFieldExpr must rebind __eq__/__ne__ itself,
        # not inherit FieldExpr's, or this would try to filter_value() a raw
        # Status enum member and raise TypeError instead of using wire_of.
        assert (f.status == Status.PUBLISHED).compile() == "status = 'published'"
        assert (f.status != Status.DRAFT).compile() == "status != 'draft'"

    def test_eq_neq_none_pass_through_to_null_without_calling_wire_of(self) -> None:
        # Regression guard: eq/neq must not unconditionally call wire_of(value)
        # -- wire_of is `lambda e: e.value`, and `None.value` raises
        # AttributeError. None must reach filter_value() un-wired, same as
        # every other FieldExpr (see the parity test below).
        assert f.status.eq(None).compile() == "status = null"
        assert f.status.neq(None).compile() == "status != null"

    def test_in_list_none_element_passes_through_to_null(self) -> None:
        assert f.status.in_list([Status.DRAFT, None]).compile() == "status in ('draft', null)"

    def test_none_handling_matches_a_plain_fieldexpr(self) -> None:
        # Parity: a plain FieldExpr (e.g. title, which has no wire_of at all)
        # already renders None -> null via filter_value. EnumFieldExpr's None
        # guard must produce the identical shape for the same op.
        assert f.status.eq(None).compile() == f.title.eq(None).compile().replace("title", "status")
        assert f.status.neq(None).compile() == f.title.neq(None).compile().replace(
            "title", "status"
        )


class TestInList:
    def test_non_empty(self) -> None:
        assert f.title.in_list(["a", "b"]).compile() == "title in ('a', 'b')"

    def test_empty_list_emits_constant_false_form(self) -> None:
        assert f.title.in_list([]).compile() == "title in ()"


class TestAndOrParenthesize:
    def test_and(self) -> None:
        e = f.price.gte(10).and_(f.status.eq(Status.PUBLISHED))
        assert e.compile() == "(price >= 10 && status = 'published')"

    def test_or(self) -> None:
        e = f.title.eq("a").or_(f.title.eq("b"))
        assert e.compile() == "(title = 'a' || title = 'b')"

    def test_and_or_dunder_sugar(self) -> None:
        e = f.price.gte(10) & f.status.eq(Status.PUBLISHED)
        assert e.compile() == "(price >= 10 && status = 'published')"
        e2 = f.title.eq("a") | f.title.eq("b")
        assert e2.compile() == "(title = 'a' || title = 'b')"

    def test_dunder_chaining_precedence(self) -> None:
        # (a & b) | c
        a = f.price.gte(10)
        b = f.status.eq(Status.PUBLISHED)
        c = f.active.eq(True)
        e = (a & b) | c
        assert e.compile() == "((price >= 10 && status = 'published') || active = true)"


class TestRelationFields:
    def test_id_level_eq(self) -> None:
        assert f.author.eq("u1").compile() == "author = 'u1'"

    def test_id_level_eq_dunder(self) -> None:
        assert (f.author == "u1").compile() == "author = 'u1'"

    def test_nested_relation_where_builds_dotted_path(self) -> None:
        assert f.author.rel(lambda u: u.name.like("Ann")).compile() == "author.name ~ 'Ann'"
        assert f.author.rel(lambda u: u.age.gt(21)).compile() == "author.age > 21"


class TestInjectionSafety:
    def test_escapes_quotes(self) -> None:
        assert f.title.eq("O'Brien").compile() == "title = 'O\\'Brien'"

    def test_escapes_quotes_in_in_list(self) -> None:
        assert f.title.in_list(["O'Brien"]).compile() == "title in ('O\\'Brien')"


class TestDateField:
    def test_datetime_operand_renders_via_format_date(self) -> None:
        dt = datetime(2024, 1, 2, 3, 4, 5, 678000, tzinfo=timezone.utc)
        expected = f"publishedAt >= '{format_date(dt)}'"
        assert f.published_at.gte(dt).compile() == expected

    def test_iso_string_operand_is_quoted_as_is(self) -> None:
        assert (
            f.published_at.eq("2024-01-02T03:04:05.678Z").compile()
            == "publishedAt = '2024-01-02T03:04:05.678Z'"
        )


class TestUnsupportedOperandsRaiseTypeError:
    def test_list_operand_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            f.title.eq(["a", "b"])  # type: ignore[arg-type]

    def test_dict_operand_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            f.title.eq({"a": 1})  # type: ignore[arg-type]


class TestExprBoolGuard:
    # An Expr's truth value has no sensible meaning -- it's a compiled filter
    # string, not a runtime value -- and Python silently calls bool() on it
    # in two easy-to-miss spots: `and`/`or` and chained comparisons. Both
    # would otherwise discard one side of the filter instead of combining
    # it, so Expr.__bool__ raises instead of returning a value.

    def test_bool_raises_type_error(self) -> None:
        with pytest.raises(TypeError, match="truth value of an Expr is ambiguous"):
            bool(f.title.eq("a"))

    def test_and_keyword_raises_instead_of_silently_dropping_a_side(self) -> None:
        # `a and b` evaluates bool(a) first; without the guard this would
        # just return `b`, discarding `a` from the filter with no error.
        with pytest.raises(TypeError):
            f.title.eq("a") and f.status.eq(Status.PUBLISHED)  # type: ignore[func-returns-value]

    def test_or_keyword_raises_instead_of_silently_dropping_a_side(self) -> None:
        with pytest.raises(TypeError):
            f.title.eq("a") or f.status.eq(Status.PUBLISHED)  # type: ignore[func-returns-value]

    def test_chained_comparison_raises(self) -> None:
        # `10 <= f.price <= 20` desugars to `(10 <= f.price) and (f.price <=
        # 20)`, so it hits the same bool() coercion as the `and` case above.
        with pytest.raises(TypeError):
            10 <= f.price <= 20  # type: ignore[misc]  # noqa: B015

    def test_where_expr_still_works_as_a_plain_value(self) -> None:
        # The guard only blocks *implicit* boolean coercion -- an Expr
        # passed around and compiled normally (e.g. as `where=` in
        # TypedRealtime.subscribe/stream, see test_typed_realtime.py) is
        # unaffected.
        e = f.title.eq("a")
        assert e is not None
        assert e.compile() == "title = 'a'"
