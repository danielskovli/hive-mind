# Setting up a hive

How a hive is made, how a machine and an agentctl sandbox are set up, and how the hive keeps itself
tidy. Where each kind of knowledge goes is in `instructions/hive.md` ("Where things go"), which every
session loads. The hive-setup skill follows this page. When in doubt, `hive status` checks the machine it runs on against
this page, and names the section to read for anything that is off.

## Getting one

Paste this into Claude Code, on the machine you use most:

> Set up a hive for me: clone https://github.com/danielskovli/hive-mind to a temporary folder and follow
> its skills/hive-setup/SKILL.md.

You need `git`, `python3`, `jq`, Claude Code, and `gh` signed in to the account that will own the hive,
with the `workflow` scope (`gh auth refresh -s workflow`): the hive's first push carries its workflow.
The session asks your name, the GitHub account to own the hive, what you work on, and whether you want
`agent-skills` and the Worklog. It then creates your private repository from `template/`, pins this
core (and `agent-skills`) in its `hive.lock`, clones it to `~/hive`, and runs `hive install`. On another
machine, ask a session to "set up my hive from https://github.com/<you>/hive on this machine".

## A machine

It needs `git`, `python3` (for the JSON edit), `jq` (for the tidy's harvest) and a POSIX shell; Linux and
macOS have all but `jq` already.

```sh
git clone https://github.com/<you>/hive ~/hive
set -- $(awk '!/^[[:space:]]*(#|$)/ { print $2, $3; exit }' ~/hive/hive.lock)
git clone -q "$1" ~/hive/hive-mind && git -C ~/hive/hive-mind checkout -q --detach "$2"
~/hive/hive-mind/bin/hive install
```

`install` touches exactly this, and `uninstall` reverses it:

- The other sources in `hive.lock`: each cloned into the hive at its pin, and kept out of its history.
- `~/.claude/settings.json`: sets `autoMemoryDirectory` to `~/hive/memory`; turns off
  `autoDreamEnabled` (Claude Code's own background consolidation, which the hive's tidy replaces),
  `idleCompaction` (see "The keep-alive") and `awaySummaryEnabled` (the recap Claude Code writes into the
  chat when you come back); blanks `attribution`, so commits and pull request descriptions name no model;
  and adds hooks that run `~/hive/hive-mind/bin/hive`: sync at SessionStart, save at Stop and SessionEnd,
  the keep-alive at Stop, UserPromptSubmit and SessionEnd, and a PreToolUse guard that refuses edits to
  the hive outside `memory/`, `decisions/` and `worklog/`. Everything else in the file is kept, and a
  linked settings file stays linked. Hooks of a hive cloned elsewhere are replaced.
- `~/.claude/rules/hive-mind` and `~/.claude/rules/hive`: links to the core's and the hive's
  `instructions/`.
- `~/.claude/skills/<name>`: a link per skill, from the highest layer that has it: in an agentctl
  sandbox the agent's own skill, which is left in place; then the hive's own; then the sources from the
  last in `hive.lock` to the first, the core. A link into a source the lock no longer pins goes. A copy there that matches is replaced, and a
  link to a checkout that is gone; anything else is left alone and reported (`--force` moves it to
  `~/.claude/hive-backup/`).
- `~/.local/bin/hive`: a link to the core's `bin/hive`, so `hive status`, `hive sync` and the rest run
  by name. If `~/.local/bin` is not on your `PATH`, install says so. Anything else already named `hive`
  there is left alone.

Nothing else: no daemon, no scheduled job. `hive` runs when Claude Code's hooks call it or when you do.

Every Claude Code session on the machine, in any directory, now uses the hive's memory. Keep the
checkout on `main`; work on the hive itself in a worktree (see "Changing instructions, skills and
sources" in `instructions/hive.md`).

You install once. When a new core changes what `install` writes to the settings, the next sync brings
the hive's keys and hooks up to it, through the core it has just checked out, and logs what changed.
Links are made by `install`, and by every sync for skills that arrive. In an agentctl sandbox, sync
leaves the settings alone: agentd puts the agent's home over them (see "agentctl").

### Then

1. **Tidy `~/.claude/CLAUDE.md`.** Keep only what is true of this machine alone. `hive status` lists
   sections it shares with the hive's instructions.
2. **Bring your old memories across.** Claude Code's per-project memories under
   `~/.claude/projects/*/memory/` stop loading once memory lives in the hive; `install` leaves them where
   they are. Ask a session to run the consolidate-hive skill in import mode.

## Sources and upgrades

`hive.lock` names each source the hive runs, one line each, `<name> <git URL> <commit>`. The core comes
first, named `hive-mind`, and the engine runs from that clone; sync and status refuse a lock that differs.
Every machine runs exactly those commits: a sync fetches every pinned commit before it moves the hive,
and if one cannot be fetched, the hive and every source stay where they were (memory still goes out),
and the session is told which source. `hive upgrade [source]` pins the newest commit of each source's
default branch, commits `hive.lock` and pushes it the way memory is pushed; every other machine moves at
its next sync. Two machines upgrading at once both land, source by source. To go back, revert the
commit that moved the pin.

A source is never edited in place: the guard refuses it, as it refuses `hive.lock`. Change one by pull
request in its own repository, from a clone elsewhere, then upgrade. To add a source, move one to a new
URL (a fork, a transferred repository) or drop one, change its line in `hive.lock` by pull request in the
hive; every machine follows at its next sync. A dropped source's skills stop loading, and its clone stays
on disk.

## agentctl

agentd starts every agent's instructions with its own "About this sandbox", then the files the agent's
manifest lists, in order. The committed manifest, `agent.yaml`, is the team's. What is yours, the hive's
pointer among it, goes in a variant beside it, `agent.mine.yaml`, which the agent's `.gitignore` keeps
out of Git. Your variant lists the pointer ahead of the agent's own instructions, and gives the agent
the core's sandbox home:

```yaml
apiVersion: agents.platform/v1alpha1
kind: AgentVariant
extends: agent.yaml
metadata:
  name: <the agent's name, as in agent.yaml>
spec:
  home:
    source: ~/hive/hive-mind/sandbox/home
  instructions:
    - source: ~/hive/sandbox/host-instructions.md
    - source: instructions.md
```

Apply it with `agentctl apply --variant mine`. A variant replaces `instructions` whole, so yours names
the manifest's instruction files again. agentd reads the files on every pass, so running agents pick up
a change within a minute.

`home` replaces the agent's own home overlay whole, and agentd copies it over `/home/agent` every 30
seconds, so the hive's settings stay put (`sandbox/README.md`). agentctl refuses to change an existing
agent's home, so delete the agent and apply it again.

For each agent:

- Its own `instructions.md` says what the agent is for, its repositories and tools, and rules for that
  agent alone. Nothing the hive says; `hive status` inside the sandbox flags sections both have.
- A skill its definition ships wins over the hive's of the same name: `hive install` leaves it to agentd,
  and `hive status` names it.
- Its GitHub account can push to your hive.
- An agent that should not get the hive has no pointer in your variant.

The first session in a new sandbox brings the hive up itself, following the pointer; later sessions load
it on their own.

## The automatic tidy, and your retro

Memory stays small and honest through two loops, both the consolidate-hive skill:

- **The tidy runs by itself.** At a session start, at most every six hours per machine, the hive checks
  in the background whether a tidy is due: the memory index near its budget, a memory holding two
  versions from concurrent sessions, memory files of a shape no tidy has checked, problems the
  keep-alive logged on that machine, or a week since the last one. If so, and no other machine has
  tidied today (a claim ref on GitHub decides), it starts a headless Claude session (Opus by default)
  that merges, retires and shortens memory, harvests that machine's transcripts, checks a Claude Code
  version no tidy has seen against the hive's memory format, and logs what it did in
  `decisions/tidy/<date>.md`. Other machines harvest their own transcripts once a day. Every machine also
  records which memories its sessions opened (`memory/.usage/`), so `hive usage` shows which memories
  pull their weight.
- **The retro is yours.** Ask a session for a retro now and then. It walks you through what the agents
  derived on their own since the last one, what sessions logged a rule costing them (`hive cost`, kept
  per machine in `memory/.costs/`), the tidies' open questions and promotion candidates.

The headless session never runs with permissions skipped. It runs in `dontAsk` mode, which refuses any
tool its allowlist does not name: it may read, edit the hive's `memory/` and `decisions/`, run read-only
git and `gh` commands, the harvest script, `hive index` and `hive usage`, and nothing else. To keep it
off a machine, set `HIVE_TIDY=off` in the environment Claude Code starts in, or `touch
~/hive/.git/hive/no-tidy`. `HIVE_TIDY_MODEL` picks the model; `hive tidy` runs one now, in the
foreground; `~/hive/.git/hive/tidy.log` holds what the automatic ones printed.

The hive's GitHub workflow checks every pull request with the pinned core's checks, and checks `main`
once a day for what must hold however it got there.

## The keep-alive

Claude Code caches a session's context for an hour. Come back to a long session after more than that,
and its next message writes the whole context to the cache again, at about twice the price of input,
instead of reading it at a tenth. The keep-alive keeps the cache warm while you are away:

- After every turn, a background Stop hook waits 55 minutes. If no turn has ended since, it wakes the
  session with a one-line ping, which the model answers in a line.
- Only interactive sessions with 100k tokens of context or more.
- `install` turns idle compaction off, so the keep-alive keeps the whole context.
- It stops 4 hours after your last message. "keep it hot" in a message stretches that to 16 hours, for a
  session of any size; "let it go cold" stops it for that session.
- `hive status` shows what it did last; `~/hive/.git/hive/keepalive.log` holds all of it.

It relies on `asyncRewake`, a hook option missing from Claude Code's public docs. The hook waits only
under a Claude Code binary that still has it, and checks that each ping's turn read the context from the
cache. When either fails, a tidy becomes due, and its drift step judges what changed.

## Checking it

`hive status`, on any machine or inside a sandbox, prints where the hive stands against origin and its
sources, then one line per setup check: `ok`, `fix` (with the section of this page to read) or `note`.

## What has been verified

`sh tests/check.sh` runs every offline check, on macOS and Linux in CI: what each scenario covers is in
`tests/hive.test.sh`, a check per line. `tests/claude.test.sh` runs real Claude Code sessions against a
hive, inside an agentctl sandbox only.
