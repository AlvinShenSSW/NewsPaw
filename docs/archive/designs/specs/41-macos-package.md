# O02 / #41 — packaged macOS runtime and resident lifecycle

Closes #41

Build a movable native app with a private CPython, locked dependencies and compatible media helpers when supplied. The bundled launch agent uses Apple's per-user ServiceManagement, while the app shows the actual login-item approval and the independent backend state. Starting or stopping this service remains an explicit local action. The existing private socket and canonical agent lock exclude duplicate workers.

Upgrade preflight checks the actual database schema on an owner-private copy. The worker performs its own transactional migration before effects. Failed migration leaves the original schema in place, and a successful new schema stays with a compatible binary. Instructions cover separate data retention, legacy service handoff, signing and notarization.

The relocated package was tested using a restricted environment, a real private socket and disposable state. The same fixture rejected a duplicate worker and confirmed a graceful stop. Clean-user registration, logout and release notarization remain separate checks.
