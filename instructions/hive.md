## The hive

The user runs you in many places: their laptop, sandboxes, whatever comes next. Every one of them shares
one hive, the user's private repository, checked out on each machine at `~/hive` (`readlink
~/.claude/rules/hive` shows where). The hive pins the repositories it runs in `hive.lock`, and each is a
clone inside it: its core, `hive-mind` (the engine, these instructions and the skills that keep a hive
running), and often a collection of skills such as `agent-skills`. These instructions, your skills and
your memory directory all come from that checkout. Hooks keep it in sync: each session start pulls, and
the end of each turn commits and pushes what changed in `memory/`, `decisions/` and `worklog/`. You do not
run git for that, and you never need to wait for it.

The point is that the next session, anywhere, starts better than this one ended. That only happens if
you write down what you learn while you learn it.

### Where things go

| What | Where | How it changes |
| --- | --- | --- |
| How we work, anywhere | `instructions/` in the hive | pull request, merged by the user |
| Procedures | `skills/` in the hive | pull request |
| How a hive works, and skills shared with others | a source, such as `hive-mind` | pull request in that repository, then `hive upgrade` |
| Judgments, preferences and gotchas | `memory/` | write the file; the hooks push it |
| A choice between alternatives for how we work, and why | `decisions/` | a new file |
| What we are doing: tasks, plans, dates, handoffs | the Worklog, where the hive has one | its own instructions |
| Claude Code settings the user wants on every machine | the hive's `settings.json` | pull request |
| What any developer needs to work in a repository | that repository's `AGENTS.md` | pull request there |

Knowledge moves upward: a memory that keeps proving itself becomes an instruction, a skill step or a
line in `AGENTS.md`. You don't do that yourself: the hive's automatic tidy lists candidates, and the
user's retro decides (both are the consolidate-hive skill).

### Memory

Your memory directory is the hive's `memory/`, for every project on every machine. Follow your built-in
memory instructions, and also:

- **Write it now.** When you are corrected or learn a gotcha, write the memory at once, even when it
  belongs in a repository's `AGENTS.md` in the end: then add `promote: AGENTS.md (<repo>/<path>)` under
  `metadata`. Sessions end without warning, and nobody else will write it.
- **No tasks.** Plans, dates, who is doing what and work in progress go in the Worklog (or wherever the
  user tracks work), not in a `project` memory. Use `project` only for lasting constraints GitHub can't
  give back.
- **Rule or default.** A `feedback` memory says under `metadata` how firmly it holds:
  `firmness: rule` only when the user stated it as a rule (always, never, anywhere, from now on) or
  confirmed it as one; otherwise `firmness: default`, for a remark about one situation or a lesson of
  your own. The index lists them apart. Follow a rule. Weigh a default against the case in front of
  you, and when you depart from one, say so in a line, so the user can correct either. Only the user
  turns a default into a rule.
- **Log what a rule cost.** When one of the hive's rules costs something in the case in front of you,
  when two of them conflict, or when you depart from a default, also log it for the retro:
  `hive cost <memory, instructions/<file> or skills/<name>> "<context>: <what it cost>"`. Give the
  context and the cost, not a verdict; the retro weighs it. A conflict goes against both.
- **Nothing secret or private.** No credentials, personal data or a client's data: memory is on GitHub
  within the turn. Say where such a thing lives instead.
- **The description is a search key,** under about 120 characters, starting with the repository when it
  only holds there. Something true of every sandbox and only there starts "In sandboxes:". Nothing
  about one machine.
- **Metadata:** `date` (YYYY-MM-DD) and `verified` (how you know: ran it, read it, the user said so,
  inferred). Change them only when you re-checked the substance, not when you merely used the memory.
- **To forget one,** retire it instead of deleting it: add `status: retired`, `retired: <date>` and
  `why: <one line>` under `metadata`. The index drops it at once.
- **Two versions.** When sessions on two machines changed a memory at the same time, the file holds both,
  the second fenced below a `<!-- hive:sibling -->` marker, and its index line ends `[2 versions]`.
  Read both when you rely on it. Merge them only if you are sure how they combine; otherwise the next
  tidy does.
- `MEMORY.md` is generated; editing it does nothing. Write each memory file whole: other sessions read
  them while you work.

### Decisions

When the user and you choose between named alternatives for how sessions, the hive or the user's
tracker work, write the memory or instruction change first (that is what acts), then
`decisions/YYYY-MM-DD-<slug>.md` in the same session: a title, then **Context**, **Decision**, **Why** and
**Ruled out**, a few lines each, citing the memory. A correction alone is just a memory. A decision about
one task belongs with that task. Never rewrite one; a later decision supersedes it by saying so.

Before proposing a change to how we work, `grep -ril --exclude-dir=tidy <topic> decisions/` in the hive:
what was ruled out, and why, is recorded there.

### Changing instructions, skills and sources

In the live checkout, only `memory/`, `decisions/` and `worklog/` change; a hook refuses edits anywhere
else, including the files you see under `~/.claude/rules/hive*` and `~/.claude/skills/`, which are that
checkout. Instructions, skills and the rest of the hive change by pull request, from a worktree:

```sh
hive=$(cd "$(readlink ~/.claude/rules/hive)/.." && pwd)
git -C "$hive" fetch -q origin && git -C "$hive" worktree add "$hive-<topic>" -b <topic> origin/main
```

A source (the core, a skills collection) changes by pull request in its own repository, from a clone
outside the hive. Once it has merged, `hive upgrade <source>` pins the hive to it and pushes the pin;
every machine moves to it at its next sync, and `hive.lock` changes no other way. When two layers have a
skill of the same name, the higher wins: a sandbox agent's own, then the hive's, then the sources from
the last in `hive.lock` to the first, the core.

Open the pull request when the user asks for the change; otherwise suggest it in your report. Remove the
worktree once the pull request is open.

### When sync speaks

Session-start lines beginning with `hive:` come from the sync hook. Whatever they ask for comes after
the user's task, never before it, and gets reported in a line of plain words, not the hive's jargon.

- **Changes arrived:** the listed memories are as good as loaded. Read any listed instruction file now.
  When the sources moved, re-read the core's instructions.
- **Sync failed:** carry on; memory you write is kept and pushed once sync works. Mention it to the user
  once, with the reason the line gives. Never run git in the checkout or a source to fix it. If the
  reason names a file outside `memory/`, `decisions/` and `worklog/`, tell the user which file.
- **Claude Code drift:** a tidy found Claude Code changing how memory works. Read the log's `- Drift:`
  lines, then add one item to the Worklog inbox that sums them up and links the log, unless the Worklog
  has one for it already, in any status; in a hive without a Worklog, tell the user. A headless session
  lists it under "Captured for later" instead.
