"""
Admin UI tests for the Logs & realtime view (Phase 4).

Covers the realtime health strip (Task 2, from GET /api/realtime/stats) and the
events log (Task 3, filters + cursor pagination over GET /api/analytics/events).
The rollups viewer is a stub here, filled in by Task 4.

GATING (design pivot after the Task-3 probe): `/api/analytics/events` is comptime-gated
(R2-3 lean build) — unmounted (404) unless the app configures `.analytics`, which the
stock `zigbase` binary doesn't. Rather than showing a permanently-disabled Logs tab on
every stock deployment, `Shell` probes the endpoint once at mount and only shows the
`nav-logs` tab (and honors a `#/logs` deep-link) when it's actually enabled; otherwise a
stale `#/logs` link falls through to the default (collections) view, same as any unknown
route. So:
  - `test_logs_tab_hidden_when_analytics_disabled` runs against the stock binary and
    asserts the tab is absent and the deep-link falls through.
  - `TestLogsEnabled` runs against `full-fixture` (`.analytics = .{}`, same override
    pattern as test_features.py's features-fixture) — the tab is present, the strip
    renders, and the events log's filter/cursor machinery works against the real
    (empty, since nothing tracks an event in either binary) endpoint.
  - The seeded happy-path (rows actually populated, filtered by name/actor/since) is
    covered at the Zig level in src/analytics/api.zig, using `analytics.insertEvent`
    (the real ctx.track capture path) rather than a raw SQL INSERT — there's no
    browser-reachable action that tracks an event in either binary.
"""
import pathlib
import pytest
from _bin import resolve_binary
from conftest import login

REPO = pathlib.Path(__file__).resolve().parents[2]


def test_logs_tab_hidden_when_analytics_disabled(page):
    login(page)
    # Let the Shell's one-shot analytics probe settle before asserting the steady state.
    page.wait_for_load_state("networkidle")
    assert page.locator('[data-test=nav-logs]').count() == 0
    # A stale #/logs deep-link (e.g. bookmarked from an analytics-enabled deployment)
    # falls through to the default view rather than showing a broken tab.
    page.goto("/_/#/logs")
    page.wait_for_selector('[data-test=collections-home]')
    assert page.locator('[data-test=logs-view]').count() == 0


class TestLogsEnabled:
    """Runs against full-fixture (`.analytics = .{}`), which mounts the events route and
    therefore shows the Logs tab."""

    @pytest.fixture(scope="session")
    def binary(self):
        return resolve_binary("ZIGBASE_TEST_FULL_BINARY", REPO, "full-fixture")

    def test_nav_tab_present_and_strip_renders(self, page):
        login(page)
        page.wait_for_selector('[data-test=nav-logs]')
        page.click('[data-test=nav-logs]')
        page.wait_for_selector('[data-test=logs-view]')
        # realtime health strip from GET /api/realtime/stats
        page.wait_for_selector('[data-test=rt-connections]')
        assert "10000" in page.inner_text('[data-test=rt-caps]')  # max_connections cap

    def test_events_filters_and_pagination_controls(self, page):
        login(page)
        page.goto("/_/#/logs")
        page.wait_for_selector('[data-test=logs-view]')
        # events log renders its filter controls + table
        page.wait_for_selector('[data-test=events-log]')
        for t in ("logs-name", "logs-actor", "logs-since", "logs-apply"):
            assert page.locator(f'[data-test={t}]').count() == 1
        # no seeded events (no browser-reachable ctx.track) -> a genuine empty page
        page.wait_for_selector('[data-test=events-empty]')
        assert page.locator('[data-test=logs-more]').count() == 0
        # applying a filter re-fetches and doesn't crash
        page.fill('[data-test=logs-name]', "no_such_event_zzz")
        page.click('[data-test=logs-apply]')
        page.wait_for_selector('[data-test=events-empty]')
        assert page.locator('[data-test=logs-more]').count() == 0

    def test_logs_rollup_unknown_name_is_graceful(self, page):
        login(page)
        page.goto("/_/#/logs")
        page.wait_for_selector('[data-test=logs-view]')
        page.wait_for_selector('[data-test=rollups-viewer]')
        page.fill('[data-test=rollup-name]', "no_such_rollup_zzz")
        page.click('[data-test=rollup-load]')
        page.wait_for_selector('[data-test=rollup-none]')
