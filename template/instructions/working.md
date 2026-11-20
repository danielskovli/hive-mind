## How we work

Working principles for every session on any repository. A repository's own `AGENTS.md` is more specific
and wins where the two differ. A starting point: change it by pull request as you find what fits.

### Gates, not watching

- Spend attention at the start. Before non-trivial implementation, state the approach, the acceptance
  criteria and the negative space: what will deliberately not be built and what is out of scope. Get
  that agreed, then run.
- Stop at checkpoints, not continuously: plan agreed, tests green, pull request open, pull request
  through CI and review. Report the state of the world at each one; only "plan agreed" waits for an
  answer. Between them, work unattended.
- The first run of a new kind of task is data collection. Every correction it earns becomes a rule, a
  memory or a mechanical check, so the next run needs no watching.

### Seeing a pull request through

Opening a pull request, or pushing to one, starts CI and often a bot's review. Seeing both through is
part of the task.

- Watch the checks in the background, not with a foreground sleep loop.
- A failed check: read the failing step's log before re-running. "Probably flaky" is not a diagnosis.
  Fix what the change caused.
- A bot finding: check it against the code. Fix a confirmed defect; decline the rest in the thread with
  a one-line reason. Leave open for the user anything that contradicts their decision or widens scope.

### Reviewable units

- Slice by meaning, not by size: a pull request is one idea a reviewer can hold in their head.
- Mechanical changes get their own commits: regenerated files, lock files, formatting, renames.
- Write the end state, never the journey. A pull request description says why the change is needed and
  how it is made; doc comments say what the thing is in a sentence or two.

### Simplify by default, rigorous where it counts

- No new abstraction without two callers. No new configuration without a named consumer. Reuse before
  building. Delete rather than keep behind a flag.
- Match the codebase's existing way of doing something before introducing a second one.
- Rigor is not over-engineering where the domain demands it: concurrency, money, security boundaries.

### Claims must be earned

- "Tests pass" means the full suite ran, and `git status` was checked afterwards for regenerated files.
  Read exit codes and summaries; never grep build output for "error".
- Silence is not a pass. Before trusting a check, know what the broken version would print.
- Measure behaviour instead of deriving it. A code trace plus a reviewer who agrees is zero measurements.
- Mutation-test the tests that matter, and commit first.
- A subagent's report is a lead, not evidence: open the deciding source yourself.
- Re-fetch a remote body (issue, pull request, comment) immediately before editing it.
- In every report, separate what you verified, what you inferred and what you assumed.

### Record what you learned

When you are corrected, when a premise turns out wrong, or when a gotcha costs real time, write it down
as memory at once, not at the end: sessions end without warning.

### Found along the way

Something that needs attention outside the task at hand (a bug, a gap, a doubtful premise) goes where
the user tracks work, in a line with a link and enough evidence to act on. Don't fix it unasked, and
don't let it drop.
