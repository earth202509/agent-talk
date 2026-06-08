# Agent Talk Skill

Standalone source workspace for the `agent-talk` skill.

## Layout

- `src/` - skill source, scripts, and adapters.
- `tests/agent-talk.tests.ps1` - focused tests for reply extraction and adapter behavior.
- `scripts/deploy-skills.ps1` - deploys `agent-talk` to local agent skill directories.

Runtime state under `src/state/` is intentionally not committed or deployed.

## Commands

Run tests:

```powershell
.\tests\run-tests.ps1
```

Deploy:

```powershell
.\scripts\deploy-skills.ps1
```

Skip deployment targets:

```powershell
.\scripts\deploy-skills.ps1 -SkipClaude -SkipGemini -SkipPi
```
