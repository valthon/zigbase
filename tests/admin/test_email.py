from conftest import login, api_request


def test_email_view_renders_tabs_and_policy(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    # policy strip fetched from GET /api/mail/config
    page.wait_for_selector('[data-test=mailcfg-webhook]')
    # three tabs present
    for t in ("senders", "suppressions", "batches"):
        assert page.locator(f'[data-test=email-tab-{t}]').count() == 1


def test_email_senders_invite_and_delete(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-senders]')
    page.fill('[data-test=sender-invite-email]', "from@example.com")
    page.click('[data-test=sender-invite]')
    page.wait_for_function("[...document.querySelectorAll('[data-test=sender-row]')].some(r => r.textContent.includes('from@example.com'))")
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=sender-row]:has-text("from@example.com") [data-test=sender-delete]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=sender-row]')].some(r => r.textContent.includes('from@example.com'))")


def test_email_suppressions_add_filter_remove(page):
    login(page)
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-suppressions]')
    page.wait_for_selector('[data-test=suppressions-tab]')
    page.fill('[data-test=suppression-add-email]', "bad@example.com")
    page.select_option('[data-test=suppression-add-reason]', "complaint")
    page.click('[data-test=suppression-add]')
    page.wait_for_function("[...document.querySelectorAll('[data-test=suppression-row]')].some(r => r.textContent.includes('bad@example.com'))")
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=suppression-row]:has-text("bad@example.com") [data-test=suppression-remove]')
    page.wait_for_function("![...document.querySelectorAll('[data-test=suppression-row]')].some(r => r.textContent.includes('bad@example.com'))")


def test_email_batches_list_and_progress(page):
    login(page)
    # The records API ignores a client-supplied "id" on create (it always
    # generates its own), so seed via the real id from the create response
    # rather than a hardcoded one.
    batch = api_request(page, "POST", "/api/collections/_mail_batches/records",
                         {"queue": "emails", "subject_tpl": "Hi Batch", "total": 2, "status": "active"}).json()
    api_request(page, "POST", "/api/collections/_mail_batch_recipients/records",
                {"batch": batch["id"], "email": "a@x.io", "status": "sent"})
    api_request(page, "POST", "/api/collections/_mail_batch_recipients/records",
                {"batch": batch["id"], "email": "b@x.io", "status": "pending"})
    page.goto("/_/#/email")
    page.wait_for_selector('[data-test=email-view]')
    page.click('[data-test=email-tab-batches]')
    page.wait_for_selector('[data-test=batch-row]')
    page.click('[data-test=batch-row]:has-text("Hi Batch")')
    page.wait_for_selector('[data-test=batch-progress]')
    prog = page.inner_text('[data-test=batch-progress]')
    assert "sent" in prog and "1" in prog
