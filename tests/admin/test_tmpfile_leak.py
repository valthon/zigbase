"""Large HTTP bodies must not leave named facil.io spill files behind."""
import json
from pathlib import Path
import sys
import urllib.request
import uuid

import pytest


# fio_tmpfile.h writes under P_tmpdir, which glibc defines as /tmp. Other
# platforms may use another directory, where this test would pass without
# looking at the spill files at all.
@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="spill dir checked only for glibc's P_tmpdir (/tmp)")
def test_large_request_body_unlinks_tmpfile(server):
    # Bundled facil.io/lib/facil/http/http.h defines HTTP_MAX_HEADER_LENGTH
    # as 8192. A 1 MiB body exercises http1.c's file-backed body path.
    marker = ("zigbase-tmpfile-" + uuid.uuid4().hex).encode()
    body = json.dumps({
        "padding": marker.decode() + "x" * (1024 * 1024),
        "identity": "admin@x.io",
        "password": "adminpassword",
    }).encode()
    temp_dir = Path("/tmp")  # fio_tmpfile.h uses P_tmpdir, not TMPDIR.
    before = set(temp_dir.glob("facil_io_tmpfile_*"))
    leaked = []
    try:
        request = urllib.request.Request(
            server + "/api/collections/_superusers/auth-with-password",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            assert response.status == 200
            assert json.load(response)["token"]

        # Other live servers can create files between snapshots. Only our
        # unguessable body marker identifies a leak belonging to this request.
        for path in set(temp_dir.glob("facil_io_tmpfile_*")) - before:
            try:
                with path.open("rb") as spill:
                    if marker in spill.read(256):
                        leaked.append(path)
            except OSError:
                # Already removed, or another user's 0600 file: either way
                # not this request's spill.
                continue
        assert not leaked, f"Request body left named spill files: {leaked}"
    finally:
        # Keep a failing run against the old dependency from leaking test data.
        for path in leaked:
            path.unlink(missing_ok=True)
