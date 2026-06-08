# Acceptance Checklists

Cheap-worker output is a draft until the main brain accepts it. Each task type has its own
acceptance path so we don't smear one generic checklist across very different work.

The main brain's final answer must say which checklist it ran and what it found. Do not
declare a worker task "done" without naming the boxes that were checked.

## 1. Implementation Task

- [ ] Review the actual changed files when the task risk warrants it; worker-declared files
      are hints, not proof.
- [ ] No obvious edits outside the natural-language task request. If there are, keep only
      the useful ones and reject the rest.
- [ ] Boundary cases reviewed: empty input, null/None, error paths, off-by-one.
- [ ] At least one test exercises the new behavior. Run it.
- [ ] If a public function signature changed, find callers and check they still compile/run.
- [ ] No new TODOs / commented-out code / unused imports left behind.

## 2. Test-Writing Task

- [ ] Each test asserts on real behavior, not implementation detail (no asserts on log
      strings, no asserts on private internals unless the worker says so explicitly).
- [ ] Each test would fail if the feature is removed (negative-control check). The worker
      should report this in COMMANDS; otherwise run it locally.
- [ ] Failure paths covered, not just happy path.
- [ ] No over-mocking. Real dependencies preferred when fixture cost is reasonable.
- [ ] Tests are deterministic — no time-of-day, no network, no random seeds without pinning.

## 3. Refactor Task

- [ ] Behavior is unchanged. Pre-refactor and post-refactor tests both pass without
      modification of assertions.
- [ ] Public API surface unchanged unless the task said otherwise.
- [ ] Call sites still compile and behave the same.
- [ ] No accidental scope creep — naming, formatting, and unrelated reorganizations were
      deferred unless asked.

## 4. Log Analysis Task

- [ ] Every finding cites a specific line / file. No bare claims.
- [ ] Facts (from log), inferences (from context), and recommendations are kept separate —
      typically `SUMMARY` / `RISKS` / `NEXT`.
- [ ] No fabricated error messages. If a quoted line cannot be found, reject the finding.
- [ ] Recommendations are not executed by the worker; the main brain decides what to act on.

## 5. Design Review Task

- [ ] Tradeoffs listed, not just a recommendation.
- [ ] At least two alternatives considered, even if briefly.
- [ ] Recommendation is justified against the listed tradeoffs.
- [ ] Default is read-only. Any code change attached to a design review is rejected unless
      the task explicitly asked for one.

## Cross-cutting Checks (apply to every task)

- [ ] Worker reply was captured and kept short enough to review.
- [ ] Output is short. If the worker pasted a full file / long diff / long log, request a
      5-bullet rewrite before reading it.
- [ ] Worker's claimed `pass` in COMMANDS was actually checked, or marked unverified in the
      final report to the user.


