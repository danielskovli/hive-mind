# hive-mind

The core of a **hive**: one person's working instructions, skills, memory and decisions, shared by every
Claude Code session they run, on every machine, laptop and sandboxes alike. A session that learns
something writes it down; the next session, anywhere, starts with it.

A hive is a private repository of your own, made from this core's template. This repository is the
engine every hive runs:

- `bin/hive`, which Claude Code's hooks call: it pulls at each session start and pushes what sessions
  wrote after each turn, many sessions on many machines at once without losing a write.
- `instructions/hive.md`, how sessions use a hive, loaded into every session.
- Skills that keep a hive running: `consolidate-hive` (an automatic tidy of memory, and your retro),
  `hive-setup` and `worklog-setup` (an optional task tracker on claude.ai).
- `template/`, the hive a new one starts from, and `sandbox/`, for agentctl sandboxes.

## Get a hive

Paste this into Claude Code:

> Set up a hive for me: clone https://github.com/danielskovli/hive-mind to a temporary folder and follow
> its skills/hive-setup/SKILL.md.

It asks a few questions, creates your private repository, and wires Claude Code to it. `SETUP.md` says
what it changes and how the parts fit.

## How a hive is laid out

```text
~/hive/                  your repository
  hive.lock              the sources it runs, each pinned to a commit: this core first
  instructions/          how you work, loaded into every session
  skills/                your own skills
  memory/                what sessions learn, one fact per file
  decisions/             why things are the way they are
  sandbox/               the pointer agentctl sandboxes get
  hive-mind/             this core, a clone at its pin
  agent-skills/          another source, if you pinned it
```

A hive pins each source in `hive.lock`, and every machine runs exactly the commits its hive names:
`hive sync` fetches them before it moves the hive, then moves both. `hive upgrade` moves the pins to each
source's newest commit and pushes them. When two layers have a skill of the same name, the higher wins:
your hive's, then the sources from the last in `hive.lock` to the first, this core.

## Commands

| Command | What it does |
| --- | --- |
| `hive status` | Where this machine stands, its sources, and its setup checked against `SETUP.md` |
| `hive sync` | Pull now, rather than at the next session start |
| `hive upgrade [source]` | Pin the sources (or one) to their newest commits, and push |
| `hive tidy` | Run a tidy of memory now, in the foreground |
| `hive usage` | Which memories sessions opened in the last 30 days, on every machine |
| `hive costs` | Where sessions logged a rule costing them something, for your retro |
| `sh tests/check.sh` | Every check of the core, offline |

## Contributing

Changes come by pull request. `sh tests/check.sh` runs every check offline, against a hive built from
`template/`; CI runs it on Linux and macOS. The core names no person and no employer, and a check keeps
it that way.

MIT licensed.
