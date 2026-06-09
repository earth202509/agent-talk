---
name: economy-delegate
description: Delegate selected task types to a configured low-cost worker agent.
variables:
  worker_app: local agent app
---

# Economy Delegate

Use this strategy to route expensive or clearly bounded work to the configured
economy worker.

## Variables

- `worker_app`: local agent app.

## Always Delegate

These task shapes are hard requirements, not options. Many are "read a lot,
report a little": the main brain would otherwise burn large amounts of context
ingesting raw material just to extract a small answer.

- **Large-file locate & digest.** When understanding or locating something in a large or
  unfamiliar file is open-ended ("where/how is X handled", "which lines change for Y"),
  delegate "read the file, report the relevant functions + exact line ranges + a short logic
  digest" to the economical worker. The main brain then does a narrow targeted read of only the
  reported lines.

- **Codebase exploration.** When the task involves scanning across multiple files or
  directories to answer an open-ended question ("which modules use X", "how does the data
  flow from A to B", "what's the project structure under dir/", "find all places that need
  changing for feature Y"), delegate the exploration to the economical worker. Ask for a
  compact map: file paths + line ranges + one-line role of each hit. The main brain then
  reads only the files and ranges that matter.

- **Web search / browsing.** Any web search or page browsing — including simple factual
  lookups like weather, prices, or version numbers — must be delegated to an economical
  worker. Ask for a compact digest plus source URLs. The main brain must never call
  WebSearch, WebFetch, or browser tools itself; it keeps only the conclusion and sources
  returned by the worker.

- **Git commit.** When the user asks to commit, delegate to a worker. The worker runs
  `git status`, `git diff`, `git log`, drafts the commit message, stages files, and commits.
  The main brain must never run git commit itself. No audit needed.

## May Delegate

These task shapes are discretionary. Delegate them when the main brain can describe the
requirement clearly and verify the result. If the work involves changes, the main brain must
be able to define a clear acceptance check before handing it to a worker.

- **Coding / feature implementation.** Specific modules or workflows are "describe precisely,
  implement broadly, verify narrowly" work. Good candidates include: frontend pages/views,
  backend endpoints, CLI commands, parsers/converters, import/export flows, data processing
  steps, config-driven behavior, integrations against a documented local interface, and
  focused refactors with observable behavior.
  - The prompt must include: the exact user-visible behavior, files or modules in scope,
    data schemas or examples (paste concrete JSON/input/output, not vague descriptions),
    required APIs or library parameters, edge cases, environment-specific warnings, and
    explicit prohibitions for known footguns.
  - The prompt must also define acceptance: which command(s) to run, which tests to add or
    update, what manual checks are expected, and what output/screenshot/result proves the
    work is done.
  - The main brain owns final verification. It reads the important changed code, runs the
    acceptance checks, inspects rendered or runtime behavior when relevant, and applies small
    fixes itself instead of delegating another pass.

- **Other high-cost tool work.** Non-coding work that would require multiple tool rounds or
  burn significant context may also be delegated after the main brain spells out the
  requirement and expected result.

## Main Brain Responsibilities

- Before delegating, write the requirement concretely enough that the worker does not need to
  infer product direction or acceptance criteria.
- Before any `Edit`, re-read the worker's reported line range to get the exact current text.
  Never use a worker's quoted excerpt as the `old_string`.
- After the worker reports back, run the acceptance checks, inspect the relevant output or
  behavior, and make small final fixes locally when that is cheaper than another delegation
  round.

## Keep Local

- A pinpoint lookup of a known symbol stays local: main-brain `Grep` for the line number plus
  `Read` with offset/limit is cheaper than briefing a worker.
- A single targeted search for a known symbol or pattern stays local.
- Reading a known URL that the main brain already has in hand stays local when the answer is
  one line. Keyword searches of any kind are never local.
- Tiny local edits, unclear product decisions, cross-cutting architecture choices,
  security-sensitive changes, and bugs whose root cause is not yet bounded stay local until
  the main brain has narrowed them into a concrete, testable task.
