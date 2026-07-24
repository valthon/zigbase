### Internal

- Pinned `ruff==0.15.21` in the `python-sdk` CI job and the Python SDK release workflow's format/lint gates (matching the codegen job), so a floating `ruff>=0.8` release can no longer turn a green `main` red on a later PR without any code change — as happened when post-0.15.21 markdown code-block formatting reflowed `clients/python/README.md`.
