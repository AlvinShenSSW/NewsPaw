# O03 / #42 — Offline checks and release evidence

## Spec review and frozen contract
The single-user product runs one backend on one Mac, serving multiple Telegram bots owned by the same user. This issue adds only offline validation infrastructure, not business features or distributed services. Preserve the accepted mockup. Source: issue #42, R10/R11, latest operator instruction. CI must never use real credentials, send Telegram messages, or incur model charges. Existing tests are prototype regression coverage, not acceptance of M1/M2.

Acceptance:
- Pull requests and main pushes run locked Python dependencies, Ruff, pytest, and package build on Linux and macOS; jobs fail on a failed command.
- Tests cannot accidentally open internet sockets; permit local Unix sockets used by asyncio/local IPC. DNS and internet connect/send paths fail before contacting a provider. Test transports remain mocked.
- CI has read-only repository permissions and no secrets or live-call job. Test guard removes inherited provider/Telegram credential variables and isolates implicit developer `.env` discovery by running tests in a temporary working directory; explicit `tmp_path` dotenv parsing remains enabled and its existing regression tests must still pass.
- A release checklist maps M1/M2 outcomes to their issue owners, with unimplemented/untested states explicit. Swift build/tests join the macOS check when U01 adds its package; absence now is a named pending item, not a successful Swift check.
- Manual live integration remains a separately documented, opt-in local procedure; no generic live execution framework is built now.

Non-goals: implement all E2E features today; signing credentials, deployment, scheduled workflows, cloud management, tenancy, custom CI orchestration, secret scanning framework. No production source changes.

## Approach and execution surface
Use one GitHub Actions workflow with two OS matrix entries, Python 3.12 and uv locked sync; existing pytest/Ruff commands and uv build. A small autouse fixture blocks internet networking during tests and isolates the working directory and credential inheritance without disabling explicit fixture config parsing. A dedicated regression verifies the guard itself using literal documentation IPs (blocked before connection), DNS, and local socketpair. The guard is a test accident barrier, not a sandbox against malicious test code/subprocesses; review remains responsible for explicit subprocess tests.

| Path | Allowed change | Purpose |
| --- | --- | --- |
| .github/workflows/checks.yml | add | offline CI matrix |
| tests/conftest.py, tests/test_offline.py | add | no accidental live API calls |
| docs/testing/README.md | add | commands, release checklist and live-test boundaries |
| AGENTS.md | append | operator's single-backend/single-user simplicity constraint |
| docs/designs/specs/42-ci-foundation.md | add | this contract |

Read/execute: pyproject.toml, uv.lock, existing tests, uv/pytest/Ruff/build, GitHub Actions official docs. Generated dist artifacts come from `uv build` with pyproject.toml/lock and are ignored; CI runner caches may contain packages only, never runtime DB/config/media. pytest writes only disposable tmp_path data. No service install or actual news fetch.

## Assumptions and risk
Repository Actions permissions were verified enabled with gh api; actual hosted-runner execution remains to verify. Official release tags/SHAs verified with gh api: checkout v7.0.1, setup-python v7.1.0, setup-uv v10.3.3 (pin those resolved SHAs in workflow). Packages download during installation; offline means test execution does not call product services. Guard is installed for each test before fixtures that load runtime config; collection-time network behavior is prohibited by convention and review. Future genuine localhost TCP tests must use an explicitly bounded fixture or Unix socket rather than disabling the guard globally.

## Test plan and handoff
First add a test proving outbound TCP, UDP, and DNS are rejected, plus Unix socketpair works, observe RED from a missing required guard fixture (so test bodies never run), without making an actual network call. Add fixture and run targeted tests, full existing suite/Ruff, package build. Inspect workflow trigger/permissions/fail propagation and observe real PR CI after review. Record unavailable Swift/product E2E as pending, add those checks with their implementing issues. Internal review then Kimi K3.1 Pro sole external gate, final suite on reviewed commit, remote check verification. Leave PR open under current policy.
