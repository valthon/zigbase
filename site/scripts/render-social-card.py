"""Render the code-authored social card using the site's browser-test dependency."""
from pathlib import Path
from playwright.sync_api import sync_playwright

site = Path(__file__).resolve().parents[1]
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1200, "height": 630}, device_scale_factor=1)
    page.goto((site / "scripts/social-card.html").as_uri())
    page.locator("header img").evaluate("img => img.decode()")
    page.screenshot(path=str(site / "assets/og-team.png"))
    browser.close()
