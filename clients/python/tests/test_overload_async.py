"""Admission overload retry contract, including non-idempotent requests."""

import httpx
import pytest
from test_transport_async import make_transport

from zigbase import _transport
from zigbase._request import RequestSpec
from zigbase.errors import ZigbaseError

OVERLOAD = '{"code":"overloaded","message":"busy"}'


@pytest.mark.parametrize("method", ["POST", "PATCH", "DELETE"])
async def test_overload_success(method, monkeypatch):
    calls = 0
    effects = 0
    delays = []

    async def sleep(seconds):
        delays.append(seconds)

    def handler(request):
        nonlocal calls, effects
        calls += 1
        assert request.method == method
        assert request.content == b'{"value":1}'
        if calls <= 2:
            return httpx.Response(503, text=OVERLOAD, headers={"Retry-After": "1"})
        effects += 1
        return httpx.Response(204)

    monkeypatch.setattr(_transport, "_asleep", sleep)
    t = make_transport(handler, max_retries=2)
    assert await t.request(RequestSpec(method, "/api/write", body={"value": 1})) is None
    assert (calls, effects) == (3, 1)
    assert delays == [1, 1]


@pytest.mark.parametrize("max_retries", [0, 2])
async def test_overload_bounded(max_retries, monkeypatch):
    calls = 0
    delays = []

    async def sleep(seconds):
        delays.append(seconds)

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(503, text=OVERLOAD)

    monkeypatch.setattr(_transport, "_asleep", sleep)
    t = make_transport(handler, max_retries=max_retries)
    with pytest.raises(ZigbaseError) as exc:
        await t.request(RequestSpec("POST", "/api/write"))
    assert (exc.value.status, exc.value.code) == (503, "overloaded")
    assert calls == max_retries + 1
    assert delays == ([0.2, 0.4] if max_retries else [])


@pytest.mark.parametrize(
    "body",
    [
        "oops",
        "null",
        "[]",
        '{"code":503}',
        '{"code":"unavailable"}',
        '{"data":{"x":{"code":"overloaded","message":"field"}}}',
    ],
)
async def test_generic_503_never_retried(body, monkeypatch):
    calls = 0

    async def sleep(seconds):
        pytest.fail("must not sleep")

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(503, text=body, headers={"Retry-After": "1"})

    monkeypatch.setattr(_transport, "_asleep", sleep)
    t = make_transport(handler, max_retries=2)
    with pytest.raises(ZigbaseError) as exc:
        await t.request(RequestSpec("POST", "/api/write"))
    assert exc.value.status == 503
    assert calls == 1


async def test_raw_bypasses_overload_retry():
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(503, text=OVERLOAD)

    t = make_transport(handler, max_retries=2)
    response = await t.raw_request(RequestSpec("POST", "/api/write"))
    assert response.status_code == 503
    assert response.text == OVERLOAD
    assert calls == 1
