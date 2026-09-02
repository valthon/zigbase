import json, os, sys, uuid
from pathlib import Path
from playwright.sync_api import sync_playwright

handoff = json.loads((Path(__file__).resolve().parent.parent / "MIGRATION.handoff.json").read_text())
if handoff.get("schema_version") != 1 or not isinstance(handoff.get("parity"), list):
    raise SystemExit(f"unsupported migration handoff schema: {handoff.get('schema_version')}")
origin = os.environ.get("ZIGAPAGOS_ORIGIN", "").rstrip("/")
if not origin:
    raise SystemExit("ZIGAPAGOS_ORIGIN is required (run through `zigapagos e2e`)")
rows = handoff["parity"]
credentials = {}

def credential(collection):
    if collection not in credentials:
        nonce = uuid.uuid4().hex
        credentials[collection] = (f"parity+{nonce}@example.invalid", f"zigapagos-parity-{nonce}")
    return credentials[collection]

def wait_island(page):
    page.wait_for_selector("[data-z-island][data-z-hydrated]", timeout=10000)

def fill_fields(page, row, invalid=False):
    form = page.locator("form").last
    for field in row["expect"]["fields"]:
        value = field.get("invalid_value") if invalid and field["name"] == row["expect"].get("field") else field["value"]
        control = form.locator(f'[name={json.dumps(field["name"])}]')
        if control.get_attribute("type") == "checkbox":
            control.set_checked(str(value).lower() == "true")
        elif control.evaluate("el => el.tagName") == "SELECT":
            control.select_option(str(value))
        else:
            control.fill(str(value))
    return form
def consume_validation_console(errors):
    for index, message in enumerate(errors):
        if message.startswith("Failed to load resource:") and "status of 400" in message:
            errors.pop(index)
            return

def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page()
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204))
        for row in [r for r in rows if r["kind"] == "signup"]:
            try:
                email, password = credential(row["expect"]["collection"])
                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
                wait_island(page)
                page.locator('input[name="email"]').fill(email)
                page.locator('input[name="password"]').fill(password)
                page.locator('input[name="passwordConfirm"]').fill(password)
                with page.expect_navigation(wait_until="networkidle"):
                    page.get_by_role("button", name="Sign up").click()
            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
        for row in [r for r in rows if r["kind"] == "signin"]:
            try:
                email, password = credential(row["expect"]["collection"])
                page.goto(origin + "/", wait_until="networkidle")
                wait_island(page)
                signout = page.get_by_role("button", name="Sign out")
                if signout.count():
                    with page.expect_navigation(wait_until="networkidle"): signout.click()
                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
                wait_island(page)
                page.locator('input[name="email"]').fill(email)
                page.locator('input[name="password"]').fill(password)
                with page.expect_navigation(wait_until="networkidle"):
                    page.get_by_role("button", name="Sign in").click()
                page.get_by_role("button", name="Sign out").wait_for(timeout=10000)
            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
        for row in [r for r in rows if r["kind"] == "submit_allowed"]:
            try:
                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
                wait_island(page)
                form = fill_fields(page, row)
                form.get_by_role("button").click()
                page.get_by_text("Done.", exact=True).wait_for(timeout=10000)
            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
        for row in [r for r in rows if r["kind"] == "validation_error"]:
            try:
                page.goto(origin + row["expect"]["page_url"], wait_until="networkidle")
                wait_island(page)
                form = fill_fields(page, row, invalid=True)
                form.get_by_role("button").click()
                form.locator(".errors").get_by_text(row["expect"]["field"], exact=False).wait_for(timeout=10000)
                consume_validation_console(errors)
            except Exception as exc: raise AssertionError(f'{row["id"]}: {exc}') from exc
        assert not errors, f"console/page errors: {errors}"
        browser.close()
    print("PASS: Rails migration browser journey")

main()
