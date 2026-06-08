# Routing Policy

This file is natural-language policy for the main brain. Scripts do not parse it. Read it
when deciding whether to delegate work, which app to use, and how to phrase the worker
task. Update it when the user asks to remember a routing preference.

## Defaults

- Keep goal ownership, architecture, integration, verification, and final user
  communication in the current Codex session.
- Use workers for bounded tasks that are cheap to describe and easy to review.
- Prefer one economy worker at a time unless the work is clearly independent.
- Ask workers for compact reports: conclusions, relevant file paths or URLs, changed files,
  commands run, and risks. Avoid asking for full files, full diffs, or long logs.
- Treat worker output as a draft. The main brain must review results before accepting them.

## Worker App Preferences

- Economy worker: prefer app `pi`.
- Fallback economy worker: use app `antigravity`/`agy` when `pi` is unavailable or unsuitable.
- Quality worker: use app `claude` only when independent higher-quality reasoning is worth the
  coordination cost.
- Peer worker: use app `codex` only when a technical second pass is useful, not for cost saving.

## Common Routing Notes

- For codebase exploration across multiple files or unfamiliar areas, delegate a compact
  scan to an economy worker, then read only the reported files and line ranges locally.
- For large-file digestion, delegate the read-and-summarize work, then locally inspect the
  exact ranges before editing.
- For implementation tasks with a clear scope, an economy worker can draft changes. The main
  brain owns review, tests, and follow-up fixes.
- For code review, use a review-style prompt and ask for findings first, ordered by
  severity, with file and line references.
- For web research, prefer the app the user has most recently endorsed here. Ask for a
  compact digest plus source URLs.

## User Preferences

- Add durable user-specific routing preferences here as short bullets.


