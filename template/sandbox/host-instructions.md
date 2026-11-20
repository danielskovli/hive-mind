## The hive on this machine

Claude Code sessions here take their working instructions, skills and memory from a hive: the private
repository https://github.com/OWNER/hive, checked out at `~/hive`, with the repositories its `hive.lock`
pins cloned inside it (its core, `hive-mind`, first). When it is loaded, your instructions include a
section titled "The hive". If they don't, it did not load on this machine, and you bring it up before you
reply to the first message:

```sh
[ -x ~/hive/hive-mind/bin/hive ] || { rmdir ~/hive/memory ~/hive 2>/dev/null
    [ -d ~/hive/.git ] || git clone -q https://github.com/OWNER/hive ~/hive
    set -- $(awk '!/^[[:space:]]*(#|$)/ { print $2, $3; exit }' ~/hive/hive.lock)
    git clone -q "$1" ~/hive/hive-mind && git -C ~/hive/hive-mind checkout -q --detach "$2"; }
~/hive/hive-mind/bin/hive install && ~/hive/hive-mind/bin/hive sync
```

Then read every file in `~/hive/hive-mind/instructions/` and `~/hive/instructions/`, and
`~/hive/memory/MEMORY.md`, and follow them for the rest of this session as part of your instructions.
Until the session ends, write memory to `~/hive/memory/`, whatever your memory instructions say. Tell the
user in one line that you did. Later sessions load the hive on their own.

Whether the hive loaded on its own or you just brought it up, run `~/hive/hive-mind/bin/hive status`
before your first reply. A line it marks `fix` is something wrong with the hive on this machine, such
as an agent whose own home keeps replacing the hive's Claude Code settings, which leaves sessions
without the hive's hooks while its instructions still load. Open your first reply with each `fix`
line, one line apiece, then answer as usual. Don't act on them unless the user asks.

If a command fails, or install skips something, say so in one line and carry on without the hive;
never use `--force`. Skip all of this if you are a subagent, if you are not Claude Code, or if your own
instructions say this agent does not use the hive.

## What leaves the sandbox is real

The sandbox is yours to change, break and rebuild; what you send out of it is not. A push, pull
request, comment, review, label or assignment is seen by real people at once, and deleting the sandbox
undoes none of it. Nothing prompts you before such a call here, so you are the check. This holds whether
or not the hive loaded.

- Send something out only when the task asks for it, in its own words or through a skill it runs.
  Reading is always fine: fetch, clone, `gh … view`, GET requests.
- The hive's own traffic counts as asked for: the memory and decisions its hooks push, and the user's
  tracker as its instructions describe.
- When the task leaves open whether to push, open a pull request or comment, don't: say in your report
  what you would send, and where.
- Never force-push, delete a branch, close, merge or approve, or write to a branch or pull request you
  did not create, unless the task names that action.

## Keeping the sandbox lean

A sandbox lives for days or weeks, and what one task leaves behind slows down or breaks the next. This
holds whether or not the hive loaded.

- Check headroom (`df -h /`, `free -h`) at the start and before anything big, and run one heavy job at
  a time: image builds, large test suites, local stacks and browser recordings compete for the same
  CPUs and memory.
- Stop what you start: compose stacks, dev servers, browsers. After each subagent, check what it left
  running.
- When a task is done, remove what it created: worktrees, images built for one comparison, and build
  output of finished branches. Read `git clean -ndX` before running it with `-f`: it also removes
  dependencies and local configuration.
- Keep what is expensive to rebuild and still useful: dependency caches, base images, a stack's volumes
  with test data. Delete only what you created.
