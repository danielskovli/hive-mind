---
name: hive-setup
description: Set up a hive for someone - a private repository made from hive-mind's template, cloned to ~/hive with its pinned sources and wired into Claude Code - or bring an existing hive to a new machine. Use when asked to set up, create or install a hive, when following hive-mind's SETUP.md, or when a machine needs a hive someone already has.
---

# Set up a hive

A hive is the user's private repository of instructions, skills, memory and decisions that every Claude
Code session of theirs shares, on every machine. This skill makes one from the template in the core,
`hive-mind`, or brings an existing one to a new machine. Talk the user through it in plain words; they
may never have heard of any of this.

Work from a clone of `hive-mind` (the user's prompt names it; otherwise clone
https://github.com/danielskovli/hive-mind to a temporary folder). `<core>` below is that clone.

## Before anything

- Needs `git`, `python3`, a POSIX shell (macOS or Linux; on Windows, WSL), Claude Code, and `gh` signed
  in (`gh auth status`) to the GitHub account that will own the hive.
- If `~/hive` exists, or `~/.claude/rules/hive` is a link, the user has a hive on this machine: stop and
  ask what they want.
- If the user already has a hive and only this machine needs it, skip to "On this machine" with their
  repository's URL.

## Ask, in one message

1. Their name, and how sessions should address them.
2. The GitHub account to own the hive (default: `gh api user --jq .login`) and the repository's name
   (default `hive`). It is created private.
3. In a sentence or two, what they work on and where their repositories live.
4. Whether to include `agent-skills`, a collection of skills for building software with agents (a
   spec-to-pull-request flow, a red team, code quality, acceptance, pull request evidence and review).
   Default yes.
5. Whether they want the Worklog, a task tracker page on claude.ai that sessions read and write. It can
   be added later with the worklog-setup skill.

## The repository

```sh
work=$(mktemp -d) && cp -R <core>/template/. "$work/"
```

Then fill in `$work`:

- `hive.lock`: one line per source, `<name> <git URL> <commit>`, the core first. The core's line is
  `<core>`'s origin and the commit it is at: `git -C <core> remote get-url origin`, `git -C <core>
  rev-parse HEAD` (a commit on its `main`, so other machines can fetch it). agent-skills' commit is
  `git ls-remote https://github.com/danielskovli/agent-skills HEAD`. Without agent-skills, delete its
  line here and in `.gitignore`.
- `instructions/me.md`: replace every placeholder from their answers, and remove the comment.
- `sandbox/host-instructions.md`: replace `https://github.com/OWNER/hive` with the hive's URL.
- Read every file once more for a placeholder left in capitals.

```sh
gh repo create <owner>/<name> --private --description "My hive: instructions, skills and memory for Claude Code"
git -C "$work" init -q -b main && git -C "$work" add -A && git -C "$work" commit -qm "A new hive"
git -C "$work" remote add origin https://github.com/<owner>/<name> && git -C "$work" push -q -u origin main
```

## On this machine

```sh
git clone -q https://github.com/<owner>/<name> ~/hive
set -- $(awk '!/^[[:space:]]*(#|$)/ { print $2, $3; exit }' ~/hive/hive.lock)
git clone -q "$1" ~/hive/hive-mind && git -C ~/hive/hive-mind checkout -q --detach "$2"
~/hive/hive-mind/bin/hive install && ~/hive/hive-mind/bin/hive status
```

`install` clones the other sources, links the rules and skills, and sets Claude Code's settings: what
it changes is in the core's `SETUP.md` ("A machine"). Read its output to the user:

- `autoMemoryDirectory is already …`: their memory lives somewhere else. Ask before rerunning with
  `--force`, which points it at the hive.
- `skipped: …`: a skill or rule of theirs is in the way. Show which, and ask before `--force`, which
  moves it to `~/.claude/hive-backup/`.
- `hive status` lines marked `fix` name what is wrong and the section of `SETUP.md` to read.

## Afterwards

Tell the user, in a few lines:

- Every new Claude Code session now loads the hive; sessions already running pick it up when restarted.
- Memory now lives in `~/hive/memory`. Their old per-project memories stop loading; the consolidate-hive
  skill in import mode brings the ones worth keeping across.
- Sections of `~/.claude/CLAUDE.md` that say what the hive now says load twice; `hive status` names them.
- Instructions and skills change by pull request in the hive; a session proposes one when asked.
- `hive upgrade` moves the hive to the newest core and skills, when they choose to.

Then, if they asked for it, run the worklog-setup skill. Remove `$work` and the temporary clone of the
core.
