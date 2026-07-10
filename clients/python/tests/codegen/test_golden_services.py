"""Golden behavior tests for the generated Python typed client's SERVICE half
(Task 6: fields builders, meta, `<Rec>sService`/`Async<Rec>sService`,
`<Rec>sRealtime`, `ZbClient`/`AsyncZbClient`).

Drives a real `ZigBase`/`AsyncZigBase` over `httpx.MockTransport`, exactly
like `test_typed_service.py` drives the generic `TypedCollection` — so this
exercises the generated code through the SAME `client.collection(name)`/
`client.files` wiring a real deployment uses, not a fake.

Not marked `integration` (no server binary needed).
"""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx

from tests.codegen.dating.zbase_gen import (
    AsyncProfilesService,
    AsyncZbClient,
    PhotoFields,
    Profile,
    ProfileCreate,
    ProfileFileField,
    ProfileGender,
    ProfilesService,
    ProfileUpdate,
    TagsService,
    ZbClient,
    create_async_client,
    create_client,
)
from zigbase import AsyncZigBase, ZigBase
from zigbase.typed import TypedCursorPage, TypedList

Handler = Callable[[httpx.Request], httpx.Response]


def json_response(body: object, status: int = 200) -> httpx.Response:
    return httpx.Response(status, json=body)


def make_sync_client(handler: Handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def make_async_client(handler: Handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


PROFILE_RECORD = {
    "id": "prof123",
    "email": "alice@example.com",
    "username": "alice",
    "verified": True,
    "name": "Alice",
    "bio": "Hi there",
    "website": "https://example.com",
    "age": 29,
    "gender": "female",
    "avatar": "avatar.png",
    "created": "2024-01-01T00:00:00Z",
    "updated": "2024-01-02T00:00:00Z",
}


# ---------------------------------------------------------------------------
# Sync ProfilesService
# ---------------------------------------------------------------------------


def test_get_list_maps_items_to_profile_instances() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            {
                "page": 1,
                "perPage": 30,
                "totalItems": 1,
                "totalPages": 1,
                "items": [PROFILE_RECORD],
            }
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = ProfilesService(zb)

    result = svc.get_list()

    assert isinstance(result, TypedList)
    assert len(result.items) == 1
    assert isinstance(result.items[0], Profile)
    assert result.items[0].email == "alice@example.com"
    assert result.items[0].gender is ProfileGender.FEMALE
    zb.close()


def test_get_list_where_lambda_compiles_into_sent_filter() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {"page": 1, "perPage": 30, "totalItems": 0, "totalPages": 0, "items": []}
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = ProfilesService(zb)

    svc.get_list(where=lambda p: p.age.gte(21) & p.gender.eq(ProfileGender.FEMALE))

    query = dict(requests[0].url.params)
    assert query["filter"] == "(age >= 21 && gender = 'female')"
    zb.close()


def test_get_list_without_where_omits_filter() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(
            {"page": 1, "perPage": 30, "totalItems": 0, "totalPages": 0, "items": []}
        )

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    ProfilesService(zb).get_list()

    assert "filter" not in requests[0].url.params
    zb.close()


def test_filter_helper_compiles_without_a_request() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    svc = ProfilesService(zb)

    assert svc.filter(lambda p: p.name.like("Al")) == "name ~ 'Al'"
    zb.close()


def test_nested_relation_filter_compiles_dotted_path() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    # PhotosService isn't imported directly; exercise PhotoFields (the
    # builder every *Service.filter/where compiles through) standalone --
    # this is the same compilation `PhotosService(zb).filter(...)` would run.
    compiled = PhotoFields().owner.rel(lambda o: o.name.like("A")).compile()

    assert compiled == "owner.name ~ 'A'"
    zb.close()


def test_create_sends_to_map_body() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return json_response(PROFILE_RECORD)

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = ProfilesService(zb)

    data = ProfileCreate(
        email="alice@example.com",
        password="secret123",
        password_confirm="secret123",
        name="Alice",
        gender=ProfileGender.FEMALE,
    )
    result = svc.create(data)

    assert isinstance(result, Profile)
    sent_body = json.loads(requests[0].content)
    assert sent_body == {
        "email": "alice@example.com",
        "password": "secret123",
        "passwordConfirm": "secret123",
        "name": "Alice",
        "gender": "female",
    }
    zb.close()


def test_get_one_update_delete_smoke() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.method == "DELETE":
            return httpx.Response(204)
        return json_response(PROFILE_RECORD)

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = ProfilesService(zb)

    assert isinstance(svc.get_one("prof123"), Profile)
    assert isinstance(svc.update("prof123", ProfileUpdate(name="Alice B.")), Profile)
    svc.delete("prof123")
    assert requests[-1].method == "DELETE"
    zb.close()


def test_auth_with_password_grafted_on_auth_collection() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/collections/profiles/auth-with-password"
        return json_response({"token": "tok", "record": PROFILE_RECORD})

    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(handler))
    svc = ProfilesService(zb)

    resp = svc.auth_with_password("alice@example.com", "secret123")
    assert resp.token == "tok"
    zb.close()


def test_file_url_builds_via_enum_field_typed_record() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    svc = ProfilesService(zb)
    profile = Profile.from_record(PROFILE_RECORD)

    url = svc.file_url(profile, field=ProfileFileField.AVATAR)

    assert url == "http://localhost:8090/api/files/profiles/prof123/avatar.png"
    zb.close()


def test_file_url_accepts_raw_mapping_too() -> None:
    zb = ZigBase("http://localhost:8090", http_client=make_sync_client(lambda r: json_response({})))
    svc = ProfilesService(zb)

    url = svc.file_url(PROFILE_RECORD, field=ProfileFileField.AVATAR)

    assert url == "http://localhost:8090/api/files/profiles/prof123/avatar.png"
    zb.close()


# ---------------------------------------------------------------------------
# Sync ZbClient / create_client
# ---------------------------------------------------------------------------


def test_zb_client_wires_every_collection_service() -> None:
    client = create_client(
        "http://localhost:8090",
        http_client=make_sync_client(lambda r: json_response({})),
    )
    assert isinstance(client, ZbClient)
    assert isinstance(client.profiles, ProfilesService)
    assert isinstance(client.tags, TagsService)
    assert not hasattr(client, "profilesRealtime")  # sync client: no realtime
    client.close()


# ---------------------------------------------------------------------------
# Async AsyncProfilesService / AsyncZbClient
# ---------------------------------------------------------------------------


async def test_async_get_list_maps_items_and_create_smoke() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.method == "POST":
            return json_response(PROFILE_RECORD)
        return json_response(
            {
                "page": 1,
                "perPage": 30,
                "totalItems": 1,
                "totalPages": 1,
                "items": [PROFILE_RECORD],
            }
        )

    zb = AsyncZigBase("http://localhost:8090", http_client=make_async_client(handler))
    svc = AsyncProfilesService(zb)

    result = await svc.get_list(where=lambda p: p.username.eq("alice"))
    assert isinstance(result, TypedList)
    assert isinstance(result.items[0], Profile)
    assert dict(requests[0].url.params)["filter"] == "username = 'alice'"

    data = ProfileCreate(email="a@b.com", password="secret123", password_confirm="secret123")
    created = await svc.create(data)
    assert isinstance(created, Profile)

    page = await svc.get_page()
    assert isinstance(page, TypedCursorPage)

    await zb.aclose()


async def test_async_zb_client_exposes_realtime_accessors() -> None:
    client = create_async_client(
        "http://localhost:8090",
        http_client=make_async_client(lambda r: json_response({})),
    )
    assert isinstance(client, AsyncZbClient)
    assert isinstance(client.profiles, AsyncProfilesService)
    assert client.profilesRealtime.meta.name == "profiles"
    await client.aclose()
