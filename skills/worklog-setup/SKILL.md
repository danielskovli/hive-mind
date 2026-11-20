---
name: worklog-setup
description: The Worklog, an optional task tracker page on claude.ai that sessions read and write through its database - set it up for a hive, back it up into the hive's worklog/ folder, or restore it from there. Use when asked to set up, add, back up, refresh or restore the Worklog, or when its instructions say the backup is stale.
---

# The Worklog

The Worklog is an artifact on claude.ai: a page (`worklog/page/` in the core) and a database holding
tasks, their steps, journals and projects. It is the user's and the sessions' shared tracker. Only
interactive sessions can reach it: publishing and its database are Claude's tools, not something a
script can call, which is why this is a skill.

Its database has these collections: `items`, `steps`, `journal`, `projects`, `meta` (with
`meta/agent-guide`, the guide agents follow), and `history`, which the page keeps for 90 days and which
is not backed up.

`<core>` is the hive's core (`$hive/hive-mind`), and `$hive` the hive
(`hive=$(cd "$(readlink ~/.claude/rules/hive)/.." && pwd)`).

## Set it up

1. **The page.** Copy `<core>/worklog/page/` to a scratch folder, and in its `index.html` replace
   `https://github.com/OWNER/hive` with the hive's repository. Load the artifact-capabilities skill, then
   publish `index.html` as a new artifact with the `db` capability, `files` mapping `worklog.css` and
   `worklog.js` to the copies beside it.
2. **The guide.** Write `meta/agent-guide` into its database with the artifact database tool: `title`
   "Worklog: guide for agents", `body` the text of `<core>/worklog/guide.md`, `by` and `updated` as the
   guide says.
3. **The instructions.** Add `instructions/worklog.md` to the hive, by pull request from a worktree (the
   live checkout refuses edits there), with the text below and the new URL, and change `me.md`'s
   tracker line to name the Worklog. Merge it with the user's agreement.
4. **The first backup,** as below, so the hive has one from the start.

```markdown
## Worklog

The user's task tracker is the **Worklog** artifact: <URL>. When they refer to their list of work, by
any name, this is it; never start a second tracker.

Either of you drops things there: flagged for later (the inbox), or to supplement work in progress (a
task's notes and journal). When the work in hand belongs to a Worklog task, keep that task current as
the session goes, and read what you are about to change right before you write it: the user and other
sessions change it concurrently.

Before reading or writing it, read the document `meta/agent-guide` in its database (the artifact
database tool, that URL) and follow it. When you read the guide and the backup in the hive's
`worklog/` is more than three days old (`git -C <hive> log -1 --format=%cr -- worklog`), refresh it as
the worklog-setup skill says, in the same session. Headless sessions have no Worklog tools: they list
what they would have captured in their report instead.
```

## Back it up

The backup lives in `$hive/worklog/`: `page/` (its three files) and `data/<collection>/<id>.json` (one
file per document, its fields only). The artifact stays the live copy; the backup is refreshed from it
and never written back on its own.

1. For each collection but `history`, empty `$hive/worklog/data/<collection>/` first (so deleted
   documents go too), then read it with the artifact database tool: `list`, `query.limit` 1000,
   `out_dir` set to `$hive/worklog/data`. Page with `next_cursor` if a result has one.
2. Read the artifact with `paths: ["index.html", "worklog.css", "worklog.js"]`, and copy the saved files
   to `$hive/worklog/page/`.

Leave the files for the hooks to commit, as with memory. A refresh that would leave fewer than half the
documents there were (the Worklog gone, a read that failed half way) is not committed, and `hive status`
says so: look before forcing it. When two machines refresh at once, each document comes whole from one
of them.

## Restore it

Restore from history, not from the working tree, which may hold the very refresh that came back empty:
`git -C $hive log --format='%h %cs %s' -- worklog/data` shows the snapshots, and `git checkout <commit>
-- worklog` in a worktree of the hive gives you one.

1. **The page.** Publish `page/index.html` as a new artifact with the `db` capability, with `files`
   mapping `worklog.css` and `worklog.js` to their copies in `page/`. Skip this if the artifact still
   exists.
2. **The data.** Write every file under `data/` into the artifact's database: `batch`, at most 50 `set`
   writes per call, `collection` from the directory name and `doc_id` from the file name, the file as
   `file_path`. Where a document still exists, compare its `updated` with the snapshot's and keep the
   newer: a restore must not undo work done since. Pin each write to an existing document with the
   `version` a read returns.
3. **The links.** A new artifact has a new URL: change it in `instructions/worklog.md` (a pull request),
   and tell the user the new link.

What changed after the last refresh is lost; say what date the snapshot is from
(`git -C $hive log -1 -- worklog`).
