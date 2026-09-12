#!/usr/bin/env python3
"""Report-only SQLite upload-layout benchmark; no timing assertions.

Run with pinned tools: mise exec python@3.13 -- python tools/bench_upload_layout.py
Compiles this checkout's vendored SQLite with pinned Zig, never system sqlite3.
Measures the persistence SQL/blob sequence, not HTTP, RAM copies, or lock waiting.
Each case gets a fresh WAL database; output includes begin and per-chunk latency.
"""
import argparse
import ctypes as ct
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


def library(directory):
    root = Path(__file__).resolve().parents[1]
    output = directory / "sqlite.so"
    flags = [
        "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_DECLTYPE",
        "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_PROGRESS_CALLBACK",
        "-DSQLITE_OMIT_TRACE", "-DSQLITE_OMIT_SHARED_CACHE",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
    ]
    subprocess.run([
        "mise", "exec", "zig@0.16.0", "--", "zig", "cc", "-O2", "-shared",
        "-fPIC", *flags, str(root / "vendor/sqlite/sqlite3.c"),
        "-o", str(output), "-lpthread", *(["-ldl"] if sys.platform == "linux" else []), "-lm",
    ], check=True)
    lib = ct.CDLL(str(output))
    pointer = ct.c_void_p
    for name, args, result in [
        ("open", [ct.c_char_p, ct.POINTER(pointer)], ct.c_int),
        ("close", [pointer], ct.c_int),
        ("errmsg", [pointer], ct.c_char_p),
        ("libversion", [], ct.c_char_p),
        ("exec", [pointer, ct.c_char_p, pointer, pointer, pointer], ct.c_int),
        ("prepare_v2", [pointer, ct.c_char_p, ct.c_int, ct.POINTER(pointer), pointer], ct.c_int),
        ("step", [pointer], ct.c_int),
        ("column_int64", [pointer, ct.c_int], ct.c_int64),
        ("finalize", [pointer], ct.c_int),
        ("blob_open", [pointer, ct.c_char_p, ct.c_char_p, ct.c_char_p,
                       ct.c_int64, ct.c_int, ct.POINTER(pointer)], ct.c_int),
        ("blob_write", [pointer, pointer, ct.c_int, ct.c_int], ct.c_int),
        ("blob_close", [pointer], ct.c_int),
    ]:
        fn = getattr(lib, "sqlite3_" + name)
        fn.argtypes, fn.restype = args, result
    return lib


def measure(lib, path, size, chunk_size, split):
    db = ct.c_void_p()
    if lib.sqlite3_open(str(path).encode(), ct.byref(db)) != 0:
        raise RuntimeError("cannot open benchmark database")

    def check(result):
        if result != 0:
            raise RuntimeError(lib.sqlite3_errmsg(db).decode())

    def execute(sql):
        check(lib.sqlite3_exec(db, sql.encode(), None, None, None))

    def scalar(sql):
        statement = ct.c_void_p()
        check(lib.sqlite3_prepare_v2(db, sql.encode(), -1, ct.byref(statement), None))
        try:
            if lib.sqlite3_step(statement) != 100:  # SQLITE_ROW
                raise RuntimeError("missing benchmark row")
            return lib.sqlite3_column_int64(statement, 0)
        finally:
            check(lib.sqlite3_finalize(statement))

    try:
        execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
                "PRAGMA foreign_keys=ON; PRAGMA wal_autocheckpoint=2000;"
                "PRAGMA cache_size=-2000;")
        execute("CREATE TABLE sessions(id TEXT PRIMARY KEY,metadata TEXT NOT NULL,"
                "length INTEGER NOT NULL,offset INTEGER NOT NULL,expires INTEGER NOT NULL,"
                "state TEXT NOT NULL" + ("" if split else ",payload BLOB NOT NULL") + ");")
        if split:
            execute("CREATE TABLE payloads(rowid INTEGER PRIMARY KEY,session TEXT NOT NULL "
                    "UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,payload BLOB NOT NULL);")
        started = time.perf_counter_ns()
        execute("BEGIN IMMEDIATE;")
        values = f"'0123456789abcdef0123456789abcdef','{{}}',{size},0,100,'receiving'"
        execute("INSERT INTO sessions VALUES(" + values +
                ("" if split else f",zeroblob({size})") + ");")
        if split:
            execute("INSERT INTO payloads(session,payload) VALUES("
                    f"'0123456789abcdef0123456789abcdef',zeroblob({size}));")
        execute("COMMIT;")
        begin_ms = (time.perf_counter_ns() - started) / 1e6
        begin_wal_bytes = Path(str(path) + "-wal").stat().st_size
        chunk = ct.create_string_buffer(b"x" * chunk_size)
        elapsed = []
        for offset in range(0, size, chunk_size):
            length = min(chunk_size, size - offset)
            started = time.perf_counter_ns()
            execute("BEGIN IMMEDIATE;")
            row = scalar(("SELECT p.rowid FROM sessions s JOIN payloads p ON p.session=s.id"
                          if split else "SELECT rowid FROM sessions") +
                         f" WHERE offset={offset} AND state='receiving';")
            blob = ct.c_void_p()
            check(lib.sqlite3_blob_open(db, b"main", b"payloads" if split else b"sessions",
                                       b"payload", row, 1, ct.byref(blob)))
            try:
                check(lib.sqlite3_blob_write(blob, chunk, length, offset))
            finally:
                check(lib.sqlite3_blob_close(blob))
            execute(f"UPDATE sessions SET offset={offset + length} "
                    "WHERE id='0123456789abcdef0123456789abcdef'; COMMIT;")
            elapsed.append((time.perf_counter_ns() - started) / 1e6)
        started = time.perf_counter_ns()
        execute("BEGIN IMMEDIATE; UPDATE sessions SET state='committing'" +
                ("" if split else ",payload=CASE WHEN 1 THEN payload ELSE zeroblob(0) END") +
                "; COMMIT;")
        committing_ms = (time.perf_counter_ns() - started) / 1e6
        assert scalar("SELECT offset FROM sessions") == size
        return {"layout": "split" if split else "same-row", "upload_bytes": size,
                "chunk_bytes": chunk_size, "chunks": len(elapsed), "begin_ms": begin_ms,
                "begin_wal_bytes": begin_wal_bytes, "append_mean_ms": statistics.mean(elapsed),
                "append_max_ms": max(elapsed), "committing_ms": committing_ms}
    finally:
        check(lib.sqlite3_close(db))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes-mib", type=int, nargs="+", default=[8, 64])
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1 or not 1 <= args.chunk_kib <= 512 * 1024 or any(size < 1 or size > 512 for size in args.sizes_mib):
        parser.error("positive sizes/chunks/repeats required; uploads and chunks at most 512 MiB")
    with tempfile.TemporaryDirectory(prefix="zigbase-upload-layout-") as tmp:
        directory = Path(tmp)
        lib = library(directory)
        print(json.dumps({"sqlite": lib.sqlite3_libversion().decode(), "journal": "WAL",
                          "synchronous": "NORMAL", "cache_kib": 2000,
                          "wal_autocheckpoint": 2000, "scope": "SQL/blob sequence, not HTTP"}), flush=True)
        for repeat in range(args.repeats):
            for case, size in enumerate(args.sizes_mib):
                # Alternate order to reduce systematic cache/thermal bias.
                for split in ([False, True] if repeat % 2 == 0 else [True, False]):
                    path = directory / f"{repeat}-{case}-{size}-{split}.db"
                    result = measure(lib, path, size * 1024**2, args.chunk_kib * 1024, split)
                    print(json.dumps({"repeat": repeat + 1, **result}), flush=True)


if __name__ == "__main__":
    main()
