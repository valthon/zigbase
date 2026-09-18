import os
from pathlib import Path
from playwright.sync_api import sync_playwright

origin = os.environ["ZIGAPAGOS_ORIGIN"]
base = origin + "/zigbase"
shot_dir = os.environ.get("ZIGBASE_SCREENSHOT_DIR")
if shot_dir:
    Path(shot_dir).mkdir(parents=True, exist_ok=True)

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1280, "height": 900}, color_scheme="light")
    page.goto(base + "/")
    page.get_by_role("heading", name="Build beyond your team size.", exact=False).wait_for()
    page.get_by_role("link", name="Follow the tutorial", exact=True).click()
    assert page.url.endswith("/docs/tutorial/")
    page.goto(base + "/")
    page.get_by_role("link", name="Set up your agent", exact=True).click()
    assert page.url.endswith("/docs/agents/")
    page.goto(base + "/")
    if shot_dir:
        page.screenshot(path=str(Path(shot_dir) / "home-desktop.png"), full_page=True)
    page.get_by_role("button", name="Switch color theme").click()
    assert page.locator("html").get_attribute("data-theme") == "dark"

    page.get_by_role("link", name="Docs", exact=True).click()
    page.get_by_role("heading", name="Build your application. Understand your tools.").wait_for()
    page.goto(base + "/docs/api/")
    page.locator("#docs-filter").fill("PostgreSQL")
    assert page.get_by_role("link", name="PostgreSQL", exact=True).is_visible()
    assert page.get_by_role("link", name="Email", exact=True).is_hidden()

    for route, heading in [
        ("/download/", "Get ZigBase"),
        ("/examples/", "Three examples, one ladder"),
        ("/examples/golfsim/", "Golf simulator booking"),
        ("/compare/", "How ZigBase compares"),
        ("/docs/why-zigbase/", "Why ZigBase"),
        ("/docs/roadmap/", "Engineering backlog"),
    ]:
        response = page.goto(base + route)
        assert response and response.ok, route
        page.get_by_role("heading", name=heading, exact=False).first.wait_for()

    page.set_viewport_size({"width": 390, "height": 844})
    page.goto(base + "/")
    assert page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
    if shot_dir:
        page.screenshot(path=str(Path(shot_dir) / "home-mobile.png"), full_page=True)
    page.goto(base + "/docs/quick-start/")
    assert page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
    if shot_dir:
        page.screenshot(path=str(Path(shot_dir) / "docs-mobile.png"), full_page=True)
    page.keyboard.press("Tab")
    assert page.locator(":focus").count() == 1
    browser.close()

print("PASS: navigation, docs discovery, theme, representative routes, responsive keyboard smoke")
