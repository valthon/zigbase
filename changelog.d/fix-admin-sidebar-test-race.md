### Internal

- Fix a race in the admin browser test
  `test_shell.py::test_login_then_sidebar_lists_builtin_collections`: it counted
  the `nav-_superusers` sidebar link immediately after `login()`, but `login()`
  only waits for the static `nav-collections` link while the built-in-collection
  nav items render asynchronously just after — so the bare `count()` read 0 and
  the `browser` job flaked. It now waits for the selector before counting.
