# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
