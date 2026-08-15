"""Browser proof for the Zigapagos frontend against the real blog binary."""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
BLOG = Path(os.environ.get("ZIGBASE_TEST_BLOG_BINARY", ROOT / "zig-out/bin/blog"))


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_until_ready(origin: str, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"blog exited before readiness: {process.returncode}")
        try:
            with urllib.request.urlopen(f"{origin}/api/health", timeout=1) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("blog did not become ready")


def main() -> None:
    port = free_port()
    origin = f"http://127.0.0.1:{port}"
    with tempfile.TemporaryDirectory(prefix="zigbase-blog-browser-") as data_dir:
        env = os.environ.copy()
        env["ZIGBASE_SERVE_BACKGROUND"] = "0"
        process = subprocess.Popen(
            [
                str(BLOG),
                "serve",
                "--http-host",
                "127.0.0.1",
                "--http-port",
                str(port),
                "--data-dir",
                data_dir,
                "--insecure-cookies",
                "--serve-static",
                str(ROOT / "frontend/dist"),
            ],
            cwd=ROOT,
            env=env,
        )
        try:
            wait_until_ready(origin, process)
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(headless=True)
                page = browser.new_page()
                page.goto(origin)
                page.locator("body").press("Tab")
                assert page.locator(".skip-link").evaluate(
                    "el => el === document.activeElement"
                )
                page.get_by_text("No posts yet").wait_for()

                page.get_by_role("link", name="✍ Write", exact=True).click()
                identity = time.time_ns()
                page.get_by_placeholder("email").fill(
                    f"magic-{identity}@blog.local"
                )
                page.get_by_role("button", name="Send magic link").click()
                page.get_by_role("heading", name="Check your email").wait_for()
                page.get_by_role("button", name="← Back").click()

                page.get_by_text("Sign in with password instead").click()
                page.get_by_placeholder("email").fill(
                    f"password-{identity}@blog.local"
                )
                page.get_by_placeholder("password (8+ chars)").fill("browser-pass-1")
                page.get_by_role("button", name="Sign up").click()
                page.get_by_role("heading", name="New post").wait_for()

                page.get_by_placeholder("Title").fill("Hello from Zigapagos")
                page.get_by_placeholder("Write your post…").fill(
                    "Published through the browser against the real ZigBase backend."
                )
                page.get_by_role("button", name="Publish").click()
                page.get_by_text("Published!").wait_for()
                page.get_by_role("link", name="View it").click()

                page.get_by_role("heading", name="Hello from Zigapagos").wait_for()
                page.get_by_text("Published through the browser").wait_for()
                page.get_by_role("link", name="ZigBase Blog").click()
                page.get_by_role("link", name="Hello from Zigapagos").wait_for()
                browser.close()
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
