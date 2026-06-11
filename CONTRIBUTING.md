# Contributing

Thanks for helping improve `agent-talk`.

## Development Setup

Use Windows with PowerShell and Windows Terminal available. Clone the repository
and run the test suite before opening a pull request:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Guidelines

- Edit durable skill source under `src/`.
- Keep runtime state out of commits.
- Use focused tests for reply extraction, adapter behavior, and deployment rules.
- Keep `src/SKILL.md` concise; place implementation details in scripts or
  references when possible.
- Avoid adding machine-specific paths or personal environment assumptions.

## Pull Requests

Please include:

- A brief summary of the change.
- The test command you ran and its result.
- Notes about any new environment variables, adapter behavior, or deployment
  changes.
