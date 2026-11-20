# Worklog: guide for agents

This is the user's personal task tracker. Read this guide before you read or write anything here, and follow it. The user edits it on the page under "For agents". The hive's instructions say when to use the Worklog; this guide says how, and wins where they differ.

## Access

The data lives in this artifact's database. Read and write it with your artifact database tool and this artifact's URL; never by republishing the page. The page itself changes only when the user asks for a change to the page.

- Pin every write to an existing document with the version you last read. If it fails because the version moved, read the document again and redo your write on what it holds now: the user may have just changed it on the page.
- On every write set `by` to where you run: `"cli"` for Claude Code, `"phone"` for the Claude app or claude.ai. On new items also set `source` the same way. Set `updated` (ISO 8601 UTC) on every write, read from the system clock (`date -u +%Y-%m-%dT%H:%M:%SZ`) at the time of the write; never estimate it, a time in the future shows as "just now" until it passes.
- Prefer one batch over several writes.
- A write that changes a task's `status`, `blockedBy`, `project`, `priority` or `due` also creates its `history` entry (see **Data**), in the same batch. The page's History tab shows the change from it; without one, it shows only as "Edited".

## Data

`items/<id>` holds tasks (ids: `i` plus a short slug, e.g. `ifixlogin`):

| Field | Meaning |
| --- | --- |
| `title` | What to do, short, in the user's words where you have them. |
| `notes` | Context and decisions, in Markdown (the page renders lists, headings, code, links and bold, not tables). Open with a sentence or two that stand alone: the inbox card shows them raw as a preview. Then short bold-labelled sections or lists for what applies (options, open questions, evidence with `Verified:` or `Inferred:` labels, what was decided), not one paragraph. Link, don't copy, issue and PR text. The user's own captures stay as they wrote them. |
| `status` | `inbox`, `backlog`, `next`, `doing`, `waiting`, `done`, `dropped`. The page and the user call `waiting` "Blocked". |
| `project` | Id of a document in `projects`, or `""`. |
| `priority` | 0 (none) to 3; 1 is most urgent. |
| `due` | `YYYY-MM-DD` or `""`. |
| `links` | Array of links. Each is a URL string, or `{url, title}` once it has a description. Read both forms. `title` is one short line saying what the link is to the user ("Practice PR in my fork", "Related, not opened for this work"), not a copy of the GitHub title. Give a link you add a title when you know what it is. |
| `blockedBy` | One line: who or what this waits on. `""` when nothing does. |
| `rank` | The user's order within a board column, lowest first; the page sets it when they drag a card. Whenever you change `status`, set `rank` to `null`: the task then shows at the top of its new column until they place it. Never set a rank yourself. |
| `handoff`, `handoffAt`, `handoffBy` | The brief for the next agent (Markdown), when and where it was written. |
| `created`, `updated`, `doneAt` | ISO 8601 UTC. `doneAt` is set when the item is done or dropped, `""` otherwise. |

**Links in text.** Where `notes`, a `handoff` or a journal `text` mentions a PR, issue or commit, write it as a Markdown link to it on GitHub, so the user can open it from the page: `[#123](https://github.com/<owner>/<repo>/pull/123)`, `[6436313](https://github.com/<owner>/<repo>/commit/<full sha>)`. Keep the link text plain: the page shows a code span inside a link as raw text. The `links` field still lists the main ones.

`steps/<id>` holds the checklist lines of a task (ids: `<task id>-<slug>`, e.g. `ifixlogin-release`). A step has only these fields; there is nowhere to put a status, priority, due date or project, which it takes from its task:

| Field | Meaning |
| --- | --- |
| `task` | Id of its task in `items`. |
| `title` | The step, short. |
| `done`, `doneAt` | `true` or `false`; `doneAt` is set when done, `""` otherwise. |
| `blockedBy` | One line: who or what this step waits on. `""` when nothing does. |
| `notes`, `links` | As on a task. |
| `order` | Position in the task's checklist, 1 first. A new step takes the highest `order` plus one. |
| `created`, `updated`, `by` | As on a task. |

Deleting a task deletes its steps. To turn a step into a task of its own, create the task in `items` and delete the step.

`projects/<id>`: `name`, `color` (hex), `status` (`active` or `archived`), `stacked` (`true` or `false`), `created`, `description`. While the board shows all projects, a stacked project's tasks in each column show as one card, except tasks that are blocked, P1 or due within a day, which show on their own. A project whose work is over is archived (`status: "archived"`), never deleted: its tasks, done ones included, keep it, and the page shows its chip only under Done. Only a project no task uses may be deleted.

`journal/<id>` holds a task's trail: which agent sessions worked on it and how to get back to them, and the decisions taken on the way (ids: `<task id>-<UTC timestamp, digits only>`, e.g. `ifixlogin-20261015201500`). Entries are only ever created; never edit or delete one.

| Field | Meaning |
| --- | --- |
| `task` | Id of its task in `items`. |
| `at` | ISO 8601 UTC, from the system clock. |
| `by` | `"cli"` or `"phone"`, as on a task; `"page"` for a note the user wrote on the page. |
| `kind` | `"session"` or `"note"`. |
| `text` | One line. For a session: what this session is doing on the task. For a note: the decision or finding. |
| `host`, `cwd`, `branch`, `session` | Session entries from Claude Code only: `hostname -s`; the absolute directory Claude Code was started in (the primary working directory in your environment, not a directory you changed into: `claude --resume` only finds the session from there); the branch you work on, with its repository if that is not obvious from `cwd`; and `$CLAUDE_CODE_SESSION_ID`. The page builds `cd <cwd> && claude --resume <session>` from them. |
| `agent`, `agentSession` | Session entries from an agentctl sandbox only, which you are in when `$AGENT_NAME` is set: `$AGENT_NAME` and `$AGENT_SESSION_NAME`. There `host` is `$AGENT_HOST` and `cwd` is `$AGENT_SOURCE_DIRECTORY`, a path on the user's machine that does not exist inside the sandbox. The page then builds `cd <cwd> && agentctl attach session/<agentSession> --agent <agent>`. |

`history/<id>` logs changes to tasks for the page's History tab (ids: `<task id>-<UTC timestamp, digits only>`). Entries are only ever created; the page deletes them after 90 days, and with their task.

| Field | Meaning |
| --- | --- |
| `task` | Id of its task in `items`. |
| `at` | The write's `updated`, exactly. |
| `by` | As on the task. |
| `changes` | One `[from, to]` pair per field the write changed, of `status`, `blockedBy`, `project`, `priority` and `due`: `{"status": ["next", "doing"], "blockedBy": ["", "Review: #N"]}`. A missing value is `""`; no priority is `0`. |

## How the user uses it

- **A task is one piece of work they act on.** An open pull request is one task, "Review and merge #N", open for as long as the PR is: never separate review and merge steps.
- **Steps are checklist lines under a task,** in `steps`, never items with a parent. The page shows them only inside their task. The user ticks them done there; everything else about a step is the agents' to keep accurate, and its order is the order of work.
- **Bulk work goes in a stacked project.** When one piece of work turns into more than about five tasks of its own (issues from a triage, PRs from a sweep), create a project with `stacked: true` and give each issue or PR its own task there, not a step under one umbrella task.
- **Blockers are explicit.** Put what blocks a task or a step in `blockedBy`. A task that waits on someone or something other than the user has status `waiting`. One that waits on the user (their review, their decision) has status `doing`, blocker and all: it is theirs to act on. When the blocker clears, clear `blockedBy` and move a `waiting` task back to `next`, or either to `done` when the blocker was all the work left. Never set `waiting` without a blocker. On the page the user unblocks a task with its Unblock button, which may add a journal note by `page`.
- **A pasted `Worklog: <task id> "title"` line**, optionally followed by `› step <step id> "title"`, comes from the page's "Copy ref" button and names the task (and step) the user means. Read them by id before anything else; the titles are there only to make a wrong paste obvious.
- **Inbox** is for thoughts captured in passing, often from the phone. Capture them as the user said them; don't triage unless they ask.
- **Either of you drops things here.** When you notice something worth doing outside the task at hand, add it to the inbox in one line with a link, rather than doing it unasked or letting it drop. When it supplements a task in progress, put it in that task's notes or journal instead.
- When work the user asked you to track changes state (a step done, a blocker cleared, a PR merged), update its task or step in the same session.
- **Every session that works on a task says so in its journal,** so the user can find it again after a crash or on another day: one `session` entry per session per task, before anything else.
- **Journal notes are for decisions,** findings that change the plan, and things the user would want to know when they next open the task: one line each. Routine progress belongs in steps, and the full state in the handoff.

## "Hand this off"

When the user wants the work continued later, in a fresh session or on another device, write a brief on the task (never on a step) for an agent that knows nothing about this conversation.

1. Find the task they name, or the one this conversation works on. If there is none, propose one and create it when they agree.
2. Establish the state now, don't recall it: for each repository the branch, HEAD sha and whether it is pushed; open PRs with CI state and unresolved threads; worktrees and other paths; anything running in the background.
3. Write the brief in Markdown, leaving out a section with nothing to say: **Goal**, **State**, **Done**, **Verified, inferred, assumed** (each bullet starting `Verified:`, `Inferred:`, `Assumed:` or `Not run:`), **Next**, **Decisions**, **Gotchas**, **How to check**.
4. Name everything by sha, PR or issue number (linked), absolute path and exact command. No secrets: say where a secret lives instead. The brief replaces the previous one and describes the state now, not the journey.
5. Save `handoff`, `handoffAt` and `handoffBy` on the task. Tell the user in a line or two which task holds it. Don't paste the brief into the chat.

## "Pick up …"

1. Match their words against the titles of open tasks; if more than one or none matches, list candidates and ask. Read the task with its steps, notes, links, blocker, handoff and journal. Then add your own `session` entry.
2. The brief is a lead, not evidence. Check it against now: each repository's branch head against the brief's sha, each PR's state, CI and threads, and the **Assumed** items first.
3. Tell the user in a few lines where the task stands, what changed since the handoff, and the step you start with. Then start, unless something you found contradicts the plan.
4. If there is no handoff, say so and offer to start from the task's notes and links.

## "Reconcile the board"

When the user asks (reconcile, sync, tidy up): read every open task and step outside the inbox, collect the GitHub references each carries, fetch each with `gh`, and then:

- Without asking, with one journal note each: a task whose own PR merged goes `done`; a `blockedBy` naming only merged or closed PRs and issues is cleared, and a `waiting` task moves to `next`.
- Asking first: a PR closed without merging, a step whose PR merged, a task blocked on the user's review whose PR has new commits, a `doing` task with no change for a week, a reference you could not resolve.

Report one short table: what changed, what needs the user, what you could not match.

## When you can't follow this guide

If your environment cannot reach this database, say so. If the Worklog is gone or its database is empty, say that too: the hive keeps a backup in `worklog/`, and the worklog-setup skill says how to restore it. Never store tracker data anywhere else.
