---
name: consolidate-hive
description: Keep the hive small, current and honest. Modes - tidy (automatic and unattended - budget, reconcile two-version memories, retire stale ones, harvest this machine's transcripts, log it), harvest (this machine's transcripts only), retro (the user's grand review of everything agents derived since the last one, promotions, the Worklog backup), import (old per-project memories). Use when the hive starts a tidy or harvest, or when asked to consolidate, prune, review memory, run a retro, or import memories.
user-invocable: true
---

# Consolidate the hive

Memory accumulates during work and rots afterwards. This skill keeps it small, reconciled and true,
catches lessons sessions failed to write down, and moves what has outgrown memory to where it belongs.
Two loops run it:

- **Automatic.** The hive's session-start hook starts a headless session in **tidy** mode when the
  hive needs it (the index near its budget, a memory with two versions, a week without a tidy), at
  most once a day across all machines, and in **harvest** mode on the other machines. Nobody watches
  these; they change memory only, and log what they did for the retro.
- **The user's retro.** Now and then the user asks for a **retro**: a review, with them, of everything
  the agents derived on their own since the last one, and the decisions only they can make.

Knowledge moves in one direction, upward, and each layer is cheaper to trust than the one below:

| Layer | Holds | Loaded |
| --- | --- | --- |
| Repository `AGENTS.md` and docs | What any new developer needs to work there at all | Every session in that repository |
| The hive's `instructions/` and `skills/` | How we work; procedures | Every session / on invocation |
| The hive's `memory/` | Judgments and gotchas not yet general, or genuinely idiosyncratic | Index every session, files on demand |
| The hive's `decisions/` | What was decided about how we work, and why; retro logs, and tidy logs in `decisions/tidy/` | By this skill, and before re-deciding something |
| Transcripts | What was actually said and done, on one machine only | By harvests |

## Where things are

- The hive checkout: the prompt names it; otherwise
  `hive=$(cd "$(readlink ~/.claude/rules/hive)/.." && pwd)`. Memory is `$hive/memory/`. The core,
  with `bin/hive` and this skill, is `$hive/hive-mind`; `hive` on the PATH runs it.
- Transcripts: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/*.jsonl` on this machine. Skip the hive
  checkout's own project directory: those are tidy and harvest sessions.
- The last tidy and retro: the newest `decisions/tidy/*.md` and `decisions/*-retro.md`.
- Which memories sessions open: `hive usage [days]` (30 by default) counts, per memory,
  the sessions on every machine that read it, from each machine's records in `memory/.usage/` (this
  machine's brought up to date first). A memory whose index line carries the whole fact can earn its
  place without ever being opened.
- What rules cost: `hive costs [days]` lists, per rule, what sessions on every machine
  logged with `hive cost` (`memory/.costs/`): where following it cost something, a conflict, or why
  a default did not fit.
- The budget: `MEMORY.md` within 170 lines and 22,000 bytes, every index line within 180
  characters. A tidy becomes due at 90% of it. `hive index` enforces it by leaving memories out, which is the failure this skill
  prevents: past the budget, its last line says how many are missing.

Edit `memory/`, `decisions/` and `worklog/` in place; the hooks commit and push them. Never edit
`instructions/`, `skills/` or anything else in the checkout (a hook refuses it): changes there are
pull requests from a worktree, and only the retro opens them. Run `hive index` after
renaming, retiring or deleting memories.

## Retiring a memory

To forget a memory, don't delete it: under `metadata`, add `status: retired`, `retired: <today>` and
`why: <one line>`. The index leaves it out at once, and an edit another session makes at the same
moment cannot bring it back by accident. A tidy deletes memories retired more than 30 days ago.

## Tidy mode (automatic, unattended)

Work through these in order, and stop changing things once the budget holds and nothing has two
versions; the rest can wait for the next tidy, except steps 4 to 9, which every tidy runs. Never ask
questions: anything that needs the user goes into the log under "For the retro".

The tidy runs with an allowlist and refuses whatever it doesn't name, without asking. It names plain
commands (`git log …`, `git show …`, `gh pr view …`, `hive index`), so run each one on its own from the
hive checkout, the working directory: no `cd … &&`, `git -C`, pipes or `;`, which it refuses whole.

1. **Two versions.** For each file containing `<!-- hive:sibling -->`: merge the versions into
   one, keeping what each learned. `git log -p -- <file>` shows which side is newer. Where they
   contradict and you cannot tell which is right from the code or the history, keep the newer one,
   and note the other under "For the retro".
2. **Retired and stale.** Delete files retired more than 30 days ago. Retire memories whose substance
   is now in the instructions, a skill or a repository's `AGENTS.md` (read them to check), memories
   that state a status GitHub can give back (the PR merged, the release is out: check with `gh`), and
   duplicates (merge into the better file first, keeping the why from both).
3. **Budget.** Shorten descriptions that run past their index line: the description is a search key,
   not the content. Name the repository in every repository-specific description. If the index is
   still over 90% of its budget, merge memories on one subject into a topic file (one repository or
   tool each, a section per fact), then retire the least useful memories (those no session opened in 30 days
   by `hive usage`, unless the index line alone does the work, and those most specific to one
   finished task), and list each under "For the retro".
4. **Firmness.** Give each feedback memory without `firmness` one, judged from its text as
   the core's `instructions/hive.md` says ("Rule or default"): `rule` only where it quotes the user stating or
   confirming a rule; in doubt, `default`.
5. **Harvest.** Harvest this machine's transcripts since the time the prompt gives (see harvest mode).
6. **Claude Code drift.** Claude Code changes how it writes memory without notice; you are the one
   placed to notice, because its memory instructions are in your own system prompt. Run this step when
   no `## Claude Code <version>` heading in `decisions/tidy/` names the version the prompt gives, when
   the reasons say memory files use something no tidy has checked, or when the prompt lists keep-alive
   problems. In the log, under `## Claude Code <version>`:
   - Quote the memory instructions from your system prompt whole, in a fenced block, and say in a line
     or two what changed since the newest earlier quote in `decisions/tidy/` ("unchanged", or what).
   - Read the memory files added or changed since that quote (`git log`) for frontmatter keys, file
     names or places the hive does not expect.
   - Judge each change against how the hive uses memory: the core's `instructions/hive.md` ("Memory"), the
     index budget, and the sync's merge (`combine` in the core's `bin/hive`). A harmless change gets its line.
     For one that costs something, fix what you can in `memory/`, and add a bullet that starts
     `- Drift: ` saying what changed, what it costs and what would fix it: the next interactive
     session puts the log in the Worklog inbox, or tells the user.
   - Keep-alive problems, when the prompt lists them. The keep-alive ("The keep-alive" in `SETUP.md`)
     leans on `asyncRewake`, a hook option missing from Claude Code's public docs. `unsupported`: the
     Claude Code binary no longer names it, so the keep-alive is off under it. `miss`: a ping woke a
     session, but its turn wrote the context to the cache instead of reading it. The log the prompt
     names shows how earlier pings went. A known cause gets a line: usage overage cuts the cache's life
     to five minutes, and a model switch starts a new cache. A change in Claude Code gets a `- Drift: `
     bullet, as above.
   - End the section with `Memory shape: ` and the shape the prompt gives, exactly: the next sync
     compares new memory files against it.
7. **Candidates.** List, without acting on them: memories that are ready to promote (to which file,
   with the text you would add), memories marked `promote:`, memories that only hold in
   sandboxes (for `sandbox/host-instructions.md`), and memories that are really tasks (for the
   Worklog: you have no Worklog tools here).
8. **Upgrades.** Run `hive upgrade --pr`. It opens a pull request in the hive for every source whose
   repository has moved past its pin, updates the open one, or closes it when nothing is left. Its last
   line is `- Upgrade: <pull request URL> (<sources>)` while one is open, and `- Upgrade: closed <URL>`
   when it closed one. Copy that line into the log under `## Upgrade`, exactly: the next interactive
   session tells the user from the newest log's line, and only of one still open. Whatever else it
   prints (skipped for want of gh or a hive on GitHub, a source it could not read) goes under the same
   heading in a line; it never stops the tidy.
9. **Log.** Append to `decisions/tidy/<today>.md` (create it with the title `# Tidy, <today>`): why
   the tidy ran, what you merged, retired, deleted and shortened, and the rules you marked, each with
   its reason in a line;
   memories harvested, each with its session; the drift section; the upgrade section; the candidates; and "For the retro".
   Then `hive index`.

## Harvest mode (automatic, unattended)

Sessions end without recording what they learned: a usage limit, a detach, a sandbox deleted. The
corrections are still in this machine's transcripts. Print what people said, with the agent text each
message answered:

```sh
sh <this skill's directory>/scripts/recent-turns.sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" <hours>
```

Hours: since the time the prompt gives (Unix time; 0 means the last 168 hours). The script needs `jq`.

Look for **corrections** ("no", "don't", "we don't want X anywhere", a reverted approach), **stated
preferences** that will recur ("I review diffs in the PR, just push"), and **premises that turned out
wrong**. Skip instructions that only concern the task at hand ("commit this", "open a PR"), and
anything about the hive's own tidy and harvest sessions.

For each, check whether memory, the instructions, a skill or the repository's `AGENTS.md` already
covers it. Covered and consistent: nothing to do. Covered but contradicted by the newer turn: in
memory, update it; elsewhere, note it as a candidate. Not covered: write a memory, one fact per file or a section in the topic file for its subject,
quoting the person's words, with `verified: harvested from session <id> on <machine>, <date>` and, for
feedback, `firmness` as tidy step 4 says. In
harvest mode, add nothing else and log nothing: the retro finds harvested memories by that line.

## Retro mode (the user's, interactive)

The retro is where the user reviews what the agents derived on their own. Prepare everything before
asking anything, then go through it with them in this order, and apply what they decide.

Guide them; never show bare titles, which they can't judge. Go in batches of about ten items, grouped by
topic. Each item gets what it says in a sentence, where it came from (their words, an incident, a
measurement, with the date) and your recommendation in bold (keep, retire, make it a rule, promote).
Number the questions that need their decision and put them last. Head each message with where they are in
the whole, such as "Part 2, batch 3 of 7", counting the batches while you prepare. Apply their answers
before the next batch, and say in a line what changed.

1. **Since when.** The last `decisions/*-retro.md`; if there is none, the last 30 days.
2. **What the agents learned.** Every memory added, changed or retired since then (`git log --stat`
   on `memory/`; each commit's `Hive-Host` and `Hive-Session` trailers say where it came from),
   grouped by topic, and within it by where it came from: harvested, written in a session, or changed
   by a tidy. The user keeps, rewrites or retires each.
   Ask about each memory marked `firmness: rule` since then (did the user state it as one?), and about the
   defaults `hive usage` shows sessions opening most: those already act as rules. The user makes each a
   rule, keeps it a default, or retires it.
   Then `hive costs <days>`, over the days since then: for each rule or default with entries, show
   them and ask. The user may reword, narrow, keep or retire it, or reject the entries themselves.
3. **What the tidies did.** The tidy logs since then: their "For the retro" sections first, then
   anything retired for the budget.
4. **Promotions.** The candidates from the tidy logs and memories marked `promote:`. For each the
   user accepts: one pull request per concern, from a fresh worktree, following the target repository's
   conventions (the hive's own `instructions/`, `skills/` or `sandbox/host-instructions.md`, or a
   repository's `AGENTS.md`). Mark the memory `promoted: <PR URL>`; a later tidy retires it once the
   PR has merged.
5. **Decisions.** Each decision record since then: does a memory, an instruction or a skill act on
   it? One that nothing reflects is a gap to close now. One a newer decision contradicts without
   saying so is a question for the user.
6. **The Worklog,** where the hive has one. Refresh the backup in `worklog/` as the worklog-setup skill says (this session has the Worklog
   tools; automatic sessions do not). Look for patterns worth a memory or an instruction: work that
   keeps getting blocked on the same thing, tasks that never move.
7. **Health.** The index against its budget, files with two versions left, how old the backup is,
   and `hive usage` since the last retro: the memories sessions open most (candidates to promote)
   and those none opened (candidates to retire, or to describe better).
8. **Record.** Write `decisions/<today>-retro.md`: what the user decided in each part, the pull requests
   opened, and what is left open. It is where the next retro starts.

## Import mode

Read every file under `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/memory/` (the per-project memory
Claude Code kept before the hive). For each, decide as in tidy steps 2 and 3, and propose which to
bring into `$hive/memory/`, merged with what is already there. Keepers get
`verified: imported from <original path> on <date>; <original verified>`. Interactively, show the list
and wait for the user's answer. Never delete the originals; tell the user they can go once the import is in.

## Report

Tidy and harvest: one line, for the log of the machine that ran it ("tidy: merged 2, retired 3, index
at 112 lines"). Retro and import: plain text, in the order above, including what you could not verify
and that only this machine's transcripts were read.
