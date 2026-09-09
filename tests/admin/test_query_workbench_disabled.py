"""Default build has no query diagnostic routes or enabled discovery flag."""
import json
import urllib.error
import urllib.request

def test_workbench_compiled_out(server):
    for method, path in [("GET", "/api/query-workbench/stats"), ("POST", "/api/query-workbench/explain")]:
        request = urllib.request.Request(server + path, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == 404
    with urllib.request.urlopen(server + "/api/meta", timeout=5) as response:
        value = json.load(response)
    assert value["capabilities"]["queryWorkbench"] is False
    assert value["endpoints"]["queryWorkbench"] is None
