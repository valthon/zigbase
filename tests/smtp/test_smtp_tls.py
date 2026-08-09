"""LIVE end-to-end SMTP-over-TLS smoke test for ZigBase's SmtpMailer.

This is NOT a mock. It stands up a real local SMTP server (aiosmtpd) that
advertises STARTTLS with a self-signed cert, boots a real `zigbase serve`
process configured to deliver mail via that server over STARTTLS, then drives
the HTTP API to trigger an actual email send and asserts the message was
received over the TLS-upgraded connection (envelope, recipient, body token, and
that the session was actually encrypted via STARTTLS).

Flow:
  aiosmtpd STARTTLS server (self-signed cert)  +  zigbase serve (SMTP=starttls,
  insecure_skip_verify=true) -> superuser created with a known email ->
  POST /api/collections/_superusers/request-password-reset {email} ->
  zigbase mints a reset token and the SmtpMailer connects plaintext -> EHLO ->
  STARTTLS -> TLS handshake -> AUTH-less MAIL/RCPT/DATA over TLS -> our handler
  captures the message. We assert the recipient matches, the body carries the
  password-reset token text, and session.ssl was set (proving STARTTLS ran).
"""
import os
import pathlib
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import pytest
from aiosmtpd.controller import Controller
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]

SUPERUSER_EMAIL = "admin@smtp-test.local"
SUPERUSER_PASSWORD = "adminpassword"


def _free_ports(n):
    """Reserve `n` DISTINCT loopback ports.

    Every socket is held open until all `n` ports have been chosen, then they are
    closed together. Choosing them one at a time — bind(0), read the number, close,
    repeat — hands the port straight back to the ephemeral pool, so two back-to-back
    calls can legitimately return the SAME number. When that happened here, the SMTP
    server and the HTTP server were pointed at one port: aiosmtpd bound it, zigbase's
    bind failed, and the test's POST reached the SMTP listener, surfacing three steps
    later as `BadStatusLine: 220 ... Python SMTP`. Holding the sockets removes the
    duplicate outright rather than making it rarer.
    """
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")


def _make_self_signed_cert(certdir):
    """Generate a self-signed cert/key for 127.0.0.1 via openssl."""
    cert = os.path.join(certdir, "cert.pem")
    key = os.path.join(certdir, "key.pem")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key, "-out", cert, "-days", "1", "-nodes",
            "-subj", "/CN=127.0.0.1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return cert, key


class CaptureHandler:
    """aiosmtpd handler that records every received message + whether the
    session was TLS-encrypted at the time of receipt (i.e. STARTTLS ran)."""

    def __init__(self):
        self.messages = []  # list of dicts: peer/mailfrom/rcpts/data/was_tls

    async def handle_DATA(self, server, session, envelope):
        self.messages.append(
            {
                "mailfrom": envelope.mail_from,
                "rcpts": list(envelope.rcpt_tos),
                "data": envelope.content.decode("utf-8", "replace"),
                # session.ssl is the SSLObject after a successful STARTTLS
                # upgrade; None over plaintext. Proves the body arrived over TLS.
                "was_tls": session.ssl is not None,
            }
        )
        return "250 Message accepted for delivery"


def _start_smtp_server(handler, port, cert, key):
    """Start an aiosmtpd Controller that advertises STARTTLS using the
    self-signed cert. require_starttls=False so EHLO works plaintext and the
    client may upgrade via the STARTTLS verb."""
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(certfile=cert, keyfile=key)
    controller = Controller(
        handler,
        hostname="127.0.0.1",
        port=port,
        # **kwargs below are forwarded to the aiosmtpd.smtp.SMTP class; passing
        # a tls_context makes the server advertise + accept the STARTTLS verb.
        tls_context=tls_context,
        require_starttls=False,
    )
    controller.start()
    return controller


def _wait_port(port, timeout=20):
    """Wait until something accepts TCP on `port` (used for the SMTP listener)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def _wait_http(port, timeout=20):
    """Wait until `port` answers HTTP — not merely accepts a TCP connection.

    A bare connect is satisfied by ANY listener, so when the HTTP and SMTP roles
    collided on one port this guard passed while zigbase had in fact failed to bind,
    and the real problem only surfaced later as an unexplained `BadStatusLine`.
    Requiring an HTTP status line makes the guard fail at the point of failure.
    An HTTP error response still proves an HTTP server is listening.
    """
    deadline = time.time() + timeout
    url = f"http://127.0.0.1:{port}/api/health"
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=0.5):
                return True
        except urllib.error.HTTPError:
            return True
        except Exception:
            time.sleep(0.1)
    return False


def test_smtp_starttls_delivery(binary):
    handler = CaptureHandler()
    smtp_port, http_port = _free_ports(2)
    data = tempfile.mkdtemp(prefix="zb_smtp_")
    certdir = tempfile.mkdtemp(prefix="zb_smtp_cert_")
    controller = None
    proc = None
    try:
        cert, key = _make_self_signed_cert(certdir)

        # 1) Local STARTTLS SMTP server with the self-signed cert.
        controller = _start_smtp_server(handler, smtp_port, cert, key)
        assert _wait_port(smtp_port), "aiosmtpd did not come up"

        # 2) Superuser with a known email, then boot `zigbase serve` pointed at
        #    the local SMTP server over STARTTLS (insecure: self-signed cert).
        subprocess.run(
            [
                binary, "superuser", "create",
                "--email", SUPERUSER_EMAIL,
                "--password", SUPERUSER_PASSWORD,
                "--data-dir", data,
            ],
            check=True,
        )
        env = {
            **os.environ,
            # Foreground pin: keep serve a foreground child so terminate() stops it
            # (an inherited agent env like CLAUDECODE would otherwise auto-background
            # it and leak the detached child past the test).
            "ZIGBASE_SERVE_BACKGROUND": "0",
            # >= 32 bytes: the server now refuses a shorter operator-provided secret.
            "ZIGBASE_JWT_SECRET": "test-secret-not-default-0123456789abcdef",
            "ZIGBASE_DATA_DIR": data,
            "ZIGBASE_HTTP_PORT": str(http_port),
            "ZIGBASE_SMTP_HOST": "127.0.0.1",
            "ZIGBASE_SMTP_PORT": str(smtp_port),
            "ZIGBASE_SMTP_FROM": "noreply@test.local",
            "ZIGBASE_SMTP_TLS": "starttls",
            "ZIGBASE_SMTP_INSECURE": "true",
            # No AUTH: leave username/password empty; the mailer only does AUTH
            # LOGIN when a username is set, and our server requires no auth.
            "ZIGBASE_SMTP_USERNAME": "",
            "ZIGBASE_SMTP_PASSWORD": "",
            "ZIGBASE_RATE_LIMIT_MAX": "1000",
        }
        proc = subprocess.Popen([binary, "serve"], env=env)
        assert _wait_http(http_port), "zigbase serve did not answer HTTP"

        # 3) Trigger a real send: request a password reset for the superuser's
        #    email. The email EXISTS, so the handler reaches deliverToken ->
        #    SmtpMailer.send over STARTTLS.
        url = f"http://127.0.0.1:{http_port}/api/collections/_superusers/request-password-reset"
        body = ('{"email":"%s"}' % SUPERUSER_EMAIL).encode()
        req = urllib.request.Request(
            url, data=body, method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            status = r.status
        # Endpoint always returns 204 (no account enumeration); the real proof
        # is the captured message below.
        assert status == 204, f"unexpected status {status}"

        # 4) Wait for the message to land (the SMTP send is async w.r.t. HTTP).
        deadline = time.time() + 15
        while time.time() < deadline and not handler.messages:
            time.sleep(0.1)

        assert handler.messages, (
            "no message received over SMTP — the SmtpMailer did not deliver "
            "over STARTTLS (this would be a REAL SMTP-TLS delivery bug)"
        )
        msg = handler.messages[0]
        assert msg["was_tls"], (
            "message was received but session was NOT TLS-encrypted — STARTTLS "
            "upgrade did not happen"
        )
        assert SUPERUSER_EMAIL in msg["rcpts"], (
            f"recipient mismatch: {msg['rcpts']}"
        )
        assert msg["mailfrom"] == "noreply@test.local", (
            f"envelope from mismatch: {msg['mailfrom']}"
        )
        # The reset email body carries the password-reset token text; assert the
        # full DATA (headers + body) was delivered over the TLS leg.
        assert "password-reset token" in msg["data"], (
            f"reset token text missing from delivered body:\n{msg['data']}"
        )
        assert "Subject: Reset your password" in msg["data"], (
            f"subject header missing from delivered message:\n{msg['data']}"
        )
    finally:
        if proc is not None:
            try:
                proc.send_signal(signal.SIGINT)
            except Exception:
                pass
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                proc.wait(timeout=10)
            except Exception:
                proc.kill()
        if controller is not None:
            try:
                controller.stop()
            except Exception:
                pass
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(certdir, ignore_errors=True)
