"""Socket helpers shared by realtime transport tests."""
import socket


def _recv_until(sock, needle: bytes, timeout=8.0) -> bytes:
    """Read from an already-open socket until `needle` appears or the peer closes/times out."""
    sock.settimeout(timeout)
    buf = b""
    while needle not in buf:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf
