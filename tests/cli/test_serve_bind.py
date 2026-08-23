"""`--http-host` / `ZIGBASE_HTTP_HOST` must reach the listening socket (#384).

The bug these cover was invisible for a reason: the host was parsed, echoed in
`zigbase listening on http://…`, recorded in `serve.json`, and graded by
`doctor` — everything except handed to the listener, which bound every
interface. Any test that trusted the log line, the status JSON, or a loopback
health probe agreed with the bug.

So these assert the *bound* address, the only witness the bug could not fake:
they dial a non-loopback address of this machine and require the answer to
differ with the configured host. `test_loopback_bind_is_refused_…` carries its
own control — the same address, same port, reachable under `0.0.0.0` and
refused under `127.0.0.1` — so a sandbox that simply cannot route to its own
LAN address fails the control and skips rather than passing vacuously.

Everything pure lives in `src/server.zig`'s `bindInterface` tests; what is here
is what only a real socket can prove.
"""
import socket

import pytest

from conftest import free_port, run


def _lan_ipv4():
    """A non-loopback IPv4 of this machine, or None.

    Uses a connectionless UDP socket to ask the routing table which local
    address would be used to reach a public address. Nothing is sent and no
    connectivity is required — only a default route.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))  # TEST-NET-1: reserved, never routed
        ip = s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()
    return None if ip.startswith("127.") else ip


def _connectable(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


@pytest.fixture()
def lan_ip():
    ip = _lan_ipv4()
    if ip is None:
        pytest.skip("no non-loopback IPv4 on this host; cannot observe a bind difference")
    return ip


def test_loopback_bind_is_refused_on_other_interfaces_but_wildcard_is_not(binary, data_dir, lan_ip):
    """The #384 regression, with its own control.

    Same address, same port, one data dir, two runs. Wildcard answers on the
    LAN address; the documented loopback default must refuse it.
    """
    port = free_port()

    # Control first: under an explicit wildcard the LAN address MUST answer. If it
    # does not, this host cannot observe the difference (no route to its own address,
    # a local firewall) and the assertion below would pass for the wrong reason.
    assert run(binary, "serve", "--background", "--insecure-cookies", "--data-dir", data_dir,
               "--http-port", str(port), "--http-host", "0.0.0.0").returncode == 0
    reachable_when_wildcard = _connectable(lan_ip, port)
    assert run(binary, "serve", "stop", "--data-dir", data_dir).returncode == 0
    if not reachable_when_wildcard:
        pytest.skip(f"{lan_ip}:{port} is not reachable even under a wildcard bind")

    # The real assertion: the documented default binds loopback ONLY.
    assert run(binary, "serve", "--background", "--insecure-cookies", "--data-dir", data_dir,
               "--http-port", str(port), "--http-host", "127.0.0.1").returncode == 0
    try:
        assert _connectable("127.0.0.1", port), "loopback bind did not answer on loopback"
        assert not _connectable(lan_ip, port), (
            f"--http-host 127.0.0.1 still answered on {lan_ip}:{port} — the host is being "
            "logged but not bound (#384)"
        )
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_explicit_interface_address_excludes_loopback(binary, data_dir, lan_ip):
    """The converse direction: binding one specific interface leaves loopback out.

    A bug that mapped every host to the wildcard would pass the test above's
    wildcard control and fail here.
    """
    port = free_port()
    assert run(binary, "serve", "--background", "--insecure-cookies", "--data-dir", data_dir,
               "--http-port", str(port), "--http-host", lan_ip).returncode == 0
    try:
        assert _connectable(lan_ip, port), f"bind to {lan_ip} did not answer there"
        assert not _connectable("127.0.0.1", port), (
            f"--http-host {lan_ip} also answered on loopback — the bind is not restricted"
        )
    finally:
        run(binary, "serve", "stop", "--data-dir", data_dir)


def test_unbindable_host_fails_at_boot_with_an_actionable_message(binary, data_dir):
    """Honouring the host means a host this machine has no address for is now a
    boot failure instead of a silent fallback to every interface. Fail fast, and
    name the address — `error.ListenError` alone does not tell an operator
    whether the port or the host was the problem."""
    port = free_port()
    # TEST-NET-1 (RFC 5737): reserved for documentation, never a local address.
    p = run(binary, "serve", "--background", "--insecure-cookies", "--data-dir", data_dir,
            "--http-port", str(port), "--http-host", "192.0.2.1")
    assert p.returncode != 0, "binding an address this machine does not have must not succeed"
    combined = p.stdout + p.stderr
    assert "cannot bind 192.0.2.1" in combined, combined
    assert "--http-host" in combined, combined
    assert not _connectable("127.0.0.1", port), "failed bind must not have fallen back to loopback"
