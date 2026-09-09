"""Stock builds do not register optional admission diagnostics."""
import urllib.error
import urllib.request


def test_admission_stats_absent_by_default(server):
    try:
        response = urllib.request.urlopen(server + "/api/admission/stats", timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == 404
