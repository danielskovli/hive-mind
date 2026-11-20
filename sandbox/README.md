# A hive in an agentctl sandbox

A sandbox is wiped by `agentctl delete`, so it cannot keep the hive; it clones it. What tells it to is the
hive's `sandbox/host-instructions.md`, which your own variant of each agent (`agent.mine.yaml`) lists
among its instructions, after agentd's "Agent sandbox" section and ahead of the agent's own. It holds
two things: the pointer, which says where the hive is, how to tell whether it loaded, the commands that
bring it up, and to pass on what `hive status` marks `fix`; and below it, the rules every sandbox
follows, hive or not, such as what leaving the sandbox means and keeping it lean. Neither repeats what
the hive's instructions say.

In a new sandbox the first session finds no hive, runs the commands (clone the hive and its core,
`hive install`, sync), reads the instructions and memory index, and says so. `hive install` clones the
other sources and writes the Claude Code settings and links, so every later session loads the hive
natively and its hooks keep it in sync.

The hive's instructions load through links that nothing in a sandbox undoes, but its settings and hooks
can be replaced, as an agent's own home can. Such a sandbox looks healthy while nothing syncs or pushes.
No hook can report that, so every session runs `hive status` before its first reply and opens with each
line it marks `fix`.

## The sandbox's settings

`home/` here is the home your variant gives each agent. agentd copies it over `/home/agent` when the
agent starts and again every 30 seconds, replacing each file it holds. Its one file,
`.claude/settings.json`, is exactly what `hive install` writes in a sandbox whose hive is at
`/home/agent/hive`, and a test keeps the two equal. So a sandbox has the hive's settings from its first
second, and nothing an agent's own home holds can undo them. Anything else put in `home/` lands in every
such sandbox.

Until the first session has cloned the hive, those settings name a `bin/hive` that is not there yet:
each hook fails "with non-blocking status code", and the session carries on. Claude Code creates the
memory directory, `~/hive/memory`, on the first prompt, and a clone into a directory that is not empty
fails, so the pointer removes the two while they are empty.

agentd reads `home/` from the host's hive, at the core it pins, while each sandbox runs its own core. A
change to the settings reaches sandboxes once the host's hive syncs, and `hive status` in a sandbox says
when the settings and its core disagree.

## Setting it up

`SETUP.md`, section "agentctl": in your variant of each agent, list the hive's
`sandbox/host-instructions.md` and point the agent's home at this `home/`. Give the agent's GitHub
account push access to the hive. `hive status`, inside a sandbox, checks that it got the pointer and that
its settings match its core.

Commits name their machine in a `Hive-Host:` trailer (`agentctl:<agent> on <host>`). Nothing runs before
`agentctl delete`; the hive loses nothing to that in practice, since every turn pushes, and `hive status`
shows commits a failed push left behind.
