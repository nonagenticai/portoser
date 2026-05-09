# Contributing to Portoser

## Welcome

Thanks for your interest in Portoser! This project thrives on community contributions —
whether you're fixing a typo, filing a bug report, proposing a new feature, or shipping
a substantial pull request, your help is appreciated. This document explains how to get
set up and what we expect from contributors.

## Ground rules

- **Be respectful.** All interactions are governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
  Be kind, assume good faith, and disagree without being disagreeable.
- **Search existing issues and PRs first.** Someone may already be working on the same
  thing, or the question may have been answered. Avoid duplicates.
- **Keep PRs small and focused.** One logical change per PR. Large omnibus PRs are
  hard to review and often get stuck. If a change is big, open an issue first to discuss
  the approach.
- **Reach out early.** For non-trivial work, open an issue or discussion before writing
  code so we can align on direction.

## Dev environment setup

Portoser requires:

- **Python 3.12+**
- **Node.js 20+**
- **Bash 4+** (macOS users: install via `brew install bash` — the system bash 3.2 is too old)
- **Docker** (for the demo and integration tests)

Clone and bootstrap:

```bash
git clone https://github.com/nonagenticai/portoser.git
cd portoser
cp .env.example .env
```

For multi-host / cluster work, also copy the cluster configuration:

```bash
cp cluster.conf.example cluster.conf
# edit cluster.conf to match your environment
```

Install Python deps (backend lives in `web/backend/`):

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ./web/backend
pip install ruff pytest pytest-asyncio
```

Install frontend deps:

```bash
cd web/frontend
npm ci
```

For full install paths (single-machine demo, multi-host, from-source) see
[`INSTALL.md`](INSTALL.md).

## Running the test suite

Two suites — bash and Python — with one entry point each.

```bash
# Bash framework (lib/, registry parser, CLI). Auto-discovers tests/ files.
bash tests/run_tests.sh

# Python (FastAPI backend). Run from web/backend/ once deps are installed.
cd web/backend
pytest tests
```

The bash framework lives at `tests/framework.sh` — read it before adding new bash
tests so you understand the helpers (`assert_*`, `setup` / `teardown`). Both suites
must be green before you push.

## Lint and formatting

| Language | Tool | Config |
|---|---|---|
| Python | `ruff check` and `ruff format` | `pyproject.toml` |
| Shell | `shellcheck` | inline directives where needed |
| TypeScript / Web | `tsc --noEmit` and `vite build` | `tsconfig.json` / `vite.config.ts` |

Run all of these locally before opening a PR. CI will run them too, but catching issues
locally is faster.

## Branch naming

Use a short prefix that describes the kind of change:

- `feat/` — new functionality (e.g. `feat/multi-region-routing`)
- `fix/`  — bug fixes (e.g. `fix/cert-expiry-check`)
- `docs/` — documentation only (e.g. `docs/clarify-cluster-conf`)
- `chore/` — refactors, dependency bumps, tooling (e.g. `chore/bump-ruff-0.6`)

## Commit messages

- **Imperative mood, present tense.** `Add foo`, not `Added foo` or `Adds foo`.
- **Subject line ≤72 characters.** No trailing period.
- **Body wrapped at ~72 chars** if more context is needed. Explain the *why*, not just
  the *what* — the diff already shows the what.
- **Reference issues** in the body: `Fixes #123`, `Refs #456`.

## Pull request conventions

1. Link the related issue if one exists (`Fixes #N`).
2. Fill out the PR template completely — don't delete sections, mark them N/A if they
   don't apply.
3. Ensure CI is green before requesting review. Don't ask reviewers to babysit a red build.
4. Request review from a maintainer once the PR is ready. Mark drafts as draft.
5. Be responsive to review feedback. Push fix-up commits and squash-merge at the end.

## DCO sign-off

Portoser uses the [Developer Certificate of Origin](https://developercertificate.org).
By signing your commits, you certify that you wrote (or have the right to submit) the
contribution under the project's open-source license.

Sign each commit with:

```bash
git commit -s -m "Add foo"
```

This appends a `Signed-off-by: Your Name <your@email>` trailer. Configure `git config
user.name` and `git config user.email` correctly first. Unsigned commits will be flagged
by CI.

## Reporting bugs / requesting features

- **Bugs:** use the [Bug report](.github/ISSUE_TEMPLATE/bug_report.md) template.
- **Feature requests:** use the [Feature request](.github/ISSUE_TEMPLATE/feature_request.md) template.
- **Questions / discussion:** use GitHub Discussions, not Issues.

## Security issues

**Do not file public issues for security vulnerabilities.** See [SECURITY.md](SECURITY.md)
for the disclosure process. We follow coordinated disclosure and will credit reporters
who follow it.

---

Thanks again for contributing to Portoser!
