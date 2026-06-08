# Failure Recovery Playbooks

Common failure modes for the Windows Terminal/ConPTY worker setup. Each playbook ends with a
state transition the main brain must record via `session_state.ps1 mark-status` when a
worker record exists.

When user or project instructions require `agent-talk`, an environment failure is not a
reason to bypass delegation. First repair the dependency/configuration problem or report a
clear blocker.

The public transport primitives these playbooks rely on:

- `talkie.ps1 new-session <app> <title>` — open or reuse a Windows
  Terminal tab running a ConPTY shim.
- `talkie.ps1 send <pane> <message>` — send a prompt through the named pipe.
- `talkie.ps1 interrupt <pane>` — send Escape to stop the current reply.
- `talkie.ps1 wait-reply <pane> [seconds] [interval]` — collect a reply
  after the TUI is idle.
- `talkie.ps1 list-sessions [tsv|json]` — inspect live worker handles.
- `talkie.ps1 kill-session <pane>` — close the Windows Terminal tab by its
  unique title.
- `session_state.ps1 mark-status -WorkerId <id> -Status <s> -Notes <why>`.
- `cleanup_workers.ps1` — reconcile stale state against live transport sessions.
- `send_to_worker.ps1` — validates the worker handle before sending; marks `failed` if not.

## 1. App Not Available

**Symptom:** the selected app cannot be resolved or its CLI is missing.

**Do:**

1. Use an app adapter name directly: `pi`, `claude`, `codex`, or `agy`/`antigravity`.
2. Run `Get-Command <app>` for the selected CLI and repair the install if it is missing.
3. If you chose the app, fall back to `pi` unless the task explicitly requires a different app.

**Status:** no worker was created, so no `session_state` entry to update.

## 2. Windows Terminal, ConPTY, Or Pi Missing

**Symptom:** transport fails before a worker tab is created, `wt.exe` is missing, the shim
cannot create a pseudoconsole, or `pi` is not found.

**Do:**

1. Run `talkie.ps1 _health-check`.
2. Check `Get-Command wt.exe`; install Windows Terminal if missing.
3. Check `Get-Command pi`; install or repair `pi` if missing.
4. Retry `new-session` once after fixing the missing dependency.

**Do not:**

- Use UI keyboard automation as a workaround.
- Use `SendInput` for worker prompts.

**Status:** no worker was created, so no `session_state` entry to update.

## 3. Worker Stuck

**Symptom:** `wait-reply` times out or the worker stays in `Working...` / `Thinking...`.

**Do:**

1. Run `talkie.ps1 wait-reply <pane> 20 2`.
2. If still busy, run `talkie.ps1 interrupt <pane>` or
   `talkie.ps1 interrupt <pane>`.
3. Mark the worker `failed` with a note such as `"task cancelled after wait timeout"`.
4. If the tab remains wedged, run `talkie.ps1 kill-session <pane>` and spawn a fresh worker.

**Do not:**

- Send increasingly long retry prompts.
- Read or paste full raw logs; use only the short tail needed to classify the failure.

## 4. Worker Edited Outside The Requested Task

**Symptom:** the worker report or your verification shows edits unrelated to the natural
language task request.

**Do:**

1. Read the diff for every out-of-scope file.
2. Keep only the useful out-of-scope edits; revert the rest with targeted edits.
3. Mark the worker `failed` with a note naming the out-of-scope file.

**Do not:**

- Trust the worker's claim that the edits were also needed. Verify.

## 5. Stale State

**Symptom:** `status` shows workers whose Windows Terminal tabs are gone.

**Do:**

1. Run `cleanup_workers.ps1`.
2. Prefer the wrapper over editing `sessions.json` by hand.

**Status:** the wrapper reports `LIVE_PANES / STATE_SYNCED / STATE_DROPPED`.

## 6. Permission Or App Setup Not In Effect

**Symptom:** the selected app cannot access the expected tools or account permissions.

**Do:**

1. Verify the app configuration outside the worker if needed.
2. Restart the worker with `talkie.ps1 kill-session <pane>` followed by a fresh `new-session`.
3. Mark the abandoned worker `failed` with a note such as `"respawned after app setup fix"`.

**Do not:**

- Manually approve prompts inside a worker as a substitute for fixing configuration.

## Cross-cutting

- Every recovery playbook ends with a `mark-status` when a worker record exists.
- If two playbooks could apply, prefer the more specific one first.
- If a failure does not match any playbook here, inspect state and run bounded
  `wait-reply`, then ask the user rather than inventing recovery.



