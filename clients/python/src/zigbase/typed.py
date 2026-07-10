"""The generic **typed tier** runtime for the ZigBase Python client.

A generated `zbase_gen.py` (produced by `zigbase typegen --lang python` or
`zig build gen-client` with a Python output) instantiates the building
blocks in this module into concrete, schema-aware record dataclasses/models
and one typed service per collection. Everything schema-independent lives
here so the generated file stays thin and declarative — the same split
`clients/dart/lib/typed.dart` and the TypeScript `@zigbase/client/typed`
tier use.

This module ships in the **base** `zigbase` wheel and has no dependency on
Pydantic: coercion, encoding, and metadata are plain Python. Pydantic (or
any other validation layer) is a concern of *generated* code, layered on
top of these primitives, not of this module.

Port of `clients/dart/lib/typed.dart` (metadata + coercion + expand
sections); see that file for the canonical behavior this mirrors.
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from enum import Enum
from typing import TYPE_CHECKING, Any, Generic, TypeVar

from zigbase.query import filter_value

if TYPE_CHECKING:
    from zigbase.client import AsyncZigBase, ZigBase
    from zigbase.collection import AsyncCollectionService, CollectionService
    from zigbase.realtime import RealtimeEvent, Unsubscribe

TYPED_CORE_VERSION = "0.1.0"

T = TypeVar("T")
E = TypeVar("E")
F = TypeVar("F")

# ---------------------------------------------------------------------------
# Metadata — mirrors clients/dart/lib/typed.dart:24-91
# ---------------------------------------------------------------------------


class FieldType(str, Enum):
    """The ZigBase field-type universe (mirrors the server's field table)."""

    TEXT = "text"
    EDITOR = "editor"
    EMAIL = "email"
    URL = "url"
    NUMBER = "number"
    BOOLEAN = "boolean"
    DATE = "date"
    AUTODATE = "autodate"
    SELECT = "select"
    RELATION = "relation"
    FILE = "file"
    JSON = "json"


class NumberMode(str, Enum):
    """Numeric storage mode.

    `FLOAT` fields are plain doubles on the wire; `INTEGER` and `FIXED`
    fields are transmitted as **decimal strings** (the server scales them
    to integers for full i64 precision) and are coerced both directions by
    generated (de)serialization.
    """

    FLOAT = "float"
    INTEGER = "integer"
    FIXED = "fixed"


@dataclass(frozen=True)
class FieldMeta:
    """Per-field runtime descriptor.

    `mode`/`scale` carry the int-vs-fixed numeric distinction that drives
    decimal-string coercion (float fields use `NumberMode.FLOAT` and are
    never coerced).
    """

    type: FieldType
    multi: bool = False
    mode: NumberMode = NumberMode.FLOAT
    scale: int | None = None


@dataclass(frozen=True)
class CollectionMeta:
    """Per-collection runtime descriptor.

    `name` doubles as the realtime topic and the `client.collection(name)`
    key.
    """

    name: str
    fields: Mapping[str, FieldMeta]
    file_fields: tuple[str, ...] = ()
    expandable: tuple[str, ...] = ()
    is_auth: bool = False
    # Field names with full-text search enabled (server >= 0.9.0); None = none.
    searchable: tuple[str, ...] | None = None
    # Tenant-owning field name; the server stamps it on create. None = not
    # tenant-owned.
    tenant: str | None = None

    def field(self, name: str) -> FieldMeta | None:
        """Safe field lookup by name."""
        return self.fields.get(name)


# ---------------------------------------------------------------------------
# int/fixed coercion helpers — used by generated `from_record` constructors
# ---------------------------------------------------------------------------


def coerce_int(v: object, fallback: int = 0) -> int:
    """Coerce a wire value (a JSON number, or the decimal-string form used
    for int-mode fields) to an `int`. Returns `fallback` for
    None/empty/unparseable values, but **raises `ValueError` on a numeric
    value with a fractional part** (`"9.99"`, `9.99`): the server always
    sends integers for int-mode fields, so a non-integer number means the
    field is not actually int-mode — silent truncation would hide the
    schema drift.

    `bool` is deliberately *not* treated as a valid int here, even though
    it's an `int` subclass in Python: Dart's `v is int` check (the type this
    ports) excludes `bool` at the type-system level, so a bool wire value
    falls through to `fallback` like any other unrecognized type, for
    parity.
    """
    if isinstance(v, int) and not isinstance(v, bool):
        return v
    if isinstance(v, float):
        if v == int(v):
            return int(v)
        raise ValueError(f"int-mode field received a non-integer value: {v!r}")
    if isinstance(v, str):
        if v == "":
            return fallback
        try:
            return int(v)
        except ValueError:
            pass
        try:
            n = float(v)
        except ValueError:
            return fallback
        if n == int(n):
            return int(n)  # e.g. "42.0"
        raise ValueError(f"int-mode field received a non-integer value: {v!r}")
    return fallback


def coerce_float(v: object, fallback: float = 0.0) -> float:
    """Coerce a wire value to a `float` (int/fixed fields arrive as decimal
    strings). Returns `fallback` for None/empty/unparseable.

    Same Dart-parity rationale as `coerce_int`: `bool` is excluded, so it
    falls through to `fallback`.
    """
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    if isinstance(v, str):
        if v == "":
            return fallback
        try:
            return float(v)
        except ValueError:
            return fallback
    return fallback


def coerce_str(v: object, fallback: str = "") -> str:
    """Coerce a wire value to a non-null `str` (falls back to `""`)."""
    return v if isinstance(v, str) else fallback


def coerce_bool(v: object, fallback: bool = False) -> bool:
    """Coerce a wire value to a `bool` (falls back to `False`)."""
    return v if isinstance(v, bool) else fallback


def coerce_str_list(v: object) -> list[str]:
    """Coerce a wire array to `list[str]` (relation-id / file-name multi
    fields).
    """
    if isinstance(v, list):
        return [e if isinstance(e, str) else str(e) for e in v]
    if isinstance(v, str) and v != "":
        return [v]
    return []


def coerce_int_list(v: object) -> list[int]:
    """Coerce a wire array to `list[int]` (multi-value int fields; decimal
    strings).
    """
    if isinstance(v, list):
        return [coerce_int(e) for e in v]
    return []


def coerce_float_list(v: object) -> list[float]:
    """Coerce a wire array to `list[float]` (multi-value fixed/float
    fields).
    """
    if isinstance(v, list):
        return [coerce_float(e) for e in v]
    return []


def encode_int(v: int | None) -> str | None:
    """Serialize an `int` field to its decimal-string wire form."""
    return None if v is None else str(v)


def encode_fixed(v: float | None, scale: int) -> str | None:
    """Serialize a fixed-point field to its scaled decimal-string wire
    form, matching Dart's `toStringAsFixed(scale)`.

    Rounds the float's exact binary value (via `Decimal(v)`, *not*
    `Decimal(str(v))`) half-up to `scale` places. A plain
    `f"{v:.{scale}f}"` uses round-half-to-even and would render an exact
    tie like `0.125` at scale 2 as `"0.12"` instead of the `"0.13"` Dart
    produces.
    """
    if v is None:
        return None
    quantum = Decimal(1).scaleb(-scale)
    quantized = Decimal(v).quantize(quantum, rounding=ROUND_HALF_UP)
    return f"{quantized:.{scale}f}"


# ---------------------------------------------------------------------------
# Expand helpers
# ---------------------------------------------------------------------------


def expand_one(
    record: Mapping[str, Any],
    key: str,
    from_record: Callable[[Mapping[str, Any]], T],
) -> T | None:
    """Read a single expanded relation from `record["expand"][key]` and map
    it through the target collection's `from_record`. Returns `None` when
    the relation was not expanded. Used by generated `<Rec>Expand` classes.
    """
    ex = record.get("expand")
    if isinstance(ex, Mapping):
        v = ex.get(key)
        if isinstance(v, Mapping):
            return from_record(v)
    return None


def expand_many(
    record: Mapping[str, Any],
    key: str,
    from_record: Callable[[Mapping[str, Any]], T],
) -> list[T]:
    """Read a multi-value expanded relation from `record["expand"][key]`.
    Returns an empty list when the relation was not expanded.
    """
    ex = record.get("expand")
    if isinstance(ex, Mapping):
        v = ex.get(key)
        if isinstance(v, list):
            return [from_record(m) for m in v if isinstance(m, Mapping)]
    return []


# ---------------------------------------------------------------------------
# Fluent filter builder — mirrors clients/dart/lib/typed.dart:202-305
# ---------------------------------------------------------------------------

_OP_MAP: Mapping[str, str] = {
    "eq": "=",
    "neq": "!=",
    "gt": ">",
    "gte": ">=",
    "lt": "<",
    "lte": "<=",
    "like": "~",
    "nlike": "!~",
}


class Expr:
    """A compiled boolean filter expression.

    Combine with `and_`/`or_` (each parenthesizes the result to make
    precedence explicit) or the `&`/`|` operator sugar, and read the wire
    string via `compile()`.
    """

    __slots__ = ("_src",)

    def __init__(self, raw: str) -> None:
        self._src = raw

    def and_(self, other: Expr) -> Expr:
        return Expr(f"({self._src} && {other._src})")

    def or_(self, other: Expr) -> Expr:
        return Expr(f"({self._src} || {other._src})")

    __and__ = and_
    __or__ = or_

    def compile(self) -> str:
        """The ZigBase filter string this expression compiles to."""
        return self._src

    def __str__(self) -> str:
        return self._src

    def __repr__(self) -> str:
        return f"Expr({self._src!r})"

    def __bool__(self) -> bool:
        """Always raises. `and`/`or` and chained comparisons (`10 <= f.price
        <= 20`) both implicitly call `bool()` on an intermediate `Expr` and
        would otherwise silently discard one side of the filter instead of
        combining it, mirroring the same guard pandas' `Series.__bool__` and
        SQLAlchemy's `ColumnElement.__bool__` raise for the identical
        footgun. Use `&`/`|` (or `.and_()`/`.or_()`) to combine expressions,
        and avoid chained comparisons -- write `(10 <= f.price) & (f.price <=
        20)` instead.
        """
        raise TypeError(
            "The truth value of an Expr is ambiguous. Use '&'/'|' (or "
            "'.and_()'/'.or_()') to combine filters instead of 'and'/'or', "
            "and avoid chained comparisons like `10 <= f.price <= 20` -- "
            "both implicitly call bool() on an Expr, which would silently "
            "drop half the filter instead of raising."
        )


class FieldExpr(Generic[T]):
    """Base per-field accessor: equality + membership.

    Every operand is serialized through the base SDK's injection-safe
    `zigbase.query.filter_value` — this class and its subclasses never
    format an operand themselves.

    `eq`/`neq` are also bound to `__eq__`/`__ne__` so `f.title == "x"` reads
    naturally in a filter expression; this is deliberate DSL sugar, not
    value equality. It means `FieldExpr` instances are **not hashable and
    not comparable for identity/value** — they are throwaway builders
    returned from a generated `*Fields` accessor (e.g. `PostFields().title`)
    and are never meant to be used as dict keys or set members.
    """

    __slots__ = ("path",)

    def __init__(self, path: str) -> None:
        self.path = path

    def _op(self, key: str, value: object) -> Expr:
        return Expr(f"{self.path} {_OP_MAP[key]} {filter_value(value)}")

    def eq(self, value: T) -> Expr:
        return self._op("eq", value)

    def neq(self, value: T) -> Expr:
        return self._op("neq", value)

    def in_list(self, values: Sequence[T]) -> Expr:
        """`path in (v1, v2)`. An empty sequence emits `path in ()`, which
        the server compiles to constant-false.
        """
        rendered = ", ".join(filter_value(v) for v in values)
        return Expr(f"{self.path} in ({rendered})")

    # See the class docstring: this dunder sugar returns `Expr`, not `bool`,
    # deliberately breaking the `object.__eq__` contract. Python responds by
    # implicitly setting `__hash__` to `None` on any class that defines
    # `__eq__` in its own namespace (including via this assignment), so
    # instances become unhashable — which is fine, see above.
    __eq__ = eq  # type: ignore[assignment]
    __ne__ = neq  # type: ignore[assignment]


class ComparableFieldExpr(FieldExpr[T]):
    """A field that supports ordered comparisons (numbers, dates, strings)."""

    def gt(self, value: T) -> Expr:
        return self._op("gt", value)

    def gte(self, value: T) -> Expr:
        return self._op("gte", value)

    def lt(self, value: T) -> Expr:
        return self._op("lt", value)

    def lte(self, value: T) -> Expr:
        return self._op("lte", value)

    __gt__ = gt
    __ge__ = gte
    __lt__ = lt
    __le__ = lte


class StringFieldExpr(ComparableFieldExpr[str]):
    """A `text`/`email`/`url`/`editor` field: comparisons + `~`/`!~` pattern
    match.
    """

    def like(self, value: str) -> Expr:
        return self._op("like", value)

    def nlike(self, value: str) -> Expr:
        return self._op("nlike", value)


class NumFieldExpr(ComparableFieldExpr[float]):
    """A `number` field."""


class DateFieldExpr(ComparableFieldExpr[object]):
    """A `date`/`autodate` field — comparisons accept a `datetime` or an ISO
    string; `filter_value` renders either correctly.
    """


class BoolFieldExpr(FieldExpr[bool]):
    """A `bool` field."""


class EnumFieldExpr(FieldExpr[E]):
    """A `select` field typed to its generated enum `E`. Serializes the enum
    to its wire string via `wire_of` before handing it to `filter_value`.
    """

    __slots__ = ("_wire_of",)

    def __init__(self, path: str, wire_of: Callable[[E], str]) -> None:
        super().__init__(path)
        self._wire_of = wire_of

    def eq(self, value: E | None) -> Expr:
        return Expr(f"{self.path} = {self._filter_wire(value)}")

    def neq(self, value: E | None) -> Expr:
        return Expr(f"{self.path} != {self._filter_wire(value)}")

    def in_list(self, values: Sequence[E | None]) -> Expr:
        rendered = ", ".join(self._filter_wire(v) for v in values)
        return Expr(f"{self.path} in ({rendered})")

    def _filter_wire(self, value: E | None) -> str:
        # `None` must reach `filter_value` un-wired -- `wire_of` (e.g. `lambda
        # e: e.value`) has no defined behavior for `None`, and every other
        # FieldExpr already renders `None` -> `null` via `filter_value` alone.
        return filter_value(value if value is None else self._wire_of(value))

    # Rebind (not inherited): FieldExpr.__eq__/__ne__ were assigned from
    # FieldExpr's own eq/neq at that class's definition time, so without
    # this the base __eq__ would run unserialized and hand a raw enum
    # member to filter_value (raising TypeError) instead of going through
    # wire_of. See FieldExpr's docstring for the hashability tradeoff. (No
    # `type: ignore` needed here: mypy already accepted the narrowing from
    # FieldExpr's own ignored `__eq__`/`__ne__` assignment above.)
    __eq__ = eq
    __ne__ = neq


class RelFieldExpr(FieldExpr[str], Generic[F]):
    """A `relation` field: id-level ops (inherited from `FieldExpr[str]`)
    plus one level of nested-relation filtering via `rel`, e.g.
    `author.rel(lambda u: u.name.like('A'))` -> `author.name ~ 'A'`. `F` is
    the target collection's generated fields builder.
    """

    __slots__ = ("_make_fields",)

    def __init__(self, path: str, make_fields: Callable[[str], F]) -> None:
        super().__init__(path)
        self._make_fields = make_fields

    def rel(self, build: Callable[[F], Expr]) -> Expr:
        """Build a filter over the related record's fields by prefixing the
        target fields builder with `"{path}."` (one nesting level, matching
        the Dart/TS ports).
        """
        return build(self._make_fields(f"{self.path}."))


# ---------------------------------------------------------------------------
# Typed pagination envelopes — mirrors clients/dart/lib/typed.dart:307-345
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TypedList(Generic[T]):
    """Offset-pagination page of typed records."""

    items: list[T]
    page: int
    per_page: int
    total_items: int
    total_pages: int


@dataclass(frozen=True)
class TypedCursorPage(Generic[T]):
    """Keyset (cursor) page of typed records."""

    items: list[T]
    next_cursor: str | None
    prev_cursor: str | None
    has_next: bool
    has_prev: bool
    total_items: int | None


# ---------------------------------------------------------------------------
# Typed collection service — mirrors clients/dart/lib/typed.dart:347-522
# ---------------------------------------------------------------------------


def join_csv(values: Sequence[str] | None) -> str | None:
    """Join a sequence of strings to a comma string. `None`/empty ->
    `None`, so the query param is omitted rather than sent empty."""
    if not values:
        return None
    return ",".join(values)


def normalize_sort(sort: str | Sequence[str] | None) -> str | None:
    """Normalize a sort argument (a `str` or a sequence of `str`) to the
    base SDK's comma-joined string form. A sequence that is empty, or whose
    entries are all empty, normalizes to `None` (param omitted)."""
    if sort is None:
        return None
    if isinstance(sort, str):
        return sort
    parts = [s for s in sort if s]
    return ",".join(parts) if parts else None


class TypedCollection(Generic[T]):
    """The generic typed CRUD service that a generated per-collection
    service composes. Wraps the base `CollectionService` for `meta.name`
    and maps every returned record through `from_record`.

    Kept thin, matching `typed.dart:371-522`: `filter` is an
    already-compiled string (the where-compilation happens in generated
    services, per Task 6), and `sort`/`expand` are normalized here via
    `normalize_sort`/`join_csv` before being handed to the base SDK.
    """

    def __init__(
        self,
        client: ZigBase,
        meta: CollectionMeta,
        from_record: Callable[[Mapping[str, Any]], T],
    ) -> None:
        self._svc = client.collection(meta.name)
        self._files = client.files
        self.meta = meta
        self.from_record = from_record

    @property
    def collection(self) -> CollectionService:
        """The underlying base `CollectionService` -- escape hatch for
        collection methods the typed surface does not wrap (e.g. auth,
        abilities)."""
        return self._svc

    def get_list(
        self,
        page: int = 1,
        per_page: int = 30,
        *,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        skip_total: bool = False,
        search: str | None = None,
    ) -> TypedList[T]:
        """`GET /records` (offset pagination), mapped through `from_record`."""
        result = self._svc.get_list(
            page,
            per_page,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            skip_total=skip_total,
            search=search,
        )
        return TypedList(
            items=[self.from_record(item) for item in result.items],
            page=result.page,
            per_page=result.per_page,
            total_items=result.total_items,
            total_pages=result.total_pages,
        )

    def get_one(
        self,
        record_id: str,
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """`GET /records/:id`, mapped through `from_record`."""
        return self.from_record(
            self._svc.get_one(record_id, expand=join_csv(expand), fields=fields)
        )

    def get_first_list_item(
        self,
        filter: str,
        *,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> T:
        """`get_list(1, 1, skip_total=True, filter=filter, ...)` sugar,
        mapped through `from_record`. Raises a synthesized 404
        `ZigbaseError` when nothing matches (see `CollectionService`)."""
        return self.from_record(
            self._svc.get_first_list_item(
                filter,
                sort=normalize_sort(sort),
                expand=join_csv(expand),
                fields=fields,
                search=search,
            )
        )

    def get_page(
        self,
        *,
        cursor: str | None = None,
        limit: int = 30,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        with_total: bool = False,
        search: str | None = None,
    ) -> TypedCursorPage[T]:
        """Native server-side cursor (keyset) pagination, mapped through
        `from_record`. See `CollectionService.get_page` for the full
        contract."""
        page = self._svc.get_page(
            cursor=cursor,
            limit=limit,
            with_total=with_total,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            search=search,
        )
        return TypedCursorPage(
            items=[self.from_record(item) for item in page.items],
            next_cursor=page.next_cursor,
            prev_cursor=page.prev_cursor,
            has_next=page.has_next,
            has_prev=page.has_prev,
            total_items=page.total_items,
        )

    def iterate(
        self,
        *,
        batch: int = 100,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> Iterator[T]:
        """Iterate every matching record, mapped through `from_record`. See
        `CollectionService.iterate` for the non-advancing-cursor guard."""
        for item in self._svc.iterate(
            batch=batch,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            search=search,
        ):
            yield self.from_record(item)

    def get_full_list(
        self,
        *,
        batch: int = 100,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> list[T]:
        """Accumulate every matching record into a list via `iterate`."""
        return list(
            self.iterate(
                batch=batch, filter=filter, sort=sort, expand=expand, fields=fields, search=search
            )
        )

    def create(
        self,
        body: Mapping[str, Any],
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """`POST /records`. `body` is the RAW dict a generated `to_map()`
        produced -- passed through untouched -- and the response is mapped
        through `from_record`."""
        return self.from_record(self._svc.create(body, expand=join_csv(expand), fields=fields))

    def update(
        self,
        record_id: str,
        body: Mapping[str, Any],
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """`PATCH /records/:id`. `body` is passed through untouched -- see
        `create`."""
        return self.from_record(
            self._svc.update(record_id, body, expand=join_csv(expand), fields=fields)
        )

    def delete(self, record_id: str) -> None:
        """`DELETE /records/:id`."""
        self._svc.delete(record_id)

    def file_url(
        self,
        record: Mapping[str, Any],
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """Build a file URL for a stored filename on `record` (a raw record
        dict; generated services expose a typed `file_url(T, field=)`
        wrapper on top of this)."""
        return self._files.get_url(record, filename, download=download, thumb=thumb, token=token)


class AsyncTypedCollection(Generic[T]):
    """`TypedCollection`'s `asyncio` mirror, over an `AsyncZigBase`/
    `AsyncCollectionService`."""

    def __init__(
        self,
        client: AsyncZigBase,
        meta: CollectionMeta,
        from_record: Callable[[Mapping[str, Any]], T],
    ) -> None:
        self._svc = client.collection(meta.name)
        self._files = client.files
        self.meta = meta
        self.from_record = from_record

    @property
    def collection(self) -> AsyncCollectionService:
        """See `TypedCollection.collection`."""
        return self._svc

    async def get_list(
        self,
        page: int = 1,
        per_page: int = 30,
        *,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        skip_total: bool = False,
        search: str | None = None,
    ) -> TypedList[T]:
        """See `TypedCollection.get_list`."""
        result = await self._svc.get_list(
            page,
            per_page,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            skip_total=skip_total,
            search=search,
        )
        return TypedList(
            items=[self.from_record(item) for item in result.items],
            page=result.page,
            per_page=result.per_page,
            total_items=result.total_items,
            total_pages=result.total_pages,
        )

    async def get_one(
        self,
        record_id: str,
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """See `TypedCollection.get_one`."""
        return self.from_record(
            await self._svc.get_one(record_id, expand=join_csv(expand), fields=fields)
        )

    async def get_first_list_item(
        self,
        filter: str,
        *,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> T:
        """See `TypedCollection.get_first_list_item`."""
        return self.from_record(
            await self._svc.get_first_list_item(
                filter,
                sort=normalize_sort(sort),
                expand=join_csv(expand),
                fields=fields,
                search=search,
            )
        )

    async def get_page(
        self,
        *,
        cursor: str | None = None,
        limit: int = 30,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        with_total: bool = False,
        search: str | None = None,
    ) -> TypedCursorPage[T]:
        """See `TypedCollection.get_page`."""
        page = await self._svc.get_page(
            cursor=cursor,
            limit=limit,
            with_total=with_total,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            search=search,
        )
        return TypedCursorPage(
            items=[self.from_record(item) for item in page.items],
            next_cursor=page.next_cursor,
            prev_cursor=page.prev_cursor,
            has_next=page.has_next,
            has_prev=page.has_prev,
            total_items=page.total_items,
        )

    async def iterate(
        self,
        *,
        batch: int = 100,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> AsyncIterator[T]:
        """See `TypedCollection.iterate`."""
        async for item in self._svc.iterate(
            batch=batch,
            filter=filter,
            sort=normalize_sort(sort),
            expand=join_csv(expand),
            fields=fields,
            search=search,
        ):
            yield self.from_record(item)

    async def get_full_list(
        self,
        *,
        batch: int = 100,
        filter: str | None = None,
        sort: str | Sequence[str] | None = None,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
        search: str | None = None,
    ) -> list[T]:
        """See `TypedCollection.get_full_list`."""
        return [
            item
            async for item in self.iterate(
                batch=batch, filter=filter, sort=sort, expand=expand, fields=fields, search=search
            )
        ]

    async def create(
        self,
        body: Mapping[str, Any],
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """See `TypedCollection.create`."""
        return self.from_record(
            await self._svc.create(body, expand=join_csv(expand), fields=fields)
        )

    async def update(
        self,
        record_id: str,
        body: Mapping[str, Any],
        *,
        expand: Sequence[str] | None = None,
        fields: str | None = None,
    ) -> T:
        """See `TypedCollection.update`."""
        return self.from_record(
            await self._svc.update(record_id, body, expand=join_csv(expand), fields=fields)
        )

    async def delete(self, record_id: str) -> None:
        """See `TypedCollection.delete`."""
        await self._svc.delete(record_id)

    def file_url(
        self,
        record: Mapping[str, Any],
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """See `TypedCollection.file_url` -- a pure string builder, not
        `async`, matching `FilesService`/`AsyncFilesService`'s `get_url`."""
        return self._files.get_url(record, filename, download=download, thumb=thumb, token=token)


# ---------------------------------------------------------------------------
# Typed realtime — async-only; mirrors clients/dart/lib/typed.dart:522-569
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TypedRealtimeEvent(Generic[T]):
    """A record-mutation event with its `record` mapped through
    `from_record`. `action` is `create`/`update`/`delete`; on `delete`,
    `record` was converted from an id-only mapping (`{"id": ...}`) -- see
    `TypedRealtime.subscribe`.
    """

    topic: str
    action: str
    record: T


class TypedRealtime(Generic[T]):
    """Typed realtime surface for one collection. A generated subclass fixes
    `T` and `from_record`.

    Wraps the client's single **shared, multiplexed** `RealtimeService`
    (`AsyncZigBase.realtime`) -- there is deliberately no per-collection
    `close()` (the TS/Dart typed realtime surfaces have none either):
    closing the shared service would kill every other collection's
    subscriptions and permanently disable reconnect. Tear down individual
    subscriptions with the `Unsubscribe` returned by `subscribe()`; tear
    down the connection itself with `AsyncZigBase.aclose()`.

    `asyncio`-only, matching `AsyncZigBase.realtime` (there is no sync
    realtime service to wrap).
    """

    def __init__(
        self,
        client: AsyncZigBase,
        meta: CollectionMeta,
        from_record: Callable[[Mapping[str, Any]], T],
    ) -> None:
        self._rt = client.realtime
        self.meta = meta
        self.from_record = from_record

    async def subscribe(
        self,
        callback: Callable[[TypedRealtimeEvent[T]], Any],
        *,
        filter: str | None = None,
        where: Expr | None = None,
    ) -> Unsubscribe:
        """Subscribe to `meta.name`'s topic; `callback` receives each event
        with `record` mapped through `from_record` -- including `delete`
        events, whose id-only `record` still runs through `from_record`
        (its coercer fallbacks tolerate the missing fields), matching
        `typed.dart`'s `TypedRealtime` (no delete special case).

        `where` takes precedence over `filter` when both are given (`where
        .compile() if where else filter`). `callback` may be sync or a
        coroutine function -- the underlying `RealtimeService` already
        supports both and isolates a raising callback (logs via
        `on_realtime_error`, never kills the dispatch loop); this wrapper
        adds no additional try/except so that isolation isn't double-wrapped
        or altered.
        """

        def _wrap(event: RealtimeEvent) -> Any:
            return callback(
                TypedRealtimeEvent(event.topic, event.action, self.from_record(event.record))
            )

        return await self._rt.subscribe(
            self.meta.name, _wrap, filter=where.compile() if where is not None else filter
        )

    def stream(
        self, *, filter: str | None = None, where: Expr | None = None
    ) -> AsyncIterator[TypedRealtimeEvent[T]]:
        """A convenience `AsyncIterator` of `TypedRealtimeEvent`s for
        `meta.name`. See `RealtimeService.stream` for the full
        subscribe-on-first-iteration/teardown-on-break/cancel contract this
        inherits unchanged; `where`/`filter` behave as in `subscribe`.
        """
        return self._stream_events(filter=filter, where=where)

    async def _stream_events(
        self, *, filter: str | None, where: Expr | None
    ) -> AsyncIterator[TypedRealtimeEvent[T]]:
        async for event in self._rt.stream(
            self.meta.name, filter=where.compile() if where is not None else filter
        ):
            yield TypedRealtimeEvent(event.topic, event.action, self.from_record(event.record))


__all__ = [
    "TYPED_CORE_VERSION",
    "AsyncTypedCollection",
    "BoolFieldExpr",
    "CollectionMeta",
    "ComparableFieldExpr",
    "DateFieldExpr",
    "EnumFieldExpr",
    "Expr",
    "FieldExpr",
    "FieldMeta",
    "FieldType",
    "NumFieldExpr",
    "NumberMode",
    "RelFieldExpr",
    "StringFieldExpr",
    "TypedCollection",
    "TypedCursorPage",
    "TypedList",
    "TypedRealtime",
    "TypedRealtimeEvent",
    "coerce_bool",
    "coerce_float",
    "coerce_float_list",
    "coerce_int",
    "coerce_int_list",
    "coerce_str",
    "coerce_str_list",
    "encode_fixed",
    "encode_int",
    "expand_many",
    "expand_one",
    "join_csv",
    "normalize_sort",
]
