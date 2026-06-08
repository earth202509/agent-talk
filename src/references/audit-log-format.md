# Orchestration Audit Log Format

Every multi-worker orchestration round must append one entry to today's audit log via
`scripts/log_orchestration.ps1`. The log is the substrate for later routing decisions
("which task types is DeepSeek actually good at?", "did Claude Code earn its keep last
week?"). Without it, learning loops are guesswork.

## File Location

Default: `src/orchestration-log/YYYY-MM-DD.md` (relative to the
deployed skill). Override with the `-LogDir` parameter or `ORCHESTRATION_LOG_DIR` env var.

Each day's file starts with a single H1: `# Orchestration Log YYYY-MM-DD`. The helper
script creates the file with that header on the first write of the day.

## Entry Shape

Each entry is one H2 section followed by a flat bullet list:

```markdown
## HH:MM - <task_id> (<outcome>)

- worker: DS#1
- app: pi
- pane: 17
- accepted: true
- summary: <one-line of what was delegated>
- acceptance: <which checklist was run; what passed; what was left unverified>
- notes: <optional one-line context such as failed reason, write scope, cost, commands, or risk>
- claude_reason: <only when worker is CL#…; why Claude was justified>
- lessons: <one-line learning, optional>
```

Field rules:

- **Outcome** is one of `done | failed`, matching the simplified
  `session_state.ps1 mark-status` vocabulary so audits can be joined to state.
- **summary** is at most one line. Long descriptions live in the worker report, not here.
- **accepted** is the main brain's verdict, not a worker-declared status. Use `false` for
  failed acceptance, protocol failure, boundary mismatch, or unverified output.
- **acceptance** names the checklist from `references/acceptance-checklists.md` (e.g.
  "Implementation Task checklist; tests pass; out-of-scope review pending"). Empty means
  "no acceptance was performed", which itself is a finding.
- **notes** is optional one-line context for details that do not deserve first-class audit
  fields yet: write scope, commands, risk, review cost, failed reason, or routing signal.
- **claude_reason** is mandatory when the worker is a `CL#…` and forbidden otherwise — it
  is what Phase 5 demanded so Claude Code spend is auditable. Empty for cheap workers.
- **lessons** is the only freeform field. Use it to capture surprises ("DS#1 broke on
  glob-of-globs again"; "CL#1 sped up bug reasoning but missed the import"). Keep to one
  line.

## Helper Usage

```powershell
& "src\scripts\log_orchestration.ps1" `
    -TaskId 'impl-parser-001' `
    -Worker 'DS#1' `
    -App 'pi' `
    -PaneId '17' `
    -Outcome 'done' `
    -Summary 'extend csv parser to tolerate empty rows' `
    -Accepted true `
    -Acceptance 'Implementation Task checklist; pytest pass; out-of-scope review clean' `
    -Notes 'write_scope=src/parsers/csv.py; commands=pytest tests/parsers -q: pass' `
    -Lessons 'DS#1 still drops the trailing newline test unless explicitly listed in ACCEPTANCE'
```

Output (stdout):

```text
LOGGED=<absolute path to YYYY-MM-DD.md>
TASK_ID=<the id>
OUTCOME=<the outcome>
```

## When To Log

- **Always** after a worker reaches a terminal state (`done | failed`).
- **Always** after a Claude Code worker, even if cheap workers ran in parallel and were
  also logged — Claude Code spend must be traceable.
- **Never** for one-off helper calls that did not spin up a worker pane (those are not
  orchestration, they are direct execution).

## Periodic Review (manual)

When reviewing the log (weekly, after a big change, etc.), look for:

- Which `task_id` shapes succeeded with `pi` vs failed and had to be redone?
- Which failed entries recur, suggesting prompt-template or recovery weaknesses?
- Which `claude_reason` justifications turned out, in hindsight, not worth the cost?
- Which failure modes could have been auto-recovered by the playbooks in
  `references/failure-recovery.md`?

Findings update routing rules in `SKILL.md` and prompt templates in
`references/worker-task-protocol.md`. The log itself is append-only history.


