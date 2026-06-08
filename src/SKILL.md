---
name: agent-talk
description: >
  Local multi-agent communication for terminal-based coding agents via Windows
  Terminal and ConPTY. Use when the main brain needs to open a worker agent
  (pi, claude, codex, antigravity/agy), send it a task, wait for its reply,
  or manage its session lifecycle.
---

# Agent Talk

All operations go through `scripts/talkie.ps1` directly. The main brain:
- calls `new-session` to open a worker and receives a pane ID
- remembers the pane ID for the rest of the session
- uses the pane ID with `send`, `wait-reply`, `interrupt`, `kill-session`

Terminal implementation: `scripts/terminals/wt-conpty.ps1` uses Windows
Terminal + ConPTY + named pipes. New tab creation can briefly focus Windows
Terminal; all other operations do not depend on keyboard focus. Override with
`AGENT_TALK_TERMINAL_TOOL` to add another platform.

Session state is stored in `state/wt-conpty/sessions.json` with `session_id`,
`app`, `title`, `status` (`ready`, `busy`, `unknown`, `error`), and transport details.

## Core Workflow

1. Decide what stays local: goal ownership, integration, verification, and
   final user communication stay with the main brain.
2. Choose the worker app that fits the current task.
3. Open a worker — talkie waits until the session is ready before returning:
   ```powershell
   & $TALKIE new-session <app> "<title>"
   # → PANE=wtcc-xxxx  APP=<app>  READY=1
   ```
4. Send the task (base64-encode to avoid quoting issues):
   ```powershell
   $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($task))
   & $TALKIE send $pane "@base64:$enc"
   ```
5. Continue useful local work while the worker runs.
6. Collect the reply:
   ```powershell
   & $TALKIE wait-reply $pane 600
   ```
7. Review the actual diff and changed files before accepting the result.

## Commands

```powershell
$TALKIE = "<agent-talk-skill-dir>\scripts\talkie.ps1"

# Open a new worker session (blocks until ready).
& $TALKIE new-session <app> "<title>"

# Send a task.
& $TALKIE send $pane "@base64:$encodedTask"

# Wait for reply (default 60s; pass seconds as second arg).
& $TALKIE wait-reply $pane 600

# Check active sessions.
& $TALKIE list-sessions
& $TALKIE list-sessions tsv
& $TALKIE list-sessions json

# Stop the current reply without closing the session.
& $TALKIE interrupt $pane

# Close the session entirely.
& $TALKIE kill-session $pane

# Debugging — use only when something goes wrong, not in normal workflow.
& $TALKIE get-screen $pane       # read raw terminal output for debugging
```

`get-screen` returns the raw terminal buffer. Use it only when `wait-reply` returns
empty, a session is stuck in `unknown`, or you need to see exactly what the worker
is displaying. In normal operation always use `wait-reply` — it extracts only the
relevant response text and handles timing.

Supported app names: `pi`, `claude`, `codex`, `agy`/`antigravity`.

## Session Status

`list-sessions` and error messages from `send`/`wait-reply` surface one of four status values:

| Status    | Meaning | What to do |
|-----------|---------|------------|
| `ready`   | Agent is at its normal prompt, idle. | Send the next task with `send`. |
| `busy`    | Agent is working — `Working…` / `Thinking…` visible. | Call `wait-reply`; or `interrupt` then re-send to cancel and retry. |
| `unknown` | Agent is alive but in an unexpected interactive state (upgrade notice, add-trusted-directory dialog, confirmation prompt, etc.). | Call `get-screen`, read the output, and **autonomously** decide what to send — e.g. type `2` to skip an upgrade, `y` to confirm a trust-dir prompt. Then re-check status or proceed normally. No human intervention is required or expected. |
| `error`   | Infrastructure failure: process dead, log file missing, or output empty. | Call `kill-session` then open a fresh session with `new-session`. |

`unknown` is not a terminal state and does not require human help. The main brain handles it
by reading the screen and picking the appropriate response, the same way it would in any
interactive CLI.

## Review Standard

Worker output is a draft. For code changes, inspect the real diff, run relevant
tests, and keep goal ownership, integration, verification, and final user
communication in the main session.
