"""Real CRUD retries use durable, bounded receipts and current authorization."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path

import pytest
from test_idempotency import call


@pytest.fixture(scope="session")
def binary():
    value = os.environ.get("ZIGBASE_TEST_REST_IDEMPOTENCY_BINARY")
    if not value:
        pytest.skip("requires rest-idempotency-fixture")
    assert Path(value).is_file()
    return value


def setup(base, reuse=False):
    status, login, _ = call(base, "POST", "/api/collections/_superusers/auth-with-password", {"identity": "admin@x.io", "password": "adminpassword"})
    assert status == 200, login
    admin = login["token"]
    if reuse:
        status, col, _ = call(base, "GET", "/api/collections/posts", token=admin)
        if status == 200:
            status, login, _ = call(base, "POST", "/api/collections/users/auth-with-password", {"identity": "a@example.com", "password": "password12345"})
            assert status == 200, login
            return admin, login["token"], login["record"], col
    assert call(base, "POST", "/api/collections", {"name": "users", "type": "auth", "fields": []}, admin)[0] == 201
    status, user, _ = call(base, "POST", "/api/collections/users/records", {"email": "a@example.com", "password": "password12345"}, admin)
    assert status == 201, user
    status, login, _ = call(base, "POST", "/api/collections/users/auth-with-password", {"identity": "a@example.com", "password": "password12345"})
    assert status == 200, login
    status, col, _ = call(base, "POST", "/api/collections", {"name": "posts", "type": "base", "createRule": "@public", "viewRule": "@public", "updateRule": "@public", "deleteRule": "@public", "fields": [{"id": "", "name": "title", "type": "text", "options": {}}]}, admin)
    assert status == 201, col
    return admin, login["token"], user, col


def test_concurrent_create_update_delete_and_conflict(server):
    admin, token, _, _ = setup(server)
    path = "/api/collections/posts/records"
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda _: call(server, "POST", path, {"title": "first"}, token, "create-one"), range(6)))
    assert [r[0] for r in results] == [201] * 6, results
    ids = {r[1]["id"] for r in results}
    assert len(ids) == 1
    assert call(server, "POST", path, {"title": "changed"}, token, "create-one")[0] == 409
    target = path + "/" + ids.pop()
    first = call(server, "PATCH", target, {"title": "second"}, token, "patch-one")
    assert first[0] == 200, first
    assert call(server, "PATCH", target, {"title": "second"}, token, "patch-one")[:2] == first[:2]
    assert call(server, "POST", path, {"title": "first"}, token, "create-one")[0] == 409
    assert call(server, "DELETE", target, token=token, key="delete-one")[0] == 204
    assert call(server, "DELETE", target, token=token, key="delete-one")[0] == 204
    assert call(server, "PATCH", target, {"title": "second"}, token, "patch-one")[0] == 404
    assert call(server, "GET", target, token=admin)[0] == 404


def test_current_identity_rules_schema_and_bounds(server):
    admin, token, user, col = setup(server)
    path = "/api/collections/posts/records"
    assert call(server, "POST", path, {"title": "first"}, key="anonymous")[0] == 401
    first = call(server, "POST", path, {"title": "first"}, token, "one")
    assert first[0] == 201, first
    assert call(server, "PATCH", "/api/collections/" + col["id"], {**col, "createRule": None}, admin)[0] == 200
    assert call(server, "POST", path, {"title": "first"}, token, "one")[0] == 403
    assert call(server, "PATCH", "/api/collections/" + col["id"], {**col, "createRule": "@public", "viewRule": None}, admin)[0] == 200
    assert call(server, "POST", path, {"title": "first"}, token, "one")[0] == 409
    assert call(server, "DELETE", "/api/collections/users/records/" + user["id"], token=admin)[0] == 204
    assert call(server, "POST", path, {"title": "first"}, token, "one")[0] == 401
    for i in range(7):
        result = call(server, "POST", path, {"title": str(i)}, admin, str(i))
        assert result[0] == 201, result
    assert call(server, "POST", path, {"title": "full"}, admin, "full")[0] == 503
    assert call(server, "POST", path + "?fields=id", {"title": "x"}, admin, "query")[0] == 400


@pytest.mark.parametrize("backend", ["sqlite", "postgres"])
def test_receipt_survives_restart_and_second_process(binary, tmp_path, backend):
    import subprocess
    from conftest import _reserve_port, _stop_server, _wait_reachable_or_fail
    url = os.environ.get("ZIGBASE_REST_PG_TEST_URL") if backend == "postgres" else None
    if backend == "postgres" and not url:
        pytest.skip("requires dedicated disposable ZIGBASE_REST_PG_TEST_URL")
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_SERVE_BACKGROUND": "0"}
    if url:
        env["ZIGBASE_DB_URL"] = url
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io", "--password", "adminpassword"], env=env, check=backend == "sqlite", capture_output=True, timeout=30)
    processes = []

    def start():
        with _reserve_port() as port:
            log_path = tmp_path / f"server-{port}.log"
            with log_path.open("wb") as log:
                proc = subprocess.Popen([binary, "serve", "--insecure-cookies", "--ignore-lock"], env={**env, "ZIGBASE_HTTP_PORT": str(port)}, stdout=log, stderr=subprocess.STDOUT)
            processes.append(proc)
            _wait_reachable_or_fail(proc, port, str(log_path))
            return f"http://127.0.0.1:{port}"

    try:
        first = start()
        admin, token, _, _ = setup(first, reuse=backend == "postgres")
        path = "/api/collections/posts/records"
        import uuid
        restart_key = "restart-" + uuid.uuid4().hex
        parallel_key = "parallel-" + uuid.uuid4().hex
        initial_count = len(call(first, "GET", path, token=admin)[1]["items"])
        original = call(first, "POST", path, {"title": "survives"}, token, restart_key)
        assert original[0] == 201, original
        _stop_server(processes.pop())
        second = start()
        assert call(second, "POST", path, {"title": "survives"}, token, restart_key)[:2] == original[:2]
        third = start()
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(lambda base: call(base, "POST", path, {"title": "parallel"}, token, parallel_key), [second, third]))
        # PostgreSQL deliberately fails fast while another replica owns namespace.
        for index, result in enumerate(outcomes):
            if result[0] == 503:
                outcomes[index] = call([second, third][index], "POST", path, {"title": "parallel"}, token, parallel_key)
        assert [r[0] for r in outcomes] == [201, 201], outcomes
        assert outcomes[0][1] == outcomes[1][1]
        assert len(call(second, "GET", path, token=admin)[1]["items"]) == initial_count + 2
        if backend == "sqlite":
            import sqlite3
            with sqlite3.connect(tmp_path / "data.db") as connection:
                connection.execute("UPDATE _idempotency_receipts SET result='[]'")
            assert call(second, "POST", path, {"title": "survives"}, token, restart_key)[0] == 500
            assert call(second, "GET", "/api/health")[0] == 200
    finally:
        for proc in processes:
            _stop_server(proc)


def test_unsupported_collections_and_failed_mutation_do_not_consume_key(server):
    admin, token, _, col = setup(server)
    path = "/api/collections/posts/records"
    assert call(server, "POST", path, [], token, "valid-after-error")[0] == 400
    assert call(server, "POST", path, {"title": "ok"}, token, "valid-after-error")[0] == 201
    assert call(server, "POST", "/api/collections/users/records", {"email": "b@example.com", "password": "password12345"}, admin, "auth")[0] == 400
    col["fields"] = col["schema"]
    col["fields"][0]["hidden"] = True
    assert call(server, "PATCH", "/api/collections/" + col["id"], col, admin)[0] == 200
    assert call(server, "POST", path, {"title": "ok"}, token, "valid-after-error")[0] == 400


def test_unavailable_feature_refuses_key_without_writing(tmp_path):
    import subprocess
    from conftest import _reserve_port, _stop_server, _wait_reachable_or_fail
    binary = os.environ.get("ZIGBASE_TEST_REST_IDEMPOTENCY_OFF_BINARY")
    if not binary:
        pytest.skip("requires default-off server binary")
    with _reserve_port() as port:
        env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path), "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
        subprocess.run([binary, "superuser", "create", "--email", "admin@x.io", "--password", "adminpassword"], env=env, check=True, capture_output=True, timeout=30)
        log_path = tmp_path / "server.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            base = f"http://127.0.0.1:{port}"
            admin, token, _, _ = setup(base)
            path = "/api/collections/posts/records"
            result = call(base, "POST", path, {"title": "refuse"}, token, "off")
            assert result[0] == 400, result
            assert call(base, "GET", path, token=admin)[1]["items"] == []
        finally:
            _stop_server(proc)


@pytest.mark.parametrize("replay", [False, True], ids=["fresh", "replay"])
@pytest.mark.parametrize("change", ["rule", "auth_collection_id"])
def test_postgres_rule_writer_blocks_receipt_authorization(binary, tmp_path, replay, change):
    """A concurrent rule change commits before fresh receipt authorization runs."""
    import subprocess
    import time
    from conftest import _reserve_port, _stop_server, _wait_reachable_or_fail

    url = os.environ.get("ZIGBASE_REST_PG_TEST_URL")
    if not url:
        pytest.skip("requires dedicated disposable ZIGBASE_REST_PG_TEST_URL")
    import psycopg

    with _reserve_port() as port:
        env = {**os.environ, "ZIGBASE_DB_URL": url, "ZIGBASE_DATA_DIR": str(tmp_path),
               "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
        # The preceding PostgreSQL restart test may already have bootstrapped this user.
        subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                        "--password", "adminpassword"], env=env, capture_output=True, timeout=30)
        log_path = tmp_path / "schema-coordination.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        base = f"http://127.0.0.1:{port}"
        original_rule = None
        original_auth_id = None
        replacement_auth_id = None
        restore_rule = False
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            admin, token, _, collection = setup(base, reuse=True)
            original_rule = collection["createRule"]
            status, auth_collection, _ = call(base, "GET", "/api/collections/users", token=admin)
            assert status == 200, auth_collection
            original_auth_id = auth_collection["id"]
            import uuid
            replacement_auth_id = uuid.uuid4().hex[:15]
            restore_rule = True
            key = "schema-race-replay" if replay else "schema-race-fresh"
            if replay:
                result = call(base, "POST", "/api/collections/posts/records",
                              {"title": "must-not-commit"}, token, key)
                assert result[0] == 201, result
            with psycopg.connect(url, autocommit=True) as writer, psycopg.connect(url, autocommit=True) as observer:
                def receipt_count():
                    if observer.execute("SELECT to_regclass('_idempotency_receipts')").fetchone()[0] is None:
                        return 0
                    return observer.execute("SELECT count(*) FROM _idempotency_receipts").fetchone()[0]

                before_receipts = receipt_count()
                before_records = observer.execute("SELECT count(*) FROM posts").fetchone()[0]
                writer.execute("BEGIN")
                writer.execute('UPDATE "_schema_state" SET generation=generation WHERE id=1')
                if change == "rule":
                    writer.execute('UPDATE "_collections" SET "createRule"=NULL WHERE name=%s', ("posts",))
                else:
                    # Model a replacement/import retaining auth table name and token
                    # bytes while changing the collection identity used by receipts.
                    writer.execute('UPDATE "_collections" SET id=%s WHERE name=%s', (replacement_auth_id, "users"))
                    writer.execute('UPDATE "_storage_namespaces" SET collection_id=%s WHERE collection_id=%s',
                                   (replacement_auth_id, original_auth_id))
                writer.execute('UPDATE "_schema_state" SET generation=generation+1 WHERE id=1')
                writer_pid = writer.info.backend_pid
                try:
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        pending = executor.submit(call, base, "POST", "/api/collections/posts/records",
                                                  {"title": "must-not-commit"}, token, key)
                        try:
                            deadline = time.monotonic() + 5
                            blocked = False
                            while time.monotonic() < deadline:
                                blocked = observer.execute(
                                    "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() "
                                    "AND %s=ANY(pg_blocking_pids(pid)) AND query LIKE %s)",
                                    (writer_pid, 'UPDATE "_schema_state"%'),
                                ).fetchone()[0]
                                if blocked or pending.done():
                                    break
                                time.sleep(0.02)
                            assert blocked, "REST mutation did not wait for the concurrent metadata writer"
                            assert not pending.done()
                        finally:
                            # Always release the request, including on a failed assertion.
                            writer.execute("COMMIT")
                        status, body, _ = pending.result(timeout=10)
                        assert status == (409 if change == "rule" else 401), body
                finally:
                    writer.execute("ROLLBACK")
                assert observer.execute('SELECT count(*) FROM posts').fetchone()[0] == before_records
                assert receipt_count() == before_receipts
                # authorize runs before receipt lookup/fingerprint comparison. The now
                # locked rule returns 403 for both fresh and replay attempts, not 409.
                if change == "rule":
                    assert call(base, "POST", "/api/collections/posts/records",
                                {"title": "must-not-commit"}, token, key)[0] == 403
        finally:
            try:
                if restore_rule:
                    with psycopg.connect(url) as cleanup:
                        cleanup.execute('UPDATE "_schema_state" SET generation=generation WHERE id=1')
                        cleanup.execute('UPDATE "_collections" SET "createRule"=%s WHERE name=%s', (original_rule, "posts"))
                        if change == "auth_collection_id":
                            cleanup.execute('UPDATE "_collections" SET id=%s WHERE name=%s', (original_auth_id, "users"))
                            cleanup.execute('UPDATE "_storage_namespaces" SET collection_id=%s WHERE collection_id=%s',
                                            (original_auth_id, replacement_auth_id))
                        cleanup.execute('UPDATE "_schema_state" SET generation=generation+1 WHERE id=1')
            finally:
                _stop_server(proc)


@pytest.mark.parametrize("operation", ["create", "update"])
def test_postgres_replay_waits_for_concurrent_record_writer(binary, tmp_path, operation):
    """A replay may not return its old body while a row mutation is in flight."""
    import subprocess
    import time
    from conftest import _reserve_port, _stop_server, _wait_reachable_or_fail

    url = os.environ.get("ZIGBASE_REST_PG_TEST_URL")
    if not url:
        pytest.skip("requires dedicated disposable ZIGBASE_REST_PG_TEST_URL")
    import psycopg

    with _reserve_port() as port:
        env = {**os.environ, "ZIGBASE_DB_URL": url, "ZIGBASE_DATA_DIR": str(tmp_path),
               "ZIGBASE_HTTP_PORT": str(port), "ZIGBASE_SERVE_BACKGROUND": "0"}
        subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                        "--password", "adminpassword"], env=env, capture_output=True, timeout=30)
        log_path = tmp_path / "row-coordination.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        base = f"http://127.0.0.1:{port}"
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            admin, token, _, _ = setup(base, reuse=True)
            path = "/api/collections/posts/records"
            method = "POST"
            if operation == "update":
                status, original, _ = call(base, "POST", path, {"title": "initial"}, admin)
                assert status == 201, original
                path += "/" + original["id"]
                method = "PATCH"
            key = "row-lock-" + operation
            status, receipt, _ = call(base, method, path, {"title": "receipt-body"}, token, key)
            assert status == (201 if operation == "create" else 200), receipt
            with psycopg.connect(url, autocommit=True) as writer, psycopg.connect(url, autocommit=True) as observer:
                before_receipts = observer.execute("SELECT count(*) FROM _idempotency_receipts").fetchone()[0]
                writer.execute("BEGIN")
                writer.execute('UPDATE posts SET title=%s WHERE id=%s', ("concurrent-body", receipt["id"]))
                writer_pid = writer.info.backend_pid
                try:
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        pending = executor.submit(call, base, method, path,
                                                  {"title": "receipt-body"}, token, key)
                        try:
                            deadline = time.monotonic() + 5
                            blocked = False
                            while time.monotonic() < deadline:
                                blocked = observer.execute(
                                    "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() "
                                    "AND %s=ANY(pg_blocking_pids(pid)) AND query LIKE %s)",
                                    (writer_pid, '%FOR UPDATE%'),
                                ).fetchone()[0]
                                if blocked or pending.done():
                                    break
                                time.sleep(0.02)
                            assert blocked, "REST replay did not wait for the concurrent record writer"
                            assert not pending.done()
                        finally:
                            writer.execute("COMMIT")
                        status, body, _ = pending.result(timeout=10)
                        assert status == 409, body
                finally:
                    writer.execute("ROLLBACK")
                assert observer.execute("SELECT title FROM posts WHERE id=%s", (receipt["id"],)).fetchone()[0] == "concurrent-body"
                assert observer.execute("SELECT count(*) FROM _idempotency_receipts").fetchone()[0] == before_receipts
        finally:
            _stop_server(proc)


@pytest.mark.parametrize("operation", ["create", "update"])
@pytest.mark.parametrize("view_rule,visible", [
    ('@request.method = "GET"', True),
    ('@request.method = "POST" || @request.method = "PATCH"', False),
    ('@request.data.title = "receipt-body"', False),
])
def test_replay_view_uses_get_context_and_action_keeps_mutation_context(server, operation, view_rule, visible):
    admin, token, _, col = setup(server)
    method = "POST" if operation == "create" else "PATCH"
    rule = f'@request.method = "{method}" && @request.data.title = "receipt-body"'
    definition = {**col, "viewRule": view_rule, ("createRule" if operation == "create" else "updateRule"): rule}
    status, body, _ = call(server, "PATCH", "/api/collections/posts", definition, admin)
    assert status == 200, body
    path = "/api/collections/posts/records"
    if operation == "update":
        status, original, _ = call(server, "POST", path, {"title": "initial"}, admin)
        assert status == 201, original
        path += "/" + original["id"]
    first = call(server, method, path, {"title": "receipt-body"}, token, "view-context")
    assert first[0] == (201 if operation == "create" else 200), first
    target = "/api/collections/posts/records/" + first[1]["id"]
    assert call(server, "GET", target, token=token)[0] == (200 if visible else 404)
    replay = call(server, method, path, {"title": "receipt-body"}, token, "view-context")
    assert replay[0] == (first[0] if visible else 404), replay
    if visible:
        assert replay[1] == first[1]


def test_keyed_validation_preserves_field_errors_and_failed_key_can_be_retried(server):
    admin, token, _, col = setup(server)
    fields = col["schema"]
    fields[0]["required"] = True
    fields[0]["options"]["max"] = 8
    status, body, _ = call(server, "PATCH", "/api/collections/posts", {**col, "fields": fields}, admin)
    assert status == 200, body
    path = "/api/collections/posts/records"
    ordinary = call(server, "POST", path, {}, token)
    keyed = call(server, "POST", path, {}, token, "validation-create")
    assert keyed[:2] == ordinary[:2]
    assert keyed[0] == 400 and keyed[1]["code"] == "validation_failed", keyed
    assert "title" in keyed[1]["data"]
    valid = call(server, "POST", path, {"title": "valid"}, token, "validation-create")
    assert valid[0] == 201, valid
    target = path + "/" + valid[1]["id"]
    ordinary_update = call(server, "PATCH", target, {"title": "too-long-title"}, token)
    keyed_update = call(server, "PATCH", target, {"title": "too-long-title"}, token, "validation-update")
    assert keyed_update[:2] == ordinary_update[:2]
    assert keyed_update[0] == 400 and "title" in keyed_update[1]["data"]
    assert call(server, "PATCH", target, {"title": "fixed"}, token, "validation-update")[0] == 200


@pytest.mark.parametrize("body", [b'{"ignored":true}', b'not-json'])
def test_keyed_delete_refuses_nonempty_body_without_consuming_key(server, body):
    import urllib.error
    import urllib.request

    admin, token, _, _ = setup(server)
    path = "/api/collections/posts/records"
    status, record, _ = call(server, "POST", path, {"title": "retained"}, token)
    assert status == 201, record
    target = path + "/" + record["id"]
    req = urllib.request.Request(server + target, data=body, method="DELETE", headers={
        "Authorization": f"Bearer {token}", "Idempotency-Key": "delete-body",
        "Content-Type": "application/json",
    })
    with pytest.raises(urllib.error.HTTPError) as failure:
        with urllib.request.urlopen(req, timeout=10):
            pass
    assert failure.value.code == 400
    failure.value.close()
    assert call(server, "GET", target, token=admin)[0] == 200
    assert call(server, "DELETE", target, token=token, key="delete-body")[0] == 204
    assert call(server, "DELETE", target, token=token, key="delete-body")[0] == 204


def _keyed_raw(base, method, path, data, token, key, account):
    """A keyed write in an active account, returning (status, raw body bytes)."""
    import json
    import urllib.error
    import urllib.request
    headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": key, "X-Account-Id": account,
               "Content-Type": "application/json"}
    req = urllib.request.Request(base + path, data=json.dumps(data).encode(), headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read()


def test_keyed_relation_to_another_account_answers_like_a_missing_id(binary, tmp_path):
    """#497 on the receipt path: a keyed create/PATCH naming another account's record in a relation
    to a tenant-owned collection gets the same 400 bytes as a never-minted id."""
    import json
    import sqlite3
    import subprocess
    from conftest import _reserve_port, _stop_server, _wait_reachable_or_fail
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZIGBASE_")}
    env.update(ZIGBASE_DATA_DIR=str(tmp_path), ZIGBASE_SERVE_BACKGROUND="0")
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io", "--password", "adminpassword"],
                   env=env, check=True, capture_output=True, timeout=30)
    with _reserve_port() as port:
        log_path = tmp_path / "server.log"
        with log_path.open("wb") as log:
            proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env={**env, "ZIGBASE_HTTP_PORT": str(port)},
                                    stdout=log, stderr=subprocess.STDOUT)
        try:
            _wait_reachable_or_fail(proc, port, str(log_path))
            base = f"http://127.0.0.1:{port}"
            admin, token, user, _ = setup(base)
            rules = {k: '@request.auth.id != ""' for k in ("listRule", "viewRule", "createRule", "updateRule", "deleteRule")}
            text = lambda n: {"id": "", "name": n, "type": "text", "options": {}}
            tenant = {"type": "base", **rules, "options": {"tenant": {"field": "account"}}}
            status, notes, _ = call(base, "POST", "/api/collections", {"name": "notes", "fields": [text("account")], **tenant}, admin)
            assert status == 201, notes
            rel = lambda n, m: {"id": "", "name": n, "type": "relation", "options": {"targetCollectionId": notes["id"], "maxSelect": m}}
            status, tasks, _ = call(base, "POST", "/api/collections",
                                    {"name": "tasks", "fields": [text("account"), text("title"), rel("note", 1), rel("notes", 5)], **tenant}, admin)
            assert status == 201, tasks
            with sqlite3.connect(tmp_path / "data.db") as db:
                for account in ("acct-a", "acct-b"):
                    db.execute("INSERT INTO _accounts(id,created,updated,slug) VALUES(?,?,?,?)", (account, "t", "t", account))
                db.execute("INSERT INTO _memberships(id,created,updated,account,user_collection,user,role,status) VALUES(?,?,?,?,?,?,?,?)",
                           ("member-a", "t", "t", "acct-a", "users", user["id"], "owner", "active"))
                db.execute("INSERT INTO notes(id,created,updated,account) VALUES('ownnote00000001','t','t','acct-a'),('foreignnote0001','t','t','acct-b')")
            own, foreign, missing = "ownnote00000001", "foreignnote0001", "zzzzzzzzzzzzzz9"
            path = "/api/collections/tasks/records"
            created = _keyed_raw(base, "POST", path, {"note": own, "notes": [own]}, token, "rel-own", "acct-a")
            assert created[0] == 201, created
            target = path + "/" + json.loads(created[1])["id"]
            for field, bad, absent in (("note", foreign, missing), ("notes", [own, foreign], [own, missing])):
                for method, where in (("POST", path), ("PATCH", target)):
                    as_foreign = _keyed_raw(base, method, where, {field: bad}, token, f"rel-{method}-{field}-f", "acct-a")
                    as_missing = _keyed_raw(base, method, where, {field: absent}, token, f"rel-{method}-{field}-m", "acct-a")
                    assert as_foreign[0] == 400, as_foreign
                    assert json.loads(as_foreign[1])["data"][field]["code"] == "validation_not_found", as_foreign
                    assert as_foreign == as_missing, (method, field, as_foreign, as_missing)

            # A superuser can seed legacy cross-tenant links. Readers may resend
            # those ids with a key just as on ordinary PATCH; non-readers may not.
            status, legacy, _ = call(base, "POST", path,
                                     {"account": "acct-a", "note": foreign, "notes": [own, foreign]}, admin)
            assert status == 201, legacy
            legacy_target = path + "/" + legacy["id"]
            for rule_index, (view_rule, readable) in enumerate((
                ('@request.method = "GET" && @request.data.title = ""', True),
                (None, False),
                ('@request.method = "GET" && @request.data.title = "grant"', False),
            )):
                status, body, _ = call(base, "PATCH", "/api/collections/tasks",
                                       {**tasks, "fields": tasks["schema"], "viewRule": view_rule}, admin)
                assert status == 200, body
                for field, stored, absent in (("note", foreign, missing),
                                               ("notes", [own, foreign], [own, missing])):
                    key = f"legacy-{rule_index}-{field}"
                    payload = {field: stored, "title": "grant"}
                    result = _keyed_raw(base, "PATCH", legacy_target, payload, token, key, "acct-a")
                    if readable:
                        assert result[0] == 200, result
                        assert json.loads(result[1])[field] == stored
                        assert _keyed_raw(base, "PATCH", legacy_target, payload, token, key, "acct-a") == result
                    else:
                        assert result[0] == 400, result
                        assert json.loads(result[1])["data"][field]["code"] == "validation_not_found", result
                        assert result == _keyed_raw(base, "PATCH", legacy_target,
                                                    {field: absent, "title": "grant"}, token, key + "-missing", "acct-a")
        finally:
            _stop_server(proc)
