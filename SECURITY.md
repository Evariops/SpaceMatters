# Security Policy

## Supported versions

Only the latest release of MacDirStats is supported with security updates.

## Reporting a vulnerability

Please report vulnerabilities privately via
[GitHub private vulnerability reporting](https://github.com/rducom/MacDirStats/security/advisories/new).
Do not open a public issue for security problems.

You can expect an initial response within a week. Please include steps to
reproduce and the affected version (`git describe --tags`).

## Scope notes

MacDirStats is a local macOS disk-usage analyzer. It reads filesystem metadata,
may invoke local tools (`du`, `find`, container/Kubernetes CLIs) and can scan
remote hosts over SSH using your existing SSH configuration. It never sends
data anywhere else. Reports about privilege escalation, sandbox/TCC bypasses,
or command injection through scanned paths or remote output are especially
welcome.
