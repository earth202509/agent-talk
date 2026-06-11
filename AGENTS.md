# Codex Project Notes

This repository is the source of truth for the standalone `agent-talk` skill.

## Workflow

- Edit skill source under `src/`.
- Run tests with:
  ```powershell
  .\tests\run-tests.ps1
  ```
- Deploy with:
  ```powershell
  .\scripts\deploy-skills.ps1
  ```
- Skip a target with `-SkipCodex`, `-SkipClaude`, `-SkipGemini`, or `-SkipPi`.
- Do not edit installed skill directories directly except for emergency runtime
  debugging; port durable changes back into this repository.

## Skill Rules

- `src/SKILL.md` must contain valid `name` and `description` frontmatter.
- Keep `SKILL.md` concise and move optional details into scripts or references only when
  they are truly useful.
- Do not commit runtime state. `src/state/` is runtime-only.

## Local Environment Notes

- On this Windows environment, do not try `rg`; use PowerShell `Get-ChildItem` and
  `Select-String`.
- Read text files with `Get-Content -Encoding UTF8`.
- Use `apply_patch` for manual file edits.
