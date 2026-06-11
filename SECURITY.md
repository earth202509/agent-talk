# Security Policy

## Reporting a Vulnerability

Please do not open a public issue for suspected vulnerabilities.

Report security concerns privately to the repository maintainer. Include:

- A description of the issue and impact.
- Steps to reproduce.
- Affected versions or commits, if known.
- Any relevant logs with secrets removed.

The maintainer will acknowledge the report, investigate, and coordinate a fix
before public disclosure when appropriate.

## Scope

This project controls local terminal sessions and may send text to local agent
CLIs. Treat local logs, session state, prompts, and agent output as potentially
sensitive.

Do not commit runtime files from `src/state/` or logs that contain private
workspace data, credentials, or proprietary prompts.
