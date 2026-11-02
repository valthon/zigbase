"""Run the published OAuth examples through the real SDK transport."""

import json
import re
from pathlib import Path

import httpx
import pytest

from zigbase.client import ZigBase

SDK_ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("path", [SDK_ROOT / "README.md", SDK_ROOT / "../../docs/python-sdk.md"])
@pytest.mark.parametrize("issued_state", ["server-state", None, ""])
@pytest.mark.parametrize("returned_state", ["server-state", "mismatch", ""])
def test_oauth_example(path: Path, issued_state: str | None, returned_state: str) -> None:
    if path.name == "python-sdk.md" and not path.is_file():
        pytest.skip("Repository guide is not included in the standalone SDK")
    blocks = re.findall(r"```python\n(.*?)\n```", path.read_text(), re.S)
    examples = [block for block in blocks if 'oauth2_init("github")' in block]
    assert len(examples) == 1
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path.rsplit("/", 1)[-1])
        if calls[-1] == "providers":
            return httpx.Response(200, json={"items": [{"name": "github"}]})
        if calls[-1] == "initiate":
            return httpx.Response(200, json={} if issued_state is None else {"state": issued_state})
        payload = json.loads(request.content)
        assert payload["state"] == "server-state"
        assert payload["code"] == "provider-code"
        assert len(payload["codeVerifier"]) >= 43
        return httpx.Response(200, json={"token": "session"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        zb = ZigBase("http://api.test", http_client=client)
        namespace = {"zb": zb, "returned_state": returned_state, "code": "provider-code"}
        if not issued_state:
            with pytest.raises(ValueError, match="This example requires server-issued OAuth state"):
                exec(compile(examples[0], str(path), "exec"), namespace)
            assert calls == ["providers", "initiate"]
        elif returned_state == "server-state":
            exec(compile(examples[0], str(path), "exec"), namespace)
            assert calls == ["providers", "initiate", "complete"]
            assert namespace["providers"] == [{"name": "github"}]
        else:
            with pytest.raises(ValueError, match="OAuth state mismatch"):
                exec(compile(examples[0], str(path), "exec"), namespace)
            assert calls == ["providers", "initiate"]
