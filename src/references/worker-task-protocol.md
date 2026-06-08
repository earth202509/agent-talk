# Worker Task Style

Worker prompts should be short prompts: natural-language instructions, not machine protocol blocks.
The main brain already knows the worker id, app, pane, current directory, and task
state. Do not repeat those fields in the prompt.

## Prompt Shape

Include only what helps the worker act:

- Task: the actual request, using relative paths when needed.
- Report request: ask for a brief note about the result and changed files.
- Length: no full files, no full diffs, no full logs. Ask for a short completion report,
  then let the main brain decide whether it is enough.

Example:

```text
创建或修改 src/worker-output.txt，内容包含 "worker e2e write test"。

完成后简短汇报结果并说明改了哪些文件。
```

## Examples

### Implementation Task

Ask for the concrete change in ordinary prose and a short report of changed files.

### Long Task

Long tasks must remain foreground and synchronous. Ask the worker to do the work and reply
only after it is actually complete. Do not ask the worker to create schedules, reminders,
background jobs, detached shell commands, or async helper processes that finish later.

Bad:

```text
Set a timer and report back later.
Start a background job and tell me it is running.
```

Good:

```text
Run the command in the foreground. Reply only after it completes, then summarize the result
and changed files.
```

### Test-Writing Task

Ask for focused tests in the target test file. The main brain decides whether the tests are
strong enough and whether a negative-control check is needed.

### Log Analysis Task

Ask for concise findings with file or line references. The worker should separate facts,
inferences, and recommendations in ordinary prose.

## Reply Handling

Worker replies are best-effort human reports. The worker does not need to return `TASK_ID`,
`STATUS`, `FILES_CHANGED`, or any other exact field name.

The main brain:

- associates the reply with the task using local worker state;
- saves the raw reply;
- extracts changed files, commands, summary, and risks when easy;
- treats missing structured fields as warnings, not failures;
- decides `accepted` / `rejected` from verification, not from worker wording.

## Parser

`scripts/parse_status_block.ps1` is now a best-effort extractor kept for compatibility with
older result files. It accepts natural replies, never requires `TASK_ID`, and emits JSON with
`summary`, `files_changed`, `commands`, `risks`, `next`, and `warnings`.


