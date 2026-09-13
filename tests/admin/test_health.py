"""The exact built-in liveness GET never parses an unused multipart body."""
import json

from test_admission import call


def assert_liveness_ignores_multipart(server):
    headers = {"Content-Type": "multipart/form-data; boundary=broken"}
    status, _, body = call(server, "/api/health", data=b"invalid multipart", headers=headers)
    assert status == 200, body
    assert json.loads(body)["status"] == "ok"
    # Similar paths and other methods must still take the ordinary parser path.
    for path, method in (("/api/health/", "GET"), ("/api/health-extra", "GET"),
                         ("/api/health", "HEAD"), ("/api/health", "POST")):
        status, _, body = call(server, path, method, b"invalid multipart", headers=headers)
        assert status == 400, (path, method, body)
        if method != "HEAD":
            assert json.loads(body)["message"] == "Invalid multipart body."


def test_default_liveness_ignores_multipart(server):
    assert_liveness_ignores_multipart(server)
