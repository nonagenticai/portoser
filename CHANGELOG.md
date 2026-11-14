# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Root `src/` (the build API) now declares its own uv project (`pyproject.toml`,
  `uv.lock`), so its third-party imports resolve for tooling and for `uv run`.
  The tree is clean under ty 0.0.104: SQLAlchemy models moved to the 2.0
  `Mapped`/`mapped_column` style (generated DDL unchanged), pydantic validators
  to `field_validator`, and `datetime.utcnow()` to a helper that returns the
  same naive-UTC values.
- `web/backend`: fastmcp 4.2 / mcp 2.3. The two move together — `fastmcp-slim[client]` 4.x
  requires `mcp>=2.3,<3` — so the old `mcp<2` ceiling made every fastmcp upgrade
  unsatisfiable and the scheduled update job failed instead of proposing one. The backend
  only constructs `FastMCP(name=...)` and imports no `mcp` module directly.
- `web/backend`: `requires-python` bounded to `>=3.12,<3.15`. Unbounded, uv resolved the
  `python_full_version >= '3.15'` split as well, where the dependency graph has no
  solution, and the whole update job failed rather than skip an interpreter this project
  never runs (CI is 3.12, the image is 3.14).

### Security

- Cleared every critical and high Dependabot advisory in the locked dependency set.
  - `web/backend`: refreshed `uv.lock` (authlib 1.9.5, certifi 2026.10.23, cryptography 50.0.2,
    PyJWT 2.15.1, anyio 4.16.0, fastmcp 3.4.11, mcp 1.30.0, starlette 1.10.0, urllib3 2.8.0,
    fastapi 0.162.6).
  - Replaced `python-jose` with `PyJWT`, which was already a direct dependency. `python-jose`
    has no fixed release for the algorithm-confusion advisory, and it pulled in `ecdsa`, which
    has none either.
  - `demo/capture`: dropped `svg-term-cli`. It was the only runtime dependency of a
    Playwright-only harness and is not imported anywhere; its `xmldom` tree has no fixed
    release.

### Changed

- `dependabot.yml` tracks the backend as `uv` rather than `pip`, so updates resolve against
  the `uv.lock` that actually ships.

## [1.0.0] - 2026-11-13

First public release.
