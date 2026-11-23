#!/bin/sh
# Scenarios for bin/hive against a throwaway hive remote, two source remotes (the core and a collection
# of skills) and throwaway machines (a, b, c and more), each with its own home and Claude config
# directory. The core is built from this working tree, so uncommitted changes are what gets tested, and
# the hive from template/ with fixtures added. Prints ok or FAIL per check; the exit code is the number of
# failures.
# Checks are strings that check() evals, helpers run only from them, and `test && ok || fail` is the idiom:
# shellcheck disable=SC2015,SC2016,SC2012,SC2034,SC2329
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
# The real path: on macOS mktemp's directory is under /var, a link to /private/var, and bin/hive
# names its checkout by its real path.
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
# check_where <condition> <why not here> <name> <test>: a check that means something only where the
# condition holds, such as a case collision, which a filesystem that ignores case cannot hold.
check_where() { if eval "$1"; then check "$3" "$4"; else echo "skip $3: $2"; fi; }

# No user or system git configuration leaks in.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --file "$tmp/gitconfig" user.name tester
git config --file "$tmp/gitconfig" user.email tester@example.com
git config --file "$tmp/gitconfig" init.defaultBranch main
# Newer git (Apple Git 2.54 on macOS) packs loose objects in the background after a commit, and a local
# clone made meanwhile fails to copy the ones it removed.
git config --file "$tmp/gitconfig" maintenance.auto false
git config --file "$tmp/gitconfig" gc.auto 0
# The variables of the session running the tests, such as an agentctl sandbox's, stay out too.
unset CLAUDE_CODE_SESSION_ID AGENT_NAME AGENT_HOST CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_PID HIVE_KEEPALIVE_DELAY
# Never the real gh: the upgrade pull request tests use a stub.
export HIVE_GH_COMMAND="$tmp/no-gh"
# Never start a real tidy session from the tests; the tidy tests use a stub.
export HIVE_TIDY=off

# snapshot <dir> <dest>: the files git tracks or would track in <dir>, uncommitted changes included.
snapshot() { mkdir -p "$2" && (cd "$1" && git ls-files -co --exclude-standard -z | xargs -0 tar cf - | tar xf - -C "$2"); }
# bare <dir> <name>: commits <dir> as a new repository and makes $tmp/<name>.git from it.
bare() { git -C "$1" init -q && git -C "$1" add -A && git -C "$1" commit -qm snapshot && git clone -q --bare "$1" "$tmp/$2.git"; }
tip() { git --git-dir="$tmp/$1.git" rev-parse main; }

# The core's remote is a snapshot of this working tree.
snapshot "$root" "$tmp/core-src" && bare "$tmp/core-src" core
# A second source, as a collection of skills: one only it has, one the hive's own shadows, and one that
# shadows the core's.
for s in extra-one shared worklog-setup; do
    mkdir -p "$tmp/extras-src/skills/$s"
    printf -- '---\nname: %s\ndescription: from extras\n---\nextras\n' "$s" >"$tmp/extras-src/skills/$s/SKILL.md"
done
bare "$tmp/extras-src" extras

# The hive's remote. Real machines' usage records and rule costs would count in the throwaway machines'
# reports, and real tidy logs would decide when the throwaway machines' tidies are due.
hive_src=$root/template
snapshot "$hive_src" "$tmp/src"
rm -rf "$tmp/src/memory/.usage" "$tmp/src/memory/.costs" "$tmp/src/decisions/tidy"
mkdir -p "$tmp/src/instructions" "$tmp/src/memory"
printf '## Test instructions\n\nA fixture.\n' >"$tmp/src/instructions/test.md"
printf '## Other test instructions\n\nA fixture.\n' >"$tmp/src/instructions/other.md"
for s in hive-skill other-skill shared; do
    mkdir -p "$tmp/src/skills/$s"
    printf -- '---\nname: %s\ndescription: from the hive\n---\nhive\n' "$s" >"$tmp/src/skills/$s/SKILL.md"
done
printf 'hive-mind %s %s\nextras %s %s\n' "$tmp/core.git" "$(tip core)" "$tmp/extras.git" "$(tip extras)" >"$tmp/src/hive.lock"
bare "$tmp/src" remote

# clone_hive <remote> <dir>: a hive and its core, as the pointer's snippet brings a machine up; install
# and sync bring the other sources.
clone_hive() {
    git clone -q "$1" "$2" &&
        git clone -q "$(awk 'NR == 1 { print $2 }' "$2/hive.lock")" "$2/hive-mind" &&
        git -C "$2/hive-mind" checkout -q --detach "$(awk 'NR == 1 { print $3 }' "$2/hive.lock")"
}
machine() { mkdir -p "$tmp/$1/home" "$tmp/$1/cfg" && clone_hive "${2:-$tmp/remote.git}" "$tmp/$1/hive"; }
for m in a b c; do machine "$m"; done
# HIVE_SH runs bin/hive under another shell, as check.sh does with bash --posix for macOS's /bin/sh.
run() { m=$1; shift; HOME="$tmp/$m/home" CLAUDE_CONFIG_DIR="$tmp/$m/cfg" ${HIVE_SH:-} "$tmp/$m/hive/hive-mind/bin/hive" "$@"; }
memory_file() { # <machine> <file> <name> [body]
    printf -- '---\nname: %s\ndescription: about %s\nmetadata:\n  type: feedback\n  date: 2026-10-25\n---\n%s\n' \
        "$3" "$3" "${4:-body}" >"$tmp/$1/hive/memory/$2"
}
on_remote() { git --git-dir="$tmp/remote.git" "$@"; }
a="$tmp/a" b="$tmp/b" c="$tmp/c"

# --- install --------------------------------------------------------------------------------------

cat >"$a/cfg/settings.json" <<'EOF'
{"modelSettings": {"x": {"effortLevel": "high"}},
 "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo other"}]}]}}
EOF
cp "$a/cfg/settings.json" "$tmp/settings.orig"
mkdir -p "$a/cfg/skills"
cp -R "$a/hive/skills/hive-skill" "$a/cfg/skills/hive-skill" && touch "$a/cfg/skills/hive-skill/.DS_Store"
cp -R "$a/hive/skills/other-skill" "$a/cfg/skills/other-skill" && echo edited >>"$a/cfg/skills/other-skill/SKILL.md"
mkdir -p "$a/cfg/projects/-x/memory" && touch "$a/cfg/projects/-x/memory/old.md"

out=$(run a install 2>&1)
settings_has() { python3 -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$a/cfg/settings.json"; }
check "install sets autoMemoryDirectory" "settings_has \"s['autoMemoryDirectory'] == '$a/hive/memory'\""
check "install adds one SessionStart hook" "settings_has \"[h['command'] for g in s['hooks']['SessionStart'] for h in g['hooks']] == ['$a/hive/hive-mind/bin/hive sync --hook']\""
check "install adds Stop and SessionEnd hooks" "settings_has \"any(h['command'].endswith('save --background') for g in s['hooks']['Stop'] for h in g['hooks']) and len(s['hooks']['SessionEnd']) == 1\""
check "install adds the keep-alive: an asyncRewake Stop hook that outlasts its wait, a prompt and an end hook" "settings_has \"[(h.get('asyncRewake'), h['timeout']) for g in s['hooks']['Stop'] for h in g['hooks'] if h['command'].endswith(' keepalive stop')] == [(True, 7200)] and any(h['command'].endswith(' keepalive prompt') for g in s['hooks']['UserPromptSubmit'] for h in g['hooks']) and any(h['command'].endswith(' keepalive end') for g in s['hooks']['SessionEnd'] for h in g['hooks'])\""
check "install keeps other settings and hooks" "settings_has \"s['modelSettings'] == {'x': {'effortLevel': 'high'}} and s['hooks']['Stop'][0]['hooks'][0]['command'] == 'echo other'\""
cp "$a/cfg/settings.json" "$tmp/settings.first"
run a install >/dev/null 2>&1
check "install is idempotent" "cmp -s '$tmp/settings.first' '$a/cfg/settings.json'"
check "the hive's instructions are linked as a rules directory" "[ \"\$(readlink '$a/cfg/rules/hive')\" = '$a/hive/instructions' ]"
check "the core's instructions are linked as another" "[ \"\$(readlink '$a/cfg/rules/hive-mind')\" = '$a/hive/hive-mind/instructions' ]"
check "install clones the other sources at their pins" "[ \"\$(git -C '$a/hive/extras' rev-parse HEAD)\" = '$(tip extras)' ]"
check "a source's clone stays out of the hive's history" "[ -z \"\$(git -C '$a/hive' status --porcelain)\" ]"
check "an identical old skill copy becomes a link" "[ -L '$a/cfg/skills/hive-skill' ]"
check "an edited old skill copy is left alone" "[ ! -L '$a/cfg/skills/other-skill' ] && grep -q edited '$a/cfg/skills/other-skill/SKILL.md'"
check "install reports the skipped copy" "printf '%s' \"\$out\" | grep -q 'skipped: .*other-skill'"
check "install points at unloaded project memories" "printf '%s' \"\$out\" | grep -q '1 memory files under'"
run a install --force >/dev/null 2>&1
check "install --force links over an edited copy, keeping a backup" "[ -L '$a/cfg/skills/other-skill' ] && grep -q edited '$a'/cfg/hive-backup/*/other-skill/SKILL.md"
n_files=$(find "$a/hive/memory" -name '*.md' ! -name MEMORY.md -exec grep -L -E '^[[:space:]]+status:[[:space:]]*retired' {} + | wc -l | tr -d ' ')
n_lines=$(grep -c '^- \[' "$a/hive/memory/MEMORY.md")
check "the index lists all $n_files unretired memories once" "[ '$n_files' = '$n_lines' ]"
check "the index is ignored by git" "[ -z \"\$(git -C '$a/hive' status --porcelain)\" ]"

# `hive` by name: install links it into ~/.local/bin, and it finds its checkout through links.
check "install links hive into ~/.local/bin" "[ \"\$(readlink '$a/home/.local/bin/hive')\" = '$a/hive/hive-mind/bin/hive' ]"
check "install says when ~/.local/bin is not on the PATH" "printf '%s' \"\$out\" | grep -q 'local/bin is not on your PATH'"
check "hive run through its link finds its checkout" "HOME='$a/home' CLAUDE_CONFIG_DIR='$a/cfg' '$a/home/.local/bin/hive' status | grep -q '^hive       $a/hive '"
ln -s home/.local/bin/hive "$a/chain"
check "hive run through a chain of relative links finds its checkout" "HOME='$a/home' CLAUDE_CONFIG_DIR='$a/cfg' '$a/chain' status | grep -q '^hive       $a/hive '"
check "status says hive runs by name when it is on the PATH" "PATH='$a/home/.local/bin':\"\$PATH\" run a status | grep -q '^  ok    .hive. runs this hive'"
mkdir -p "$b/home/.local/bin" && echo "#!/bin/sh" >"$b/home/.local/bin/hive"

printf '{"autoMemoryDirectory": "/elsewhere"}\n' >"$b/cfg/settings.json"
check "install refuses to move a memory directory set elsewhere" "! run b install >/dev/null 2>&1"
rm "$b/cfg/settings.json"
out=$(run b install 2>&1)
check "install leaves another hive command alone" "[ ! -L '$b/home/.local/bin/hive' ] && grep -qx '#!/bin/sh' '$b/home/.local/bin/hive' && printf '%s' \"\$out\" | grep -q 'skipped: .*local/bin/hive exists'"

# --- save and sync --------------------------------------------------------------------------------

memory_file a feedback_new.md feedback-new
echo "local edit" >>"$a/hive/instructions/test.md"
run a save >/dev/null 2>&1
check "save pushes the new memory" "on_remote show main:memory/feedback_new.md >/dev/null 2>&1"
check "save commits nothing outside memory/ and decisions/" "[ \"\$(on_remote show --name-only --format= main)\" = memory/feedback_new.md ]"
check "save leaves other edits in the working tree" "git -C '$a/hive' diff --quiet -- instructions/test.md; [ \$? = 1 ]"
check "save names the change in the subject" "[ \"\$(on_remote log -1 --format=%s main)\" = 'memory: add feedback_new' ]"
check "save records where it ran" "on_remote log -1 --format=%b main | grep -q '^Hive-Host: '"
git -C "$a/hive" checkout -q -- instructions/test.md

out=$(run b sync --hook 2>&1)
check "a hook sync reports memory that arrived" "printf '%s' \"\$out\" | grep -qF -- '- [feedback-new](feedback_new.md) — about feedback-new (2026-10-25)'"
check "the arrived memory is in the index" "grep -qF 'feedback_new.md' '$b/hive/memory/MEMORY.md'"
out=$(run b sync --hook 2>&1)
check "a hook sync with nothing new prints nothing" "[ -z \"\$out\" ]"

memory_file a feedback_from_a.md from-a
memory_file b feedback_from_b.md from-b
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "saves from two machines both land" "on_remote show main:memory/feedback_from_a.md >/dev/null 2>&1 && on_remote show main:memory/feedback_from_b.md >/dev/null 2>&1"
run a sync >/dev/null 2>&1
check "both machines end on the same commit" "[ \"\$(git -C '$a/hive' rev-parse HEAD)\" = \"\$(git -C '$b/hive' rev-parse HEAD)\" ]"

mkdir -p "$a/hive/decisions"
printf '# A decision\n' >"$a/hive/decisions/2026-10-25-test.md"
run a save >/dev/null 2>&1
out=$(run b sync --hook 2>&1)
check "decisions are pushed" "on_remote show main:decisions/2026-10-25-test.md >/dev/null 2>&1"
check "decisions are not reported to sessions, which never load them" "[ -z \"\$out\" ]"

# Background save returns at once and pushes behind the session's back.
memory_file a feedback_bg.md bg
t0=$(date +%s)
run a save --background
t1=$(date +%s)
check "background save returns within a second" "[ \$((t1 - t0)) -le 1 ]"
i=0; while [ $i -lt 50 ] && ! on_remote show main:memory/feedback_bg.md >/dev/null 2>&1; do sleep 0.2; i=$((i + 1)); done
check "background save pushes" "on_remote show main:memory/feedback_bg.md >/dev/null 2>&1"
run b sync >/dev/null 2>&1

# Several sessions on one machine saving at the same moment share one checkout: the lock serialises
# them and nothing is lost.
memory_file a feedback_p1.md p1
memory_file a feedback_p2.md p2
run a save >/dev/null 2>&1 &
run a save >/dev/null 2>&1 &
run a save >/dev/null 2>&1 &
wait
check "concurrent saves on one machine all land" "on_remote show main:memory/feedback_p1.md >/dev/null 2>&1 && on_remote show main:memory/feedback_p2.md >/dev/null 2>&1"
check "concurrent saves leave no lock behind" "[ ! -d '$a/hive/.git/hive/lock' ]"
check "concurrent saves leave nothing uncommitted" "[ -z \"\$(git -C '$a/hive' status --porcelain)\" ]"
run b sync >/dev/null 2>&1

# --- concurrency: conflicts never stop a save, and nothing written is lost ---------------------------

no_markers() { ! on_remote grep -q -e '^<<<<<<<' -e '^>>>>>>>' main -- memory decisions; }

# The same memory changed in the same place on two machines: both versions are kept, flagged.
memory_file a feedback_from_a.md from-a "version a"
memory_file b feedback_from_a.md from-a "version b"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1; rc=$?
check "a conflicting save succeeds" "[ $rc = 0 ]"
check "a conflict keeps both versions" "on_remote show main:memory/feedback_from_a.md | grep -q 'version a' && on_remote show main:memory/feedback_from_a.md | grep -q 'version b'"
check "a conflict is marked for reconciliation" "on_remote show main:memory/feedback_from_a.md | grep -q '^<!-- hive:sibling -->'"
check "a conflict leaves no conflict markers" "no_markers"
check "the index flags the file with two versions" "grep 'feedback_from_a.md' '$b/hive/memory/MEMORY.md' | grep -qF '[2 versions]'"
check "the checkout sessions read is moved to the result" "[ \"\$(git -C '$b/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ]"
run a sync >/dev/null 2>&1

# Changes to different parts of one memory merge cleanly, with no marker.
printf -- '---\nname: lines\ndescription: d\nmetadata:\n  type: feedback\n---\nfirst\n2\n3\n4\n5\nlast\n' >"$a/hive/memory/feedback_lines.md"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
sed 's/^first$/first, from a/' "$a/hive/memory/feedback_lines.md" >"$tmp/x" && mv "$tmp/x" "$a/hive/memory/feedback_lines.md"
sed 's/^last$/last, from b/' "$b/hive/memory/feedback_lines.md" >"$tmp/x" && mv "$tmp/x" "$b/hive/memory/feedback_lines.md"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "separate changes to one memory merge cleanly" "on_remote show main:memory/feedback_lines.md | grep -q 'first, from a' && on_remote show main:memory/feedback_lines.md | grep -q 'last, from b' && ! on_remote show main:memory/feedback_lines.md | grep -q sibling"

# Claude Code stamps `modified:` on every write. Separate changes still merge, keeping the newer stamp,
# here the one that landed first.
printf -- '---\nname: stamped\ndescription: d\nmetadata:\n  type: feedback\n  modified: 2026-10-30T08:00:00.000Z\n---\nfirst\n2\n3\n4\n5\nlast\n' >"$a/hive/memory/feedback_stamped.md"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
sed 's/^first$/first, from a/; s/T08:00/T09:30/' "$a/hive/memory/feedback_stamped.md" >"$tmp/x" && mv "$tmp/x" "$a/hive/memory/feedback_stamped.md"
sed 's/^last$/last, from b/; s/T08:00/T09:00/' "$b/hive/memory/feedback_stamped.md" >"$tmp/x" && mv "$tmp/x" "$b/hive/memory/feedback_stamped.md"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "separate changes to a stamped memory merge cleanly" "on_remote show main:memory/feedback_stamped.md | grep -q 'first, from a' && on_remote show main:memory/feedback_stamped.md | grep -q 'last, from b' && ! on_remote show main:memory/feedback_stamped.md | grep -q sibling"
check "the merged memory keeps the newer stamp, once" "[ \"\$(on_remote show main:memory/feedback_stamped.md | grep '^  modified:')\" = '  modified: 2026-10-30T09:30:00.000Z' ]"
run a sync >/dev/null 2>&1

# Re-confirming a stamped memory on two machines changes date, verified and the stamp: the newer wins.
printf -- '---\nname: stamped-confirmed\ndescription: d\nmetadata:\n  type: feedback\n  date: 2026-10-01\n  verified: read it\n  modified: 2026-10-01T08:00:00.000Z\n---\nbody\n' >"$a/hive/memory/feedback_stamped_confirmed.md"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
sed 's/2026-10-01/2026-10-20/g; s/read it/ran it on a/' "$a/hive/memory/feedback_stamped_confirmed.md" >"$tmp/x" && mv "$tmp/x" "$a/hive/memory/feedback_stamped_confirmed.md"
sed 's/2026-10-01/2026-10-10/g; s/read it/ran it on b/' "$b/hive/memory/feedback_stamped_confirmed.md" >"$tmp/x" && mv "$tmp/x" "$b/hive/memory/feedback_stamped_confirmed.md"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "a stamped re-confirmation on two machines keeps the newer, not two versions" "on_remote show main:memory/feedback_stamped_confirmed.md | grep -q 'ran it on a' && ! on_remote show main:memory/feedback_stamped_confirmed.md | grep -q sibling"
run a sync >/dev/null 2>&1

# The same new memory written on two machines, as when two sessions learn one thing.
memory_file a feedback_same_lesson.md same-lesson "learned on a"
memory_file b feedback_same_lesson.md same-lesson "learned on b"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "the same new memory from two machines keeps both" "on_remote show main:memory/feedback_same_lesson.md | grep -q 'learned on a' && on_remote show main:memory/feedback_same_lesson.md | grep -q 'learned on b'"
run a sync >/dev/null 2>&1

# An edit beats a delete, whichever lands first.
memory_file a feedback_contested.md contested "original"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
rm "$a/hive/memory/feedback_contested.md"
memory_file b feedback_contested.md contested "edited on b"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "an edit beats an earlier delete" "on_remote show main:memory/feedback_contested.md | grep -q 'edited on b'"
run a sync >/dev/null 2>&1
memory_file a feedback_contested.md contested "edited on a"
rm "$b/hive/memory/feedback_contested.md"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "an edit beats a later delete" "on_remote show main:memory/feedback_contested.md | grep -q 'edited on a'"
run a sync >/dev/null 2>&1

# The checkout is never rewritten under someone's uncommitted change: here an instruction being edited
# in place while a merged pull request changes the same file.
git clone -q "$tmp/remote.git" "$tmp/pr"
echo "merged change" >>"$tmp/pr/instructions/test.md"
git -C "$tmp/pr" commit -qam "Change working.md" && git -C "$tmp/pr" push -q origin main
echo "edit in progress" >>"$b/hive/instructions/test.md"
memory_file b feedback_during_edit.md during-edit
out=$(run b sync --hook 2>&1)
check "memory still goes out while the checkout cannot move" "on_remote show main:memory/feedback_during_edit.md >/dev/null 2>&1"
check "an uncommitted edit is never overwritten" "grep -q 'edit in progress' '$b/hive/instructions/test.md' && ! grep -q 'merged change' '$b/hive/instructions/test.md'"
check "the session is told the checkout stays behind, and which file" "printf '%s' \"\$out\" | grep -q 'memory is pushed, but this checkout stays at .*instructions/test.md has uncommitted changes'"
git -C "$b/hive" checkout -q -- instructions/test.md
run b sync >/dev/null 2>&1
check "once the edit is gone the next sync catches up" "grep -q 'merged change' '$b/hive/instructions/test.md' && [ ! -s '$b/hive/.git/hive/error' ]"
run a sync >/dev/null 2>&1

# Two machines back up the Worklog at once: one snapshot wins whole, never two fenced together.
mkdir -p "$a/hive/worklog/data/items" "$b/hive/worklog/data/items"
for i in 1 2 3 4 5 6; do printf '{"title": "item %s"}\n' "$i" >"$a/hive/worklog/data/items/i$i.json"; done
run a save >/dev/null 2>&1
check "a large snapshot is summarised in the subject" "[ \"\$(on_remote log -1 --format=%s main)\" = 'worklog: add 6 files' ]"
run b sync >/dev/null 2>&1
printf '{"title": "item 1", "status": "done"}\n' >"$a/hive/worklog/data/items/i1.json"
printf '{"title": "item 1", "status": "dropped"}\n' >"$b/hive/worklog/data/items/i1.json"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "a Worklog snapshot conflict keeps one whole version" "on_remote show main:worklog/data/items/i1.json | python3 -m json.tool >/dev/null 2>&1 && ! on_remote show main:worklog/data/items/i1.json | grep -q sibling"
run a sync >/dev/null 2>&1

# Re-confirming a memory on two machines changes only date and verified: the newer one wins, whole.
printf -- '---\nname: confirmed\ndescription: d\nmetadata:\n  type: feedback\n  date: 2026-10-01\n  verified: read it\n---\nbody\n' >"$a/hive/memory/feedback_confirmed.md"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
sed 's/2026-10-01/2026-10-20/; s/read it/ran it on a/' "$a/hive/memory/feedback_confirmed.md" >"$tmp/x" && mv "$tmp/x" "$a/hive/memory/feedback_confirmed.md"
sed 's/2026-10-01/2026-10-10/; s/read it/ran it on b/' "$b/hive/memory/feedback_confirmed.md" >"$tmp/x" && mv "$tmp/x" "$b/hive/memory/feedback_confirmed.md"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1
check "a re-confirmation on two machines keeps the newer, not two versions" "on_remote show main:memory/feedback_confirmed.md | grep -q 'ran it on a' && ! on_remote show main:memory/feedback_confirmed.md | grep -q sibling"
run a sync >/dev/null 2>&1

# A memory that looks like it holds a secret never reaches GitHub.
memory_file a feedback_leaky.md leaky "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
memory_file a feedback_clean.md clean
run a save >/dev/null 2>&1
check "a memory holding a secret is not committed" "! on_remote show main:memory/feedback_leaky.md >/dev/null 2>&1"
check "the rest of the save still goes out" "on_remote show main:memory/feedback_clean.md >/dev/null 2>&1"
check "status names the file that holds a secret" "run a status | grep -q 'not committed: memory/feedback_leaky.md looks like it holds a secret'"
rm "$a/hive/memory/feedback_leaky.md"; run a save >/dev/null 2>&1

# Claude Code's own background consolidation leaves a lock in the memory folder; it is not committed.
touch "$a/hive/memory/.consolidate-lock"
run a save >/dev/null 2>&1
check "auto-dream's lock is not committed" "! on_remote show main:memory/.consolidate-lock >/dev/null 2>&1"
check "install turns auto-dream off" "python3 -c \"import json,sys; sys.exit(json.load(open(sys.argv[1])).get('autoDreamEnabled') is not False)\" '$a/cfg/settings.json'"
check "install turns idle compaction off" "python3 -c \"import json,sys; sys.exit(json.load(open(sys.argv[1])).get('idleCompaction') is not False)\" '$a/cfg/settings.json'"

# A refresh of the Worklog backup that comes back mostly empty does not replace the backup.
mkdir -p "$a/hive/worklog/data/items"
i=0; while [ $i -lt 30 ]; do printf '{"title": "t%s"}\n' "$i" >"$a/hive/worklog/data/items/w$i.json"; i=$((i + 1)); done
run a save >/dev/null 2>&1
n_backup=$(on_remote ls-tree -r --name-only main -- worklog/data | grep -c '\.json$')
rm -rf "$a/hive/worklog/data"/*; mkdir -p "$a/hive/worklog/data/items"; printf '{"title": "only"}\n' >"$a/hive/worklog/data/items/w0.json"
run a save >/dev/null 2>&1
check "a backup refresh that comes back nearly empty is not committed" "[ \"\$(on_remote ls-tree -r --name-only main -- worklog/data | grep -c '\\.json$')\" = '$n_backup' ]"
check "status says why the backup was not committed" "run a status | grep -q 'the Worklog backup would shrink from'"
git -C "$a/hive" checkout -q -- worklog && rm -f "$a/hive/.git/hive/error"; run a save >/dev/null 2>&1; run b sync >/dev/null 2>&1

# The index keeps within its budget: lines are capped, retired memories are left out, and an index past
# its budget says how many it left out.
printf -- '---\nname: long\ndescription: %s\nmetadata:\n  type: feedback\n  date: 2026-10-25\n---\nx\n' "$(printf 'word %.0s' $(seq 1 80))" >"$tmp/long.md"
cp "$tmp/long.md" "$a/hive/memory/feedback_long.md"
printf -- '---\nname: gone\ndescription: retired one\nmetadata:\n  type: feedback\n  status: retired\n---\nx\n' >"$a/hive/memory/feedback_retired.md"
run a index
check "no index line is longer than 180 characters" "awk 'length > 180 { bad = 1 } END { exit bad }' '$a/hive/memory/MEMORY.md'"
check "a long description is cut with an ellipsis" "grep 'feedback_long.md' '$a/hive/memory/MEMORY.md' | grep -q '…'"
check "a retired memory is left out of the index" "! grep -q 'feedback_retired.md' '$a/hive/memory/MEMORY.md'"
printf -- '---\nname: firm\ndescription: d\nmetadata:\n  type: feedback\n  firmness: "rule"\n---\nx\n' >"$a/hive/memory/feedback_firm.md"
printf -- '---\nname: soft\ndescription: d\nmetadata:\n  type: feedback\n  firmness: default\n---\nx\n' >"$a/hive/memory/feedback_soft.md"
run a index
# section_of <file>: the index heading a memory is listed under.
section_of() { awk -v f="($1)" '/^## / { s = $0 } index($0, f) { print s; exit }' "$a/hive/memory/MEMORY.md"; }
check "the index lists a feedback rule under the rules" "[ \"\$(section_of feedback_firm.md)\" = '## Feedback: rules' ]"
check "the index lists a default, and feedback that says neither, under the defaults" "section_of feedback_soft.md | grep -q '^## Feedback: defaults' && section_of feedback_long.md | grep -q '^## Feedback: defaults'"
check "the index lists the rules before the defaults" "grep '^## Feedback' '$a/hive/memory/MEMORY.md' | head -n 1 | grep -qx '## Feedback: rules'"
mkdir -p "$tmp/many/hive/memory" "$tmp/many/hive/hive-mind"
i=0; while [ $i -lt 250 ]; do cp "$tmp/long.md" "$tmp/many/hive/memory/feedback_m$i.md"; i=$((i + 1)); done
cp -R "$a/hive/hive-mind/bin" "$tmp/many/hive/hive-mind/" && cp "$a/hive/hive.lock" "$tmp/many/hive/" && git -C "$tmp/many/hive" init -q
"$tmp/many/hive/hive-mind/bin/hive" index
check "an index past its budget stays under Claude Code's limits" "[ \$(wc -l <'$tmp/many/hive/memory/MEMORY.md') -lt 200 ] && [ \$(wc -c <'$tmp/many/hive/memory/MEMORY.md') -lt 25000 ]"
check "an index past its budget says how many it left out" "grep -q 'more memories are not listed' '$tmp/many/hive/memory/MEMORY.md'"
rm "$a/hive/memory/feedback_long.md" "$a/hive/memory/feedback_retired.md" "$a/hive/memory/feedback_firm.md" "$a/hive/memory/feedback_soft.md"; run a save >/dev/null 2>&1; run b sync >/dev/null 2>&1

# --- crashes, signals and odd inputs ---------------------------------------------------------------

# A push that failed left the private worktree ahead, and a crashed git left its index lock: the next
# save must still push what it committed, never the stale result.
memory_file b feedback_diverge.md diverge
run b save >/dev/null 2>&1
memory_file a feedback_l1.md l1
printf '#!/bin/sh\nexit 1\n' >"$tmp/remote.git/hooks/pre-receive" && chmod +x "$tmp/remote.git/hooks/pre-receive"
run a save >/dev/null 2>&1
rm "$tmp/remote.git/hooks/pre-receive"
touch "$a/hive/.git/worktrees/worktree/index.lock" 2>/dev/null || true
memory_file a feedback_l2.md l2
run a save >/dev/null 2>&1; rc=$?
check "after a failed push and a crashed git, the next save still pushes everything" "[ $rc = 0 ] && on_remote show main:memory/feedback_l1.md >/dev/null 2>&1 && on_remote show main:memory/feedback_l2.md >/dev/null 2>&1"
check "and the checkout still has what it committed" "[ -f '$a/hive/memory/feedback_l2.md' ]"
run b sync >/dev/null 2>&1

# A lock whose owner is gone is broken; one whose owner is alive is respected.
printf '999999-1-1\n' >"$a/hive/.git/hive/lock"
memory_file a feedback_after_crash.md after-crash
run a save >/dev/null 2>&1
check "a lock left by a dead process is broken" "on_remote show main:memory/feedback_after_crash.md >/dev/null 2>&1 && [ ! -e '$a/hive/.git/hive/lock' ]"
sleep 30 & alive=$!
printf '%s-1-1\n' "$alive" >"$a/hive/.git/hive/lock"
t0=$(date +%s); out=$(run a sync --hook 2>&1); t1=$(date +%s)
check "a lock held by a live process is respected, and a session start waits only briefly ($((t1 - t0))s)" "[ -z \"\$out\" ] && [ \$((t1 - t0)) -le 7 ] && grep -q '^$alive-' '$a/hive/.git/hive/lock'"
kill "$alive" 2>/dev/null; wait "$alive" 2>/dev/null; rm -f "$a/hive/.git/hive/lock"

# SIGTERM (a hook's timeout) stops the run and frees the lock; it does not carry on unlocked.
git -C "$a/hive" config remote.origin.uploadpack "sleep 3; git-upload-pack"
memory_file a feedback_term.md term
HOME="$a/home" CLAUDE_CONFIG_DIR="$a/cfg" "$a/hive/hive-mind/bin/hive" save >/dev/null 2>&1 & pid=$!
sleep 1; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
check "SIGTERM ends the run" "[ $rc = 143 ]"
check "SIGTERM frees the lock" "[ ! -e '$a/hive/.git/hive/lock' ]"
git -C "$a/hive" config --unset remote.origin.uploadpack
run a save >/dev/null 2>&1

# A memory with a non-ASCII name conflicts like any other.
memory_file a feedback_påske.md påske "from a"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
memory_file a feedback_påske.md påske "a again"
memory_file b feedback_påske.md påske "b again"
run a save >/dev/null 2>&1
run b save >/dev/null 2>&1; rc=$?
check "a conflict in a non-ASCII name keeps both versions" "[ $rc = 0 ] && on_remote show 'main:memory/feedback_påske.md' | grep -q 'a again' && on_remote show 'main:memory/feedback_påske.md' | grep -q 'b again'"
run a sync >/dev/null 2>&1

# Names that differ only in case would be one file on a Mac.
memory_file a feedback_Case.md case-one
run a save >/dev/null 2>&1
memory_file a feedback_case.md case-two
run a save >/dev/null 2>&1
touch "$tmp/case-probe"
check_where "[ ! -e '$tmp/CASE-PROBE' ]" "this filesystem ignores case" "a memory whose name differs only in case is not committed" "! on_remote show main:memory/feedback_case.md >/dev/null 2>&1 && run a status | grep -q 'differs only in case'"
rm "$a/hive/memory/feedback_case.md"; rm -f "$a/hive/.git/hive/error"

# While the checkout cannot move, saves do not combine the same pushed commit again and again.
memory_file a feedback_stuck.md stuck "version a"
run a save >/dev/null 2>&1 && run b sync >/dev/null 2>&1
git clone -q "$tmp/remote.git" "$tmp/pr2" && echo "pr2" >>"$tmp/pr2/instructions/other.md" && git -C "$tmp/pr2" commit -qam pr2 && git -C "$tmp/pr2" push -q origin main
memory_file a feedback_stuck.md stuck "version a2"
run a save >/dev/null 2>&1
echo "local edit" >>"$b/hive/instructions/other.md"
memory_file b feedback_stuck.md stuck "version b2"
for i in 1 2 3; do run b save >/dev/null 2>&1; done
check "a stuck checkout combines a conflict once, not on every save" "[ \"\$(on_remote show main:memory/feedback_stuck.md | grep -c '^<!-- hive:sibling')\" = 1 ]"
git -C "$b/hive" checkout -q -- instructions/other.md; run b sync >/dev/null 2>&1; run a sync >/dev/null 2>&1
check "once the edit is gone the stuck checkout catches up" "[ \"\$(git -C '$b/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ] && [ ! -e '$b/hive/.git/hive/pushed' ]"

# A user's global git setup does not leak in: here, signing every commit with a program that fails.
git config --file "$tmp/gitconfig" commit.gpgsign true; git config --file "$tmp/gitconfig" gpg.program false
memory_file a feedback_signed.md signed
run a save >/dev/null 2>&1; rc=$?
check "a global commit.gpgsign does not break saving" "[ $rc = 0 ] && on_remote show main:memory/feedback_signed.md >/dev/null 2>&1"
git config --file "$tmp/gitconfig" --unset commit.gpgsign; git config --file "$tmp/gitconfig" --unset gpg.program
run b sync >/dev/null 2>&1

# Stress: three machines, four sessions each, all saving at once. Every session writes a memory of its
# own, and every machine writes the same shared memory differently.
for m in p q r; do machine "$m"; done
for m in p q r; do
    memory_file "$m" feedback_shared.md shared "shared, from $m"
    for n in 1 2 3 4; do
        memory_file "$m" "feedback_${m}_$n.md" "$m-$n"
        run "$m" save >/dev/null 2>&1 &
    done
done
wait
for m in p q r; do run "$m" sync >/dev/null 2>&1; done
for m in p q r; do run "$m" sync >/dev/null 2>&1; done
missing=""
for m in p q r; do for n in 1 2 3 4; do
    on_remote show "main:memory/feedback_${m}_$n.md" >/dev/null 2>&1 || missing="$missing ${m}_$n"
done; done
check "stress: every session's memory landed" "[ -z '$missing' ]"
check "stress: the shared memory keeps every machine's version" "(for m in p q r; do on_remote show main:memory/feedback_shared.md | grep -q \"shared, from \$m\" || exit 1; done)"
check "stress: no conflict markers" "no_markers"
check "stress: all machines converge" "[ \"\$(git -C '$tmp/p/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ] && [ \"\$(git -C '$tmp/q/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ] && [ \"\$(git -C '$tmp/r/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ]"
check "stress: no locks, pending saves, rebases or errors left" "(for m in p q r; do d='$tmp'/\$m/hive/.git; [ ! -e \$d/hive/lock ] && [ ! -e \$d/hive/pending ] && [ ! -s \$d/hive/error ] && [ ! -d \$d/worktrees/worktree/rebase-merge ] || exit 1; done)"
check "stress: nothing left uncommitted" "(for m in p q r; do [ -z \"\$(git -C '$tmp'/\$m/hive status --porcelain)\" ] || exit 1; done)"
run a sync >/dev/null 2>&1
run b sync >/dev/null 2>&1

# --- edge cases -----------------------------------------------------------------------------------

git -C "$b/hive" checkout -q -b experiment
memory_file b feedback_offmain.md offmain
out=$(run b sync --hook 2>&1)
check "a checkout off main does not sync, and says so" "printf '%s' \"\$out\" | grep -q 'checkout is on experiment, not main'"
check "a checkout off main does not commit memory onto the branch" "[ \"\$(git -C '$b/hive' rev-parse experiment)\" = \"\$(git -C '$b/hive' rev-parse main)\" ]"
git -C "$b/hive" checkout -q main && rm -f "$b/hive/.git/hive/error"
run b sync >/dev/null 2>&1
check "back on main, the waiting memory is saved" "on_remote show main:memory/feedback_offmain.md >/dev/null 2>&1"

mv "$tmp/remote.git" "$tmp/remote.gone"
out=$(run b sync --hook 2>&1); rc=$?
check "offline: the hook sync says it works from the local copy" "printf '%s' \"\$out\" | grep -q 'sync failed: fetch failed.*local copy'"
check "offline: the hook sync exits 0" "[ $rc = 0 ]"
mv "$tmp/remote.gone" "$tmp/remote.git"
rm -f "$b/hive/.git/hive/error"

# A machine whose first session runs the hook before anything was linked (a fresh sandbox).
out=$(run c sync --hook 2>&1)
check "a cold session is told it loaded nothing" "printf '%s' \"\$out\" | grep -q 'started before the hive was linked'"
check "a cold session is pointed at the instructions" "printf '%s' \"\$out\" | grep -qx -- '- $c/hive/instructions/test.md'"
check "a cold session is pointed at the core's instructions" "printf '%s' \"\$out\" | grep -qx -- '- $c/hive/hive-mind/instructions/hive.md'"
check "a cold session is pointed at the memory index" "printf '%s' \"\$out\" | grep -qx -- '- $c/hive/memory/MEMORY.md'"
check "the cold report fits a hook's output limit" "[ \$(printf '%s' \"\$out\" | wc -c) -lt 2000 ]"
check "a cold sync links the rules" "[ -L '$c/cfg/rules/hive' ]"
out=$(run c sync --hook 2>&1)
check "the next session is warm and quiet" "[ -z \"\$out\" ]"

# A sandbox with only the pointer (sandbox/host-instructions.md): the agent runs its snippet
# in the first session, and from then on the hive is installed and the session start is quiet.
snippet() { # <file> <heading>: the first sh block after the heading, pointed at the test remote
    awk -v h="$2" 'index($0, h) == 1 { f = 1 } f && /^```sh$/ { g = 1; next } g && /^```$/ { exit } g' "$1" \
        | sed "s|https://github.com/[A-Za-z0-9._/-]*|$tmp/remote.git|"
}
snippet "$hive_src/sandbox/host-instructions.md" "## The hive on this machine" >"$tmp/pointer.sh"
mkdir -p "$tmp/d/home"
HOME="$tmp/d/home" CLAUDE_CONFIG_DIR="$tmp/d/home/.claude" sh "$tmp/pointer.sh" >/dev/null 2>&1; rc=$?
check "the pointer's snippet brings the hive up" "[ $rc = 0 ] && [ -s '$tmp/pointer.sh' ] && [ -L '$tmp/d/home/.claude/rules/hive' ] && grep -q autoMemoryDirectory '$tmp/d/home/.claude/settings.json'"
out=$(HOME="$tmp/d/home" CLAUDE_CONFIG_DIR="$tmp/d/home/.claude" "$tmp/d/home/hive/hive-mind/bin/hive" sync --hook 2>&1)
check "after the pointer's snippet the next session start is quiet" "[ -z \"\$out\" ]"
HOME="$tmp/d/home" CLAUDE_CONFIG_DIR="$tmp/d/home/.claude" sh "$tmp/pointer.sh" >/dev/null 2>&1; rc=$?
check "the pointer's snippet is safe to run again" "[ $rc = 0 ]"
# With the hive's sandbox home, Claude Code creates the empty memory directory before the first clone.
mkdir -p "$tmp/e/home/hive/memory"
HOME="$tmp/e/home" CLAUDE_CONFIG_DIR="$tmp/e/home/.claude" sh "$tmp/pointer.sh" >/dev/null 2>&1; rc=$?
check "the pointer's snippet clones over the empty memory directory Claude Code made" "[ $rc = 0 ] && [ -L '$tmp/e/home/.claude/rules/hive' ]"

# agentd copies the hive's sandbox/home over a sandbox's home every 30 seconds, so its settings must be
# what install writes there, or the two undo each other.
machine h
run h install >/dev/null 2>&1
sed "s|$tmp/h/hive|/home/agent/hive|g" "$tmp/h/cfg/settings.json" >"$tmp/h/sandbox-settings.json"
check "install writes the sandboxes' home: what install writes in a sandbox" "cmp -s '$tmp/h/sandbox-settings.json' '$tmp/h/hive/sandbox/home/.claude/settings.json'"
check "and keeps it out of the hive's history" "[ -z \"\$(git -C '$tmp/h/hive' status --porcelain)\" ]"

# In a sandbox, a skill the agent's definition ships wins over the hive's of the same name: agentd's,
# even with --force, and no conflict.
machine s && mkdir -p "$tmp/s/cfg/skills/hive-skill"
echo "agentd's copy" >"$tmp/s/cfg/skills/hive-skill/SKILL.md"
out=$(AGENT_NAME=x run s install --force 2>&1)
check "in a sandbox, the agent's own skill is never taken over" "[ ! -L '$tmp/s/cfg/skills/hive-skill' ] && grep -q \"agentd's copy\" '$tmp/s/cfg/skills/hive-skill/SKILL.md'"
check "in a sandbox, install keeps the agent's own skill without calling it a conflict" "! printf '%s' \"\$out\" | grep -q -e skipped -e hive-skill"
out=$(AGENT_NAME=x run s status 2>&1)
check "in a sandbox, status counts the agent's own skill as linked and names it" "printf '%s' \"\$out\" | grep -q 'ok .*rules and skills are linked.*own in place of the hive.s: hive-skill' && ! printf '%s' \"\$out\" | grep -q 'link(s) missing'"

# The guard refuses edits to the live checkout outside memory/, decisions/ and worklog/, however the
# path is spelled, and allows everything else.
guard() { printf '{"tool_name": "Edit", "tool_input": {"file_path": "%s"}}' "$1" | run a guard; }
check "install adds the guard hook" "settings_has \"any(h['command'].endswith(' guard') for g in s['hooks']['PreToolUse'] for h in g['hooks'])\""
check "the guard refuses an instruction edit through the rules link" "guard '$a/cfg/rules/hive/test.md' | grep -q '\"permissionDecision\": \"deny\"'"
check "the guard refuses a skill edit through its link" "guard '$a/cfg/skills/hive-skill/SKILL.md' | grep -q deny"
check "the guard refuses bin/hive in the checkout" "guard '$a/hive/hive-mind/bin/hive' | grep -q deny"
check "the guard allows memory" "[ -z \"\$(guard '$a/hive/memory/feedback_x.md')\" ]"
check "the guard allows decisions, tidy logs and the Worklog backup" "[ -z \"\$(guard '$a/hive/decisions/x.md')\" ] && [ -z \"\$(guard '$a/hive/decisions/tidy/x.md')\" ] && [ -z \"\$(guard '$a/hive/worklog/README.md')\" ]"
check "the guard allows a worktree of the hive" "[ -z \"\$(guard '$a/hive-topic/instructions/test.md')\" ]"
check "the guard allows files elsewhere" "[ -z \"\$(guard /tmp/elsewhere.md)\" ]"
check "the guard allows on input it cannot read" "[ -z \"\$(echo 'not json' | run a guard)\" ] && echo 'not json' | run a guard"

# status checks the machine against SETUP.md.
printf '# Mine\n\n## Test instructions\n\nold copy\n' >"$a/cfg/CLAUDE.md"
out=$(run a status 2>&1)
check "status confirms the install" "printf '%s' \"\$out\" | grep -q '^  ok    Claude Code settings use the hive'"
check "status flags a section loaded twice" "printf '%s' \"\$out\" | grep -q '^  fix   .*repeats hive sections, so they load twice: Test instructions'"
check "status notes unimported memories" "printf '%s' \"\$out\" | grep -q '^  note  1 old per-project memory'"
printf '# Mine\n\n### Test instructions\n' >"$a/cfg/CLAUDE.md"
check "status matches a repeated section at any heading level" "run a status | grep -q 'load twice: Test instructions'"
echo "edit" >>"$a/hive/instructions/test.md"
check "status flags uncommitted changes that would block incoming ones" "run a status | grep -q '^  fix   uncommitted changes outside memory/.*instructions/test.md'"
git -C "$a/hive" checkout -q -- instructions/test.md
check "status says how old the Worklog backup is" "run a status | grep -q 'the Worklog backup is .* old'"
out=$(AGENT_NAME=x run a status 2>&1)
check "inside a sandbox, status flags a missing pointer" "printf '%s' \"\$out\" | grep -q '^  fix   this sandbox.s instructions lack the hive.s pointer'"
cp "$a/hive/sandbox/host-instructions.md" "$a/cfg/CLAUDE.md"
check "inside a sandbox, status confirms the pointer" "AGENT_NAME=x run a status | grep -q '^  ok    this sandbox gets the hive.s pointer'"
check "the pointer is not mistaken for a duplicate" "! AGENT_NAME=x run a status | grep -q 'repeats hive sections'"
cp "$a/cfg/settings.json" "$tmp/settings.installed"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['hooks']['Stop'].reverse(); json.dump(s, open(p, 'w'))" "$a/cfg/settings.json"
check "status ignores where the hive's hooks sit among others" "run a status | grep -q '^  ok    Claude Code settings use the hive'"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); del s['idleCompaction']; json.dump(s, open(p, 'w'))" "$a/cfg/settings.json"
check "status flags settings older than the checkout" "run a status | grep -q '^  fix   Claude Code settings differ from what this hive installs: run .* install (\"A machine\")'"
check "in a sandbox, status says to sync the hive on the host" "AGENT_NAME=x run a status | grep -q 'sync the hive on the host'"
echo '{"theme": "dark"}' >"$a/cfg/settings.json"
check "in a sandbox, status names the agent's home when the settings lack the hive" "AGENT_NAME=x run a status | grep -q '^  fix   Claude Code settings do not use the hive: .*point this agent.s home at the hive.s sandbox/home'"
cp "$tmp/settings.installed" "$a/cfg/settings.json"

# --- sync keeps the settings up to what the checkout installs ---------------------------------------

drop() { # <keys and hook events to remove from a's settings>
    python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p))
for k in sys.argv[2:]: s.pop(k, None); s['hooks'].pop(k, None)
json.dump(s, open(p, 'w'))" "$a/cfg/settings.json" "$@"
}
inode() { ls -i "$1" | awk '{ print $1 }'; }
before=$(inode "$a/cfg/settings.json")
out=$(run a sync --hook 2>&1)
check "a sync leaves current settings untouched" "[ \"\$(inode '$a/cfg/settings.json')\" = '$before' ] && cmp -s '$tmp/settings.installed' '$a/cfg/settings.json'"
drop autoDreamEnabled PreToolUse
out=$(run a sync --hook 2>&1)
check "a session-start sync puts back what install writes" "settings_has \"s['autoDreamEnabled'] is False and any(h['command'].endswith(' guard') for g in s['hooks']['PreToolUse'] for h in g['hooks'])\""
check "and keeps other settings and hooks" "settings_has \"s['modelSettings'] == {'x': {'effortLevel': 'high'}} and any(h['command'] == 'echo other' for g in s['hooks']['Stop'] for h in g['hooks'])\""
check "and tells the session nothing, but logs what changed" "[ -z \"\$out\" ] && grep -q 'updated .*settings.json .*(autoDreamEnabled, PreToolUse hooks)' '$a/hive/.git/hive/log'"
drop idleCompaction
out=$(run a sync 2>&1)
check "a sync run by hand says what it updated" "printf '%s' \"\$out\" | grep -q '^hive: updated .*settings.json to what this hive installs (idleCompaction)'"
drop idleCompaction
out=$(export AGENT_NAME=x; run a sync --hook 2>&1)
check "in a sandbox, sync leaves the settings to agentd" "[ -z \"\$out\" ] && ! settings_has \"'idleCompaction' in s\""
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['autoMemoryDirectory'] = '/elsewhere'; json.dump(s, open(p, 'w'))" "$a/cfg/settings.json"
run a sync --hook >/dev/null 2>&1
check "sync leaves an autoMemoryDirectory pointed elsewhere alone" "settings_has \"s['autoMemoryDirectory'] == '/elsewhere' and 'idleCompaction' not in s\""
# A hand edit that broke the file.
{ cat "$tmp/settings.installed"; echo '}'; } >"$a/cfg/settings.json"
out=$(run a sync --hook 2>&1); rc=$?
check "settings that are not JSON are reported, and the sync still succeeds" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q '^hive: could not update Claude Code.s settings: .*is not valid JSON'"
cp "$tmp/settings.installed" "$a/cfg/settings.json"

# A new core pinned by `hive upgrade` on one machine reaches another at its next sync, which runs the old
# core's script while the new one replaces it, and applies what the new core's install writes. Remotes of
# their own, so the change reaches no other machine here.
git clone -q --bare "$tmp/core.git" "$tmp/core2.git"
git clone -q --bare "$tmp/remote.git" "$tmp/remote2.git"
git clone -q "$tmp/remote2.git" "$tmp/w2" && sed "s|$tmp/core.git|$tmp/core2.git|" "$tmp/w2/hive.lock" >"$tmp/w2/lock" &&
    mv "$tmp/w2/lock" "$tmp/w2/hive.lock" && git -C "$tmp/w2" commit -qam "core from core2" && git -C "$tmp/w2" push -q origin main
machine u "$tmp/remote2.git" && machine v "$tmp/remote2.git"
run u install >/dev/null 2>&1
git clone -q "$tmp/core2.git" "$tmp/c2"
python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); old='    s[\"idleCompaction\"] = False\n'; assert old in s
s = s.replace(old, old + '    s[\"hiveTestKey\"] = True\n')
# Shift everything after the header, so a run that read on from the new file would land mid-line.
s = s.replace('set -eu\n', '#' + 'x' * 199 + '\n' * 1 + ('#' + 'y' * 99 + '\n') * 80 + 'set -eu\n', 1)
open(p, 'w').write(s)" "$tmp/c2/bin/hive"
git -C "$tmp/c2" commit -qam "install writes a new key" && git -C "$tmp/c2" push -q origin main
new_core=$(git -C "$tmp/c2" rev-parse HEAD)
out=$(run v upgrade hive-mind 2>&1)
check "upgrade pins the core's newest commit and pushes it" "git --git-dir='$tmp/remote2.git' show main:hive.lock | grep -q '^hive-mind .* $new_core\$' && printf '%s' \"\$out\" | grep -q 'upgraded hive-mind and pushed'"
before=$(ls -i "$tmp/u/hive/hive-mind/bin/hive" | awk '{ print $1 }')
out=$(run u sync 2>&1); rc=$?
check "a sync that moves the core it runs from finishes cleanly" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q 'in sync with origin/main' && [ \"\$(git -C '$tmp/u/hive/hive-mind' rev-parse HEAD)\" = '$new_core' ]"
check "the core's files are replaced, not rewritten in place" "[ \"\$(ls -i '$tmp/u/hive/hive-mind/bin/hive' | awk '{ print \$1 }')\" != '$before' ]"
check "the sync that pulls a change to what install writes applies it" "python3 -c \"import json,sys; sys.exit(json.load(open(sys.argv[1])).get('hiveTestKey') is not True)\" '$tmp/u/cfg/settings.json'"
run v sync >/dev/null 2>&1
check "sync installs nothing on a machine that never ran install" "[ ! -e '$tmp/v/cfg/settings.json' ]"

# --- the automatic tidy ---------------------------------------------------------------------------

printf '#!/bin/sh\n[ "$1" = --version ] && { echo "9.9.9 (Claude Code)"; exit 0; }\nprintf "%%s|%%s\\n" "$HIVE_TIDY_SESSION" "$*" >>"%s/stub.log"\n' "$tmp" >"$tmp/stub-claude" && chmod +x "$tmp/stub-claude"
# In subshells: in POSIX sh an assignment before a function call outlives the call, and would turn the
# tidy on (or, for HIVE_TIDY_SESSION, off) for every check after it.
tidy_env() { (HIVE_TIDY=on HIVE_TIDY_COMMAND="$tmp/stub-claude"; export HIVE_TIDY HIVE_TIDY_COMMAND; "$@"); }
stub_count() { c=$(grep -c "$1" "$tmp/stub.log" 2>/dev/null); echo "${c:-0}"; }
wait_for_stub() { i=0; while [ $i -lt 50 ] && [ "$(stub_count "$1")" -lt "$2" ]; do sleep 0.2; i=$((i + 1)); done; }
today=$(date -u +%Y-%m-%d)
rm -f "$a/hive/.git/hive/tidy-checked" "$tmp/stub.log"
run a sync >/dev/null 2>&1
check "the hive is due a tidy (memories with two versions)" "HOME='$a/home' CLAUDE_CONFIG_DIR='$a/cfg' sh -c '. /dev/null' && grep -l '^<!-- hive:sibling' '$a'/hive/memory/*.md >/dev/null"
tidy_env run a sync --hook >/dev/null 2>&1
wait_for_stub 'tidy mode' 1
check "a session start that finds a tidy due starts one, headless" "grep -q '^1|-p Run the consolidate-hive skill in tidy mode' '$tmp/stub.log'"
check "the tidy never skips permissions: dontAsk with an allowlist" "grep 'tidy mode' '$tmp/stub.log' | grep -q -- '--permission-mode dontAsk --allowedTools Read' && ! grep -q 'dangerously' '$tmp/stub.log'"
check "the tidy may edit only memory and decisions" "grep 'tidy mode' '$tmp/stub.log' | grep -o 'Edit([^)]*)' | grep -v -e '/hive/memory/\\*\\*' -e '/hive/decisions/\\*\\*' | wc -l | tr -d ' ' | grep -qx 0"
check "the tidy says why it is due" "grep 'tidy mode' '$tmp/stub.log' | grep -q 'with two versions'"
check "the first tidy is due to record the memory files' shape" "grep 'tidy mode' '$tmp/stub.log' | grep -q 'no tidy has recorded the memory files'"
check "the tidy is told the Claude Code version and the memory shape, for its drift step" "grep 'tidy mode' '$tmp/stub.log' | grep -q 'Claude Code version: 9.9.9 (Claude Code). Memory shape: .*key:name'"
check "the machine that tidies claims the day on origin" "on_remote show-ref | grep -q 'refs/hive/tidy/$today'"
mkdir -p "$b/cfg/projects/x" && echo '{}' >"$b/cfg/projects/x/s.jsonl"
rm -f "$b/hive/.git/hive/tidy-checked"
tidy_env run b sync --hook >/dev/null 2>&1
wait_for_stub 'harvest mode' 1
check "another machine the same day harvests its own transcripts instead" "[ \"\$(grep -c 'tidy mode' '$tmp/stub.log')\" = 1 ] && grep -q 'harvest mode' '$tmp/stub.log'"
n=$(wc -l <"$tmp/stub.log")
tidy_env run b sync --hook >/dev/null 2>&1; sleep 1
check "a machine looks at most every six hours" "[ \"\$(wc -l <'$tmp/stub.log')\" = '$n' ]"
rm -f "$b/hive/.git/hive/tidy-checked"
(HIVE_TIDY_SESSION=1; export HIVE_TIDY_SESSION; tidy_env run b sync --hook) >/dev/null 2>&1; sleep 1
check "a tidy session never starts another" "[ \"\$(wc -l <'$tmp/stub.log')\" = '$n' ]"
rm -f "$b/hive/.git/hive/tidy-checked"
tidy_env run b tidy --auto >/dev/null 2>&1; sleep 1
check "a machine harvests at most once a day" "[ \"\$(wc -l <'$tmp/stub.log')\" = '$n' ]"
machine t
mkdir -p "$tmp/t/hive/decisions/tidy" && printf '# Tidy\n\nMemory shape: %s\n' "$(run t shape)" >"$tmp/t/hive/decisions/tidy/$today.md" && sed -i.bak '/hive:sibling/,$d' "$tmp/t/hive"/memory/*.md && rm -f "$tmp/t/hive"/memory/*.bak
git -C "$tmp/t/hive" add -A && git -C "$tmp/t/hive" commit -qm "tidy" && run t index
tidy_env run t tidy --auto >/dev/null 2>&1; sleep 1
check "nothing starts when no tidy is due and there is nothing to harvest" "[ \"\$(wc -l <'$tmp/stub.log')\" = '$n' ]"
# Today's claim is taken, so nothing would start anyway: ask for the reasons a tidy gives instead.
tidy_env run t tidy >/dev/null 2>&1
check "a log in decisions/tidy/ counts as the last tidy" "tail -n 1 '$tmp/stub.log' | grep -q 'in tidy mode. The hive checkout' && ! tail -n 1 '$tmp/stub.log' | grep -q 'since the last tidy'"

# The index makes a tidy due only past 90% of its budget: at 80% tidies came daily and retired as many
# memories as sessions wrote.
idx="$tmp/t/hive/memory/MEMORY.md"
awk 'BEGIN { for (i = 0; i < 100; i++) printf "%0184d\n", 0 }' >"$idx"
tidy_env run t tidy >/dev/null 2>&1
check "an index at 85% of its budget makes no tidy due" "! tail -n 1 '$tmp/stub.log' | grep -q 'index at'"
awk 'BEGIN { for (i = 0; i < 110; i++) printf "%0184d\n", 0 }' >"$idx"
tidy_env run t tidy >/dev/null 2>&1
check "an index past 90% of its budget makes a tidy due" "tail -n 1 '$tmp/stub.log' | grep -q 'index at 110 lines and 20350 characters'"
run t index

# A memory of a shape no tidy has checked, as when Claude Code changes how it writes memory, makes a
# tidy due and says what is new.
printf -- '---\nname: odd\ndescription: d\nmetadata:\n  type: feedback\n  surprise: yes\n---\nbody\n' >"$tmp/t/hive/memory/feedback_odd.md"
git -C "$tmp/t/hive" add -A && git -C "$tmp/t/hive" commit -qm "odd"
tidy_env run t tidy >/dev/null 2>&1
check "a memory shape no tidy has checked makes a tidy due, naming what is new" "tail -n 1 '$tmp/stub.log' | grep -q 'memory files now use key:surprise, which no tidy has checked'"

# A tidy that found drift reaches the next interactive session, once for the whole hive; never a tidy's.
printf -- '\n## Claude Code 9.9.9\n\n- Drift: memory files carry a surprise key.\n' >>"$tmp/t/hive/decisions/tidy/$today.md"
run t save >/dev/null 2>&1
out=$(HIVE_TIDY_SESSION=1 run b sync --hook 2>&1)
check "a tidy session is not told about drift" "! printf '%s' \"\$out\" | grep -q 'found Claude Code changing'"
out=$(run a sync --hook 2>&1)
check "a session start reports a tidy's drift, for the Worklog" "printf '%s' \"\$out\" | grep -q 'found Claude Code changing how memory works'"
out=$(run a sync --hook 2>&1)
check "a machine reports a tidy's drift once" "! printf '%s' \"\$out\" | grep -q 'found Claude Code changing'"
run a save >/dev/null 2>&1
out=$(run b sync --hook 2>&1)
check "a machine is not told about drift a session on another machine was told about" "! printf '%s' \"\$out\" | grep -q 'found Claude Code changing'"

# --- memory usage ---------------------------------------------------------------------------------

# Each machine records from its own transcripts which memories sessions open, in a file only it writes.
for n in used written edited moved quiet; do memory_file a "feedback_$n.md" "$n"; done
run a save >/dev/null 2>&1; run b sync >/dev/null 2>&1
# event <transcript> <session> <cwd> <tool> <input key> <input value, JSON-escaped>
event() {
    mkdir -p "$(dirname "$1")"
    printf '{"type":"assistant","sessionId":"%s","timestamp":"%sT10:00:00.000Z","cwd":"%s","message":{"content":[{"type":"tool_use","id":"t","name":"%s","input":{"%s":"%s"}}]}}\n' \
        "$2" "$today" "$3" "$4" "$5" "$6" >>"$1"
}
# In a subshell, so AGENT_NAME does not outlive the call (see tidy_env).
as() { (AGENT_NAME=$1; export AGENT_NAME; shift; "$@"); }
p="$a/cfg/projects/-work"
event "$p/s1.jsonl" s1 /work Read file_path "$a/hive/memory/feedback_used.md"
event "$p/s1.jsonl" s1 /work Bash command "cat > $a/hive/memory/feedback_written.md <<EOF"
event "$p/s1.jsonl" s1 /work Bash command "sed -i '' s/a/b/ $a/hive/memory/feedback_edited.md"
event "$p/s1.jsonl" s1 /work Bash command "mv $a/hive/memory/feedback_moved.md /elsewhere"
event "$p/s1.jsonl" s1 /work Read file_path "$a/hive/memory/no_such.md"
event "$p/s2.jsonl" s2 "$a/hive" Read file_path "$a/hive/memory/feedback_quiet.md"
event "$p/s3.jsonl" s3 /work Bash command "ls"
event "$p/s3/subagents/agent-x.jsonl" s3 /work Bash command "cat ~/hive/memory/feedback_moved.md"
event "$p/s4.jsonl" s4 /work Bash command 'rg x \"$hive\"/memory/feedback_written.md'
event "$p/s4.jsonl" s4 /work Read file_path "$a/elsewhere-hive/memory/feedback_edited.md"
as ma run a usage >/dev/null 2>&1
u="$a/hive/memory/.usage/agentctl-ma-on-unknown-host.tsv"
tab=$(printf '\t')
recorded() { grep -qxF "$today$tab$1$tab$2" "$u"; }
check "usage records a memory a session read" "recorded feedback_used s1"
check "usage records a shell command reading a memory through \$hive" "recorded feedback_written s4"
check "usage counts a subagent's read for its session" "recorded feedback_moved s3"
check "usage records each session once a day" "[ \"\$(grep -c \"$tab-${tab}s1\$\" '$u')\" = 1 ] && recorded - s3 && recorded - s4"
check "writing, editing or moving a memory is not opening it" "! recorded feedback_written s1 && ! recorded feedback_edited s1 && ! recorded feedback_moved s1"
check "usage ignores files that are not this hive's memories" "! grep -q -e no_such -e feedback_edited '$u'"
check "usage leaves out sessions working in the checkout" "! grep -q 's2\$' '$u'"
cp "$u" "$tmp/usage.first"
rm -f "$a/hive/.git/hive/usage-scanned"
as ma run a usage >/dev/null 2>&1
check "reading the transcripts again adds nothing" "cmp -s '$tmp/usage.first' '$u'"
printf '2020-01-01\tfeedback_used\told\n~~~~~~~~\n' >>"$u"
as ma run a usage >/dev/null 2>&1
check "usage drops old records and lines that do not parse" "cmp -s '$tmp/usage.first' '$u'"
run a save >/dev/null 2>&1
out=$(run b sync --hook 2>&1)
check "another machine's usage file is not reported to sessions as memory" "! printf '%s' \"\$out\" | grep -q -e usage -e '\\.tsv'"
event "$b/cfg/projects/-work/s5.jsonl" s5 /work Read file_path "$b/hive/memory/feedback_used.md"
out=$(as mb run b usage 2>&1)
check "the report counts sessions on every machine" "printf '%s\n' \"\$out\" | grep -q '^Memories opened in the last 30 days, recorded on 2 machine(s): 4 sessions started, 4 sessions opened at least one'"
check "the report counts each session that opened a memory" "printf '%s\n' \"\$out\" | grep -Eq '^ +2 +$today +2026-10-25 +feedback_used$'"
check "the report lists memories nobody opened" "printf '%s\n' \"\$out\" | grep -Eq '^ +0 +- +2026-10-25 +feedback_quiet$'"
check "usage refuses a window that is not a number of days" "! run b usage soon >/dev/null 2>&1"
check "the tidy may run hive usage" "grep 'tidy mode' '$tmp/stub.log' | grep -q 'Bash(hive usage \\*)'"
event "$c/cfg/projects/-work/s6.jsonl" s6 /work Read file_path "$c/hive/memory/feedback_used.md"
run c sync >/dev/null 2>&1
as mc tidy_env run c tidy --auto >/dev/null 2>&1
check "the background check records usage" "grep -q 's6\$' '$c/hive/memory/.usage/agentctl-mc-on-unknown-host.tsv'"
rm -f "$b/hive/memory/.usage/agentctl-mb-on-unknown-host.tsv" "$c/hive/memory/.usage/agentctl-mc-on-unknown-host.tsv"

# --- rule costs -----------------------------------------------------------------------------------

# A session logs what a rule cost, in a file only its machine writes; the report reads every machine's.
# cost <machine> <session> <rule> <text>: hive cost as a session on that machine runs it.
cost() { (CLAUDE_CODE_SESSION_ID=$2 AGENT_NAME=m$1; export CLAUDE_CODE_SESSION_ID AGENT_NAME; run "$1" cost "$3" "$4") >/dev/null 2>&1; }
ca="$a/hive/memory/.costs/agentctl-ma-on-unknown-host.tsv"
cost a s1 used "A project, a one-line fix: the full suite	took
9 minutes"
check "a cost is one line, against the memory's file name, found by its name too" "[ \"\$(cat '$ca')\" = '$today${tab}feedback_used${tab}s1${tab}A project, a one-line fix: the full suite took 9 minutes' ]"
cost a s1 instructions/test "Project: x"
cost a s1 skills/extra-one/ "Project: y"
check "an instruction file and a source's skill can be logged against" "grep -q '${tab}instructions/test.md${tab}' '$ca' && grep -q '${tab}skills/extra-one${tab}' '$ca'"
refused=0
for name in no_such MEMORY instructions/../memory/feedback_used instructions/no_such skills/no_such 'feedback_used x'; do
    cost a s1 "$name" "x" || refused=$((refused + 1))
done
cost a s1 feedback_used " " || refused=$((refused + 1))
check "a name that is no rule in the hive, or no text, is refused and logs nothing" "[ $refused = 7 ] && [ \"\$(wc -l <'$ca' | tr -d ' ')\" = 3 ]"
printf -- '---\nname: firm\ndescription: d\nmetadata:\n  type: feedback\n  firmness: rule\n---\nbody\n' >"$a/hive/memory/feedback_firm.md"
cost a s1 feedback_firm "Work: w"
printf '2020-01-01\tfeedback_used\told\tlong ago\n' >>"$ca"
cost b s5 feedback_used "Work: z"
run a save >/dev/null 2>&1; run b save >/dev/null 2>&1; run a sync >/dev/null 2>&1
check "each machine's log reaches the remote" "on_remote show main:memory/.costs/agentctl-ma-on-unknown-host.tsv >/dev/null 2>&1 && on_remote show main:memory/.costs/agentctl-mb-on-unknown-host.tsv >/dev/null 2>&1"
out=$(run a costs 2>&1)
check "the report reads every machine's log, within its window" "printf '%s\n' \"\$out\" | grep -qx 'Rule costs logged in the last 30 days, on 2 machine(s): 5 against 4 rule(s).' && ! printf '%s' \"\$out\" | grep -q 'long ago'"
check "it groups entries by rule, the most logged against first" "[ \"\$(printf '%s\n' \"\$out\" | grep -v -e '^ ' -e '^Rule' | grep . | head -n 1)\" = feedback_used ] && printf '%s\n' \"\$out\" | grep -qx '  $today  agentctl-mb-on-unknown-host  s5  Work: z'"
check "it shows a memory's firmness" "printf '%s\n' \"\$out\" | grep -qx 'feedback_firm (rule)'"
check "costs refuses a window that is not a number of days" "! run a costs soon >/dev/null 2>&1"

# --- keep-alive -----------------------------------------------------------------------------------

machine ka
printf 'x asyncRewake x\n' >"$tmp/claude-new" && printf 'x\n' >"$tmp/claude-old"
ks="$tmp/ka/hive/.git/hive"
# request <session> <cache read> <cache write>: a request of the session's main conversation, made now,
# in its transcript.
request() { printf '{"type":"assistant","isSidechain":false,"timestamp":"%s","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$2" "$3" >>"$tmp/ka/$1.jsonl"; }
# ka <mode> <session> [prompt]: the keep-alive hook as an interactive Claude Code runs it, with the
# globals below for its environment. Sets rc, out and secs (how long it took).
ka_entry=cli ka_exe="$tmp/claude-new" ka_pid="" ka_delay=1
ka() {
    started=$(date +%s)
    out=$(printf '{"session_id":"%s","transcript_path":"%s","prompt":"%s"}' "$2" "$tmp/ka/$2.jsonl" "${3:-}" |
        (CLAUDE_CODE_ENTRYPOINT=$ka_entry CLAUDE_CODE_EXECPATH=$ka_exe HIVE_KEEPALIVE_DELAY=$ka_delay
         export CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH HIVE_KEEPALIVE_DELAY
         [ -z "$ka_pid" ] || { CLAUDE_PID=$ka_pid; export CLAUDE_PID; }
         run ka keepalive "$1") 2>&1)
    rc=$?
    secs=$(( $(date +%s) - started ))
}
# ka_bg <session>: a Stop hook in the background, once it has armed its wait. ka_done waits for it and
# sets bgrc and bgsecs.
ka_bg() {
    before=$(cat "$ks/keepalive/$1/armed" 2>/dev/null)
    ( ka stop "$1"; echo "$rc $secs" >"$tmp/ka/$1.rc" ) &
    bg=$!
    i=0
    while [ $i -lt 100 ]; do
        case "$(cat "$ks/keepalive/$1/armed" 2>/dev/null)" in "$before"|-*|"") ;; *) break ;; esac
        sleep 0.1; i=$((i + 1))
    done
}
ka_done() { wait "$bg"; read -r bgrc bgsecs <"$tmp/ka/$1.rc"; }
klog() { grep -q " $1 $2" "$ks/keepalive.log"; }
# age <session>: dates the session's requests and its transcript back to 2020, as a Mac asleep
# through the wait would find them.
age() {
    sed 's/"timestamp":"[^"]*"/"timestamp":"2020-01-01T00:00:00.000Z"/' "$tmp/ka/$1.jsonl" >"$tmp/ka/$1.old" &&
        mv "$tmp/ka/$1.old" "$tmp/ka/$1.jsonl" && touch -t 202001010000 "$tmp/ka/$1.jsonl"
}

request s1 150000 1000
ka stop s1
check "an idle interactive session of 100k tokens is pinged when the wait ends" "[ \"\$rc\" = 2 ] && printf '%s' \"\$out\" | grep -q 'keep-alive ping 1: this session has been idle 0 min'"
check "the ping is logged" "klog s1 'ping 1, idle 0 min'"
request s1 151000 300
ka stop s1
check "the woken turn's end records a warm cache, and waits again" "klog s1 'warm the woken turn read 151000 tokens from the cache' && [ \"\$rc\" = 2 ]"
check "a woken turn does not restart the count" "printf '%s' \"\$out\" | grep -q 'keep-alive ping 2:'"
request s1 20000 140000
ka stop s1
check "a woken turn that missed the cache is logged, and the pings stop" "klog s1 'miss the woken turn wrote 140000 tokens' && [ \"\$rc\" = 0 ]"
ka stop s1
check "the next real turn starts over" "[ \"\$rc\" = 2 ] && printf '%s' \"\$out\" | grep -q 'keep-alive ping 1:'"
# The transcript can lag behind the Stop hook (2.1.316): the woken turn's request lands during the wait.
request s10 150000 1000
ka stop s10
ka_delay=3
ka_bg s10
check "a woken turn whose request is not in the transcript yet is not measured" "! klog s10 warm && ! klog s10 miss"
request s10 20000 140000
request s10 160000 300
ka_done s10
check "it is measured once its request lands, by its first request after the ping, which met the cache" "klog s10 'miss the woken turn wrote 140000 tokens' && [ \"\$bgrc\" = 0 ]"
# The user back before the wait ends: their turn's end measures the ping, and a miss stays with that absence.
ka_delay=1
request s12 150000 1000
ka stop s12
ka_delay=3
ka_bg s12
request s12 20000 140000
ka prompt s12 "back again"
ka_done s12
ka_delay=1
request s12 160000 300
ka stop s12
check "a ping measured at the next real turn's end is logged, and does not stop the pings of the next absence" "klog s12 'miss the woken turn wrote 140000 tokens' && [ \"\$rc\" = 2 ]"

# Sessions it must leave alone return at once: with a 30-second wait, one that waited would show.
ka_delay=30
request s2 60000 1000
ka stop s2
check "a session under 100k tokens is not kept warm" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
request s3 150000 1000
ka_entry=sdk-cli; ka stop s3; ka_entry=cli
check "a headless session never waits, since claude -p waits for the hook" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
ka prompt s3 "Thanks, let it go cold now"
ka stop s3
check "'let it go cold' turns it off for the session" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
request s13 150000 1000
ka prompt s13 "Let this session go cold"
ka stop s13
check "so do other wordings, such as 'let this session go cold'" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
request s16 150000 1000
ka prompt s16 "Lets go cold for now"
ka stop s16
check "and 'go cold' on its own, as in 'lets go cold for now'" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
ka_exe="$tmp/claude-old"
request s4 150000 1000
ka stop s4
check "under a Claude Code without asyncRewake it never waits, as it would run in the foreground" "[ \"\$rc\" = 0 ] && [ \"\$secs\" -lt 10 ]"
ka stop s4
check "a Claude Code without asyncRewake is logged once" "[ \"\$(grep -c ' unsupported Claude Code at $tmp/claude-old does not name asyncRewake' '$ks/keepalive.log')\" = 1 ]"
# Hooks get the Claude Code process's id, not its path (2.1.316): a sleep stands in for it here.
sleep 60 &
ka_pid=$!
ka_exe=""
ka stop s4
check "without CLAUDE_CODE_EXECPATH, a hook finds the running binary through CLAUDE_PID" "[ \"\$rc\" = 0 ] && grep -qF ' unsupported Claude Code at $(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("sleep")))') does not' '$ks/keepalive.log'"
kill "$ka_pid" 2>/dev/null
ka_pid="" ka_exe="$tmp/claude-new"
ka stop '../../escape'
check "a session id that is not a plain name is ignored" "[ \"\$rc\" = 0 ] && [ ! -e '$ks/escape' ] && [ ! -e '$tmp/ka/hive/.git/escape' ]"

ka_delay=1
ka prompt s2 "keep it hot while I am out"
ka stop s2
check "'keep it hot' keeps even a small session warm" "[ \"\$rc\" = 2 ]"
request s14 60000 1000
ka prompt s14 "Lets keep this session warm while I talk to a colleague"
ka stop s14
check "so do other wordings, such as 'keep this session warm'" "[ \"\$rc\" = 2 ]"

# The wait's end, against the clock: the window after the last real turn, and the cache's hour.
ka_delay=3
request s5 150000 1000
ka_bg s5
echo $(( $(date +%s) - 5 * 3600 )) >"$ks/keepalive/s5/last"
ka_done s5
check "the pings end 4 hours after the last real turn" "[ \"\$bgrc\" = 0 ] && klog s5 'cold idle 300 min after 0 ping(s)'"
ka prompt s5 "keep it hot"
ka_bg s5
echo $(( $(date +%s) - 5 * 3600 )) >"$ks/keepalive/s5/last"
ka_done s5
check "'keep it hot' stretches that to 16 hours" "[ \"\$bgrc\" = 2 ]"
request s6 150000 1000
ka_bg s6
age s6
ka_done s6
check "a wait that ends after the cache expired (a Mac asleep) does not ping" "[ \"\$bgrc\" = 0 ] && klog s6 'late woke more than 59 min'"
# Claude Code writes to an idle session's transcript without a request (2.1.309).
request s15 150000 1000
ka_bg s15
age s15
echo '{"type":"artifact-autoreact-ledger"}' >>"$tmp/ka/s15.jsonl"
ka_done s15
check "nor does one whose transcript was written after the last request" "[ \"\$bgrc\" = 0 ] && klog s15 'late woke more than 59 min'"

# A wait ends early when something else happens to the session.
request s7 150000 1000
ka_bg s7
ka stop s7
ka_done s7
check "a newer turn ends the earlier wait, which does not ping" "[ \"\$bgrc\" = 0 ] && [ \"\$bgsecs\" -lt 3 ] && [ \"\$rc\" = 2 ] && [ \"\$(grep -c ' s7 ping' '$ks/keepalive.log')\" = 1 ]"
request s8 150000 1000
ka_bg s8
ka prompt s8 "next question"
ka_done s8
check "a prompt ends the wait, so no ping lands in the middle of a turn" "[ \"\$bgrc\" = 0 ] && [ \"\$bgsecs\" -lt 3 ]"
request s9 150000 1000
ka_bg s9
ka end s9
ka_done s9
check "the session's end ends the wait and drops its state" "[ \"\$bgrc\" = 0 ] && [ \"\$bgsecs\" -lt 3 ] && [ ! -e '$ks/keepalive/s9' ]"

# What goes wrong reaches the drift step of the next tidy, once.
tidy_env run ka tidy >/dev/null 2>&1
check "keep-alive problems make a tidy due" "tail -n 1 '$tmp/stub.log' | grep -q 'the keep-alive logged 5 problem(s) on this machine'"
check "and the tidy is given them" "tail -n 1 '$tmp/stub.log' | grep -q 'Keep-alive problems on this machine, from .*keepalive.log: .* s1 miss the woken turn .* | .* unsupported Claude Code at'"
tidy_env run ka tidy >/dev/null 2>&1
check "a tidy is given each problem once" "! tail -n 1 '$tmp/stub.log' | grep -q -i 'keep-alive'"
check "status shows the keep-alive's last lines" "run ka status | grep -q '^keep-alive .*keepalive.log, last lines'"

# --- install, again: concurrency, links, migration ------------------------------------------------

# Installs racing each other (a pre-launch step per launch) leave no junk links inside the hive.
machine i
for n in 1 2 3 4 5 6; do run i install >/dev/null 2>&1 & done; wait
check "concurrent installs leave no links inside the checkout" "[ -z \"\$(find '$tmp/i/hive' -path '*/.git' -prune -o -type l -print)\" ]"
check "concurrent installs end installed" "run i status | grep -q '^  ok    rules and skills are linked'"

# A ~/.claude/skills that is itself a link into the hive is not emptied.
machine k && ln -s "$tmp/k/hive/skills" "$tmp/k/cfg/skills"
out=$(run k install 2>&1)
check "install keeps the hive's skills when ~/.claude/skills links into the hive" "[ -z \"\$(git -C '$tmp/k/hive' status --porcelain)\" ]"
check "and links no other layer's skill into the hive through it, saying why" "[ ! -e '$tmp/k/hive/skills/extra-one' ] && printf '%s' \"\$out\" | grep -q 'skipped: .*extra-one.*inside the hive'"

# A hive cloned somewhere new takes over the old install with --force, hooks included.
clone_hive "$tmp/remote.git" "$tmp/i/hive2"
HOME="$tmp/i/home" CLAUDE_CONFIG_DIR="$tmp/i/cfg" "$tmp/i/hive2/hive-mind/bin/hive" install --force >/dev/null 2>&1
check "a moved checkout takes over the links" "[ \"\$(readlink '$tmp/i/cfg/rules/hive')\" = '$tmp/i/hive2/instructions' ]"
check "a moved checkout leaves one set of hooks" "[ \"\$(grep -c 'sync --hook' '$tmp/i/cfg/settings.json')\" = 1 ] && grep -q 'hive2/hive-mind/bin/hive' '$tmp/i/cfg/settings.json'"

# Taking over from the predecessor, agent-brain: its hooks go, and links into a checkout that has moved
# away are replaced without --force.
machine m
mkdir -p "$tmp/m/cfg/skills" "$tmp/m/cfg/rules" "$tmp/m/gone"
ln -s "$tmp/m/gone/skills/hive-skill" "$tmp/m/cfg/skills/hive-skill"
cat >"$tmp/m/cfg/settings.json" <<EOF
{"autoMemoryDirectory": "$tmp/m/hive/memory",
 "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "$tmp/m/agent-brain/bin/brain sync --hook"}]}],
           "Stop": [{"hooks": [{"type": "command", "command": "$tmp/m/agent-brain/bin/brain save --background"}]}]}}
EOF
run m install >/dev/null 2>&1
check "install takes over the predecessor's hooks" "! grep -q 'bin/brain' '$tmp/m/cfg/settings.json' && [ \"\$(grep -c 'sync --hook' '$tmp/m/cfg/settings.json')\" = 1 ]"
check "install replaces a link to a checkout that is gone" "[ \"\$(readlink '$tmp/m/cfg/skills/hive-skill')\" = '$tmp/m/hive/skills/hive-skill' ]"

# A settings.json that is a link (a dotfile manager's) stays a link.
machine n && mkdir -p "$tmp/n/dotfiles"
echo '{"theme": "dark"}' >"$tmp/n/dotfiles/settings.json" && ln -s "$tmp/n/dotfiles/settings.json" "$tmp/n/cfg/settings.json"
run n install >/dev/null 2>&1
check "a linked settings.json stays a link, edited through it" "[ -L '$tmp/n/cfg/settings.json' ] && grep -q autoMemoryDirectory '$tmp/n/dotfiles/settings.json' && grep -q dark '$tmp/n/dotfiles/settings.json'"

# --- sources: pins, upgrades, layers ---------------------------------------------------------------

run a sync >/dev/null 2>&1; run b sync >/dev/null 2>&1
lnk() { readlink "$tmp/$1/cfg/skills/$2"; }
check "a skill only the hive has links to the hive's" "[ \"\$(lnk a hive-skill)\" = '$a/hive/skills/hive-skill' ]"
check "a skill only a source has links to the source's" "[ \"\$(lnk a extra-one)\" = '$a/hive/extras/skills/extra-one' ]"
check "the hive's own skill wins over a source's of the same name" "[ \"\$(lnk a shared)\" = '$a/hive/skills/shared' ]"
check "a source's skill wins over the core's of the same name" "[ \"\$(lnk a worklog-setup)\" = '$a/hive/extras/skills/worklog-setup' ]"
check "a skill only the core has links to the core's" "[ \"\$(lnk a consolidate-hive)\" = '$a/hive/hive-mind/skills/consolidate-hive' ]"
git clone -q "$tmp/remote.git" "$tmp/pr3" && git -C "$tmp/pr3" rm -q -r skills/shared && git -C "$tmp/pr3" commit -qm "drop shared" && git -C "$tmp/pr3" push -q origin main
run a sync >/dev/null 2>&1
check "when the hive drops a skill, the next layer's takes its place" "[ \"\$(lnk a shared)\" = '$a/hive/extras/skills/shared' ]"
machine ag && mkdir -p "$tmp/ag/cfg/skills/extra-one" && echo "agentd's copy" >"$tmp/ag/cfg/skills/extra-one/SKILL.md"
as x run ag install --force >/dev/null 2>&1
check "in a sandbox, the agent's own skill wins over a source's too" "[ ! -L '$tmp/ag/cfg/skills/extra-one' ] && grep -q \"agentd's copy\" '$tmp/ag/cfg/skills/extra-one/SKILL.md'"

# new_extras <skill>: a new commit in the extras source, adding a skill; prints the commit.
new_extras() {
    rm -rf "$tmp/x" && git clone -q "$tmp/extras.git" "$tmp/x" && mkdir -p "$tmp/x/skills/$1" &&
        printf -- '---\nname: %s\ndescription: from extras\n---\nextras\n' "$1" >"$tmp/x/skills/$1/SKILL.md" &&
        git -C "$tmp/x" add -A && git -C "$tmp/x" commit -qm "add $1" && git -C "$tmp/x" push -q origin main &&
        git -C "$tmp/x" rev-parse HEAD
}
pinned() { on_remote show main:hive.lock | awk -v n="$1" '$1 == n { print $3 }'; }
e2=$(new_extras extra-two)
out=$(run a upgrade extras 2>&1); rc=$?
check "upgrade pins a source's newest commit" "[ $rc = 0 ] && [ \"\$(pinned extras)\" = '$e2' ]"
check "upgrade commits only hive.lock, saying which source" "[ \"\$(on_remote show --name-only --format=%s main)\" = \"\$(printf 'hive.lock: upgrade extras\n\nhive.lock')\" ]"
check "upgrade moves this machine's source and links its new skill" "[ \"\$(git -C '$a/hive/extras' rev-parse HEAD)\" = '$e2' ] && [ \"\$(lnk a extra-two)\" = '$a/hive/extras/skills/extra-two' ]"
out=$(run a upgrade extras 2>&1)
check "upgrade with nothing new says so and commits nothing" "printf '%s' \"\$out\" | grep -q 'extras is at its repository.s newest commit' && [ \"\$(pinned extras)\" = '$e2' ]"
check "upgrade refuses a source the lock does not pin" "! run a upgrade nosuch >/dev/null 2>&1"
out=$(run b sync --hook 2>&1)
check "another machine's sync moves its source to the new pin" "[ \"\$(git -C '$b/hive/extras' rev-parse HEAD)\" = '$e2' ] && [ \"\$(lnk b extra-two)\" = '$b/hive/extras/skills/extra-two' ]"
check "and tells the session the sources moved" "printf '%s' \"\$out\" | grep -q 'the sources moved to new pins (hive.lock)'"

# Both or neither: a machine that cannot fetch a pinned commit keeps its hive and every source where
# they are, while its own memory still goes out.
e3=$(new_extras extra-three)
run a upgrade extras >/dev/null 2>&1
mv "$tmp/extras.git" "$tmp/extras.gone"
b_head=$(git -C "$b/hive" rev-parse HEAD)
memory_file b feedback_while_cut_off.md cut-off
out=$(run b sync --hook 2>&1); rc=$?
check "a pin that cannot be fetched fails the sync, naming the source" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q 'sync failed: source extras: could not fetch its pinned commit'"
check "memory still goes out" "on_remote show main:memory/feedback_while_cut_off.md >/dev/null 2>&1"
check "the hive stays where it was" "[ \"\$(git -C '$b/hive' rev-parse HEAD)\" != \"\$(on_remote rev-parse main)\" ] && [ \"\$(awk '\$1 == \"extras\" { print \$3 }' '$b/hive/hive.lock')\" = '$e2' ]"
check "and so does every source" "[ \"\$(git -C '$b/hive/extras' rev-parse HEAD)\" = '$e2' ] && [ ! -e '$b/hive/extras/skills/extra-three' ]"
check "status says which source cannot be fetched" "run b status | grep -q 'error .*source extras: could not fetch'"
mv "$tmp/extras.gone" "$tmp/extras.git"
run b sync >/dev/null 2>&1
check "once the source is back, the hive and the source move together" "[ \"\$(git -C '$b/hive' rev-parse HEAD)\" = \"\$(on_remote rev-parse main)\" ] && [ \"\$(git -C '$b/hive/extras' rev-parse HEAD)\" = '$e3' ] && [ ! -s '$b/hive/.git/hive/error' ]"
check "status confirms every source is at its pin" "run b status | grep -q '^  ok    source extras is at its pin' && run b status | grep -q '^  ok    source hive-mind is at its pin'"
run a sync >/dev/null 2>&1

# Two machines upgrading at once: different sources both land; of two pins for one source, the one
# replayed last wins.
git clone -q "$tmp/core.git" "$tmp/cx" && echo note >"$tmp/cx/NOTE" && git -C "$tmp/cx" add NOTE && git -C "$tmp/cx" commit -qm note && git -C "$tmp/cx" push -q origin main
c1=$(git -C "$tmp/cx" rev-parse HEAD)
e4=$(new_extras extra-four)
run a upgrade extras >/dev/null 2>&1
run b upgrade hive-mind >/dev/null 2>&1; rc=$?
check "upgrades of different sources on two machines both land" "[ $rc = 0 ] && [ \"\$(pinned extras)\" = '$e4' ] && [ \"\$(pinned hive-mind)\" = '$c1' ]"
check "and the machine that upgraded last runs both" "[ \"\$(git -C '$b/hive/extras' rev-parse HEAD)\" = '$e4' ] && [ \"\$(git -C '$b/hive/hive-mind' rev-parse HEAD)\" = '$c1' ]"
run a sync >/dev/null 2>&1
e5=$(new_extras extra-five)
run a upgrade extras >/dev/null 2>&1
e6=$(new_extras extra-six)
run b upgrade extras >/dev/null 2>&1; rc=$?
check "of two upgrades of one source, the one replayed last wins" "[ $rc = 0 ] && [ \"\$(pinned extras)\" = '$e6' ] && on_remote show main:hive.lock | grep -q '^hive-mind '"
check "the lock keeps one line per source" "[ \"\$(on_remote show main:hive.lock | wc -l | tr -d ' ')\" = 2 ]"
run a sync >/dev/null 2>&1

# The guard: hive.lock changes through upgrade, and a source through its own repository.
guard_reason() { printf '{"tool_name": "Edit", "tool_input": {"file_path": "%s"}}' "$1" | run a guard; }
check "the guard refuses hive.lock, pointing at upgrade" "guard_reason '$a/hive/hive.lock' | grep -q 'deny' && guard_reason '$a/hive/hive.lock' | grep -q 'hive upgrade'"
check "the guard refuses a file in a source, naming it" "guard_reason '$a/hive/extras/skills/extra-one/SKILL.md' | grep -q 'in extras, a source'"
check "the guard refuses the core's instructions through their rules link" "guard_reason '$a/cfg/rules/hive-mind/hive.md' | grep -q 'in hive-mind, a source'"
check "the guard refuses a source's skill through its skill link" "guard_reason '$a/cfg/skills/extra-one/SKILL.md' | grep -q 'in extras, a source'"

# A lock line that is not a source is ignored, and status says so; a core outside a hive refuses to run.
machine w
printf 'memory %s %s\nnot a source line\n' "$tmp/core.git" "$(tip core)" >>"$tmp/w/hive/hive.lock" && git -C "$tmp/w/hive" commit -qam "bad lines"
check "status flags lock lines that are not sources" "run w status | grep -q '^  fix   hive.lock has lines that are not .* memory .* | not a source line'"
mkdir -p "$tmp/lone/core" && cp -R "$root/bin" "$tmp/lone/core/"
check "a core outside a hive refuses to run, saying why" "! '$tmp/lone/core/bin/hive' status >/dev/null 2>&1 && '$tmp/lone/core/bin/hive' status 2>&1 | grep -q 'not inside a hive: there is no hive.lock'"

# A source that moves to a new URL (a fork, a transferred repository), by pull request in the hive: every
# machine fetches the new pin from the new URL, not from the clone's old origin.
git clone -q --bare "$tmp/remote.git" "$tmp/rt-url.git"
git clone -q --bare "$tmp/extras.git" "$tmp/extras-moved.git"
machine ru "$tmp/rt-url.git" && run ru install >/dev/null 2>&1
rm -rf "$tmp/x" && git clone -q "$tmp/extras-moved.git" "$tmp/x" && mkdir -p "$tmp/x/skills/moved-skill" &&
    printf -- '---\nname: moved-skill\ndescription: from the moved extras\n---\nx\n' >"$tmp/x/skills/moved-skill/SKILL.md" &&
    git -C "$tmp/x" add -A && git -C "$tmp/x" commit -qm "only in the new home" && git -C "$tmp/x" push -q origin main
moved=$(git -C "$tmp/x" rev-parse HEAD)
git clone -q "$tmp/rt-url.git" "$tmp/rt-url-pr" &&
    awk -v u="$tmp/extras-moved.git" -v s="$moved" '$1 == "extras" { $2 = u; $3 = s } { print }' "$tmp/rt-url-pr/hive.lock" >"$tmp/rt-lock" &&
    mv "$tmp/rt-lock" "$tmp/rt-url-pr/hive.lock" && git -C "$tmp/rt-url-pr" commit -qam "extras moves" && git -C "$tmp/rt-url-pr" push -q origin main
out=$(run ru sync 2>&1); rc=$?
check "a source whose URL changes in hive.lock is fetched from its new URL" "[ $rc = 0 ] && [ \"\$(git -C '$tmp/ru/hive/extras' rev-parse HEAD)\" = '$moved' ] && [ \"\$(git -C '$tmp/ru/hive' rev-parse HEAD)\" = \"\$(git --git-dir='$tmp/rt-url.git' rev-parse main)\" ]"

# A source removed from hive.lock by pull request runs on no machine: its skills stop loading where it
# was cloned, as they never load on a machine set up after the removal.
git clone -q --bare "$tmp/remote.git" "$tmp/rt-rm.git"
machine rr "$tmp/rt-rm.git" && run rr install >/dev/null 2>&1
check "a source's skill is linked before the source is removed" "[ \"\$(lnk rr extra-one)\" = '$tmp/rr/hive/extras/skills/extra-one' ]"
git clone -q "$tmp/rt-rm.git" "$tmp/rt-rm-pr" && sed '/^extras /d' "$tmp/rt-rm-pr/hive.lock" >"$tmp/rt-lock" &&
    mv "$tmp/rt-lock" "$tmp/rt-rm-pr/hive.lock" && git -C "$tmp/rt-rm-pr" commit -qam "drop extras" && git -C "$tmp/rt-rm-pr" push -q origin main
run rr sync >/dev/null 2>&1
check "a skill of a source removed from hive.lock stops loading" "[ ! -e '$tmp/rr/cfg/skills/extra-one' ] && [ ! -L '$tmp/rr/cfg/skills/extra-one' ]"
check "and the core's skill it shadowed takes its place" "[ \"\$(lnk rr worklog-setup)\" = '$tmp/rr/hive/hive-mind/skills/worklog-setup' ]"

# hive.lock merges per source, but a replayed upgrade must not undo what a pull request did to the same
# source meanwhile: a machine that has not synced since upgrades a source the hive dropped, or moved.
git clone -q --bare "$tmp/remote.git" "$tmp/rt-m1.git"
machine rm1 "$tmp/rt-m1.git" && run rm1 install >/dev/null 2>&1
git clone -q "$tmp/rt-m1.git" "$tmp/rt-m1-pr" && sed '/^extras /d' "$tmp/rt-m1-pr/hive.lock" >"$tmp/rt-lock" &&
    mv "$tmp/rt-lock" "$tmp/rt-m1-pr/hive.lock" && git -C "$tmp/rt-m1-pr" commit -qam "drop extras" && git -C "$tmp/rt-m1-pr" push -q origin main
new_extras rt-one >/dev/null
run rm1 upgrade >/dev/null 2>&1
check "an upgrade replayed onto a lock that dropped the source leaves it dropped" "! git --git-dir='$tmp/rt-m1.git' show main:hive.lock | grep -q '^extras '"

git clone -q --bare "$tmp/remote.git" "$tmp/rt-m2.git"
git clone -q --bare "$tmp/extras.git" "$tmp/extras-fork.git"
machine rm2 "$tmp/rt-m2.git" && run rm2 install >/dev/null 2>&1
git clone -q "$tmp/rt-m2.git" "$tmp/rt-m2-pr" &&
    awk -v u="$tmp/extras-fork.git" '$1 == "extras" { $2 = u } { print }' "$tmp/rt-m2-pr/hive.lock" >"$tmp/rt-lock" &&
    mv "$tmp/rt-lock" "$tmp/rt-m2-pr/hive.lock" && git -C "$tmp/rt-m2-pr" commit -qam "extras from the fork" && git -C "$tmp/rt-m2-pr" push -q origin main
new_extras rt-two >/dev/null
run rm2 upgrade >/dev/null 2>&1
check "an upgrade replayed onto a lock that moved the source keeps its new URL" "git --git-dir='$tmp/rt-m2.git' show main:hive.lock | grep -q '^extras $tmp/extras-fork.git '"

# A hive's own settings.json: its keys merge into Claude Code's settings wherever the hive installs, an
# object key by key; the engine's keys win; every sync puts them back; uninstall takes back only those
# still at the hive's values; and sandboxes get them through the home the host writes.
git clone -q --bare "$tmp/remote.git" "$tmp/hs.git"
git clone -q "$tmp/hs.git" "$tmp/hs-pr" &&
    printf '{"awaySummaryEnabled": false, "attribution": {"commit": "", "pr": ""}, "theme": "dark", "autoDreamEnabled": true}\n' >"$tmp/hs-pr/settings.json" &&
    git -C "$tmp/hs-pr" add settings.json && git -C "$tmp/hs-pr" commit -qm "my settings" && git -C "$tmp/hs-pr" push -q origin main
machine sa "$tmp/hs.git"
printf '{"attribution": {"sessionUrl": "kept"}, "model": "mine"}\n' >"$tmp/sa/cfg/settings.json"
run sa install >/dev/null 2>&1
sa_has() { python3 -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$tmp/sa/cfg/settings.json"; }
check "the hive's settings.json merges into Claude Code's settings" "sa_has \"s['theme'] == 'dark' and s['awaySummaryEnabled'] is False and s['model'] == 'mine'\""
check "an object in it merges key by key" "sa_has \"s['attribution'] == {'sessionUrl': 'kept', 'commit': '', 'pr': ''}\""
check "a key the engine owns keeps the engine's value" "sa_has \"s['autoDreamEnabled'] is False\""
check "and status says so" "run sa status | grep -q '^  note  the hive.s settings.json sets autoDreamEnabled, which the engine owns'"
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['theme'] = 'light'; json.dump(s, open(p, 'w'))" "$tmp/sa/cfg/settings.json"
run sa sync >/dev/null 2>&1
check "a sync puts back a hive key the user changed" "sa_has \"s['theme'] == 'dark'\""
cp "$tmp/sa/cfg/settings.json" "$tmp/sa-before.json"
printf '{"theme": "dark",\n' >"$tmp/hs-pr/settings.json" && git -C "$tmp/hs-pr" commit -qam "broken settings" && git -C "$tmp/hs-pr" push -q origin main
out=$(run sa sync 2>&1)
check "an invalid settings.json is reported and leaves Claude Code's settings alone" "printf '%s' \"\$out\" | grep -q 'settings.json is not valid JSON.*settings are unchanged' && cmp -s '$tmp/sa-before.json' '$tmp/sa/cfg/settings.json'"
check "install refuses it too, changing nothing" "! run sa install >/dev/null 2>&1 && cmp -s '$tmp/sa-before.json' '$tmp/sa/cfg/settings.json'"
check "and status flags it" "run sa status | grep -q '^  fix   .*settings.json is not valid JSON'"
git -C "$tmp/hs-pr" revert --no-edit HEAD >/dev/null && git -C "$tmp/hs-pr" push -q origin main && run sa sync >/dev/null 2>&1

# A sandbox: agentd copies the host's generated home over it, and its own sync leaves that alone.
sb_home="$tmp/sa/hive/sandbox/home/.claude/settings.json"
check "the sandboxes' home carries the hive's keys" "python3 -c \"import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s['theme'] == 'dark' and s['autoDreamEnabled'] is False and s['autoMemoryDirectory'] == '/home/agent/hive/memory' else 1)\" '$sb_home'"
machine sb "$tmp/hs.git" && sed "s|/home/agent/hive|$tmp/sb/hive|g" "$sb_home" >"$tmp/sb/cfg/settings.json"
as x run sb install >/dev/null 2>&1
python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['theme'] = 'agentd'; json.dump(s, open(p, 'w'))" "$tmp/sb/cfg/settings.json"
cp "$tmp/sb/cfg/settings.json" "$tmp/sb-agentd.json"
out=$(AGENT_NAME=x run sb sync --hook 2>&1)
check "and the sandbox's sync leaves them to agentd" "cmp -s '$tmp/sb-agentd.json' '$tmp/sb/cfg/settings.json'"
sed "s|/home/agent/hive|$tmp/sb/hive|g" "$sb_home" >"$tmp/sb/cfg/settings.json"
check "in a sandbox, the settings from the home are what the hive installs" "AGENT_NAME=x run sb status | grep -q '^  ok    Claude Code settings use the hive'"

python3 -c "import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['awaySummaryEnabled'] = True; json.dump(s, open(p, 'w'))" "$tmp/sa/cfg/settings.json"
run sa uninstall >/dev/null 2>&1
check "uninstall takes back the hive's keys still at its values" "! sa_has \"'theme' in s\" && sa_has \"s['attribution'] == {'sessionUrl': 'kept'}\""
check "and leaves the ones the user changed, and the user's own" "sa_has \"s['awaySummaryEnabled'] is True and s['model'] == 'mine'\""

# --- upgrade pull requests ------------------------------------------------------------------------

# A gh stub that answers as GitHub's does: pull requests live in $tmp/gh/prs.json; `pr list --head`
# matches the branch name in any repository (forks too) and --state closed takes merged ones in; --json
# projects the fields asked for and --jq runs real jq on the result, printing strings raw (so an empty
# list's .[0] prints "null"); `pr create` refuses a second open pull request from one branch. It records
# every call in calls, and the latest body in body. Files there steer it: me (gh's user), owner, org
# (true for an organisation's hive), signed-out, list-fails, review-fails, view-state (what `pr view`
# says, as when a pull request is merged mid-run).
mkdir -p "$tmp/gh"
cat >"$tmp/gh/gh" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
printf '%s\n' "$*" >>"$d/calls"
exec python3 -I - "$d" "$@" <<'PY'
import json, os, subprocess, sys
d, args = sys.argv[1], sys.argv[2:]
prs = json.load(open(d + "/prs.json"))
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def read(name, default=""):
    try:
        return open(os.path.join(d, name)).read().strip()
    except OSError:
        return default
def out(value):
    q = opt("--jq")
    if q is None:
        print(json.dumps(value)); return
    r = subprocess.run(["jq", "-r", q], input=json.dumps(value), capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
def save():
    json.dump(prs, open(d + "/prs.json", "w"))
def find(ref):
    return next(p for p in prs if str(p["number"]) == ref or p["url"] == ref)
def keep_body(p):
    if opt("--body-file"):
        p["body"] = open(opt("--body-file")).read()
        open(d + "/body", "w").write(p["body"])
cmd = " ".join(args[:2])
if cmd == "auth status":
    sys.exit(1 if os.path.exists(d + "/signed-out") else 0)
elif cmd == "api user":
    out({"login": read("me")})
elif cmd == "repo view":
    out({"owner": {"login": read("owner", "o")}, "isInOrganization": read("org", "false") == "true"})
elif cmd == "pr list":
    if os.path.exists(d + "/list-fails"):
        sys.stderr.write("HTTP 502: Bad Gateway\n"); sys.exit(1)
    head, state = opt("--head"), (opt("--state") or "open").upper()
    rows = [p for p in prs if (head is None or p["headRefName"] == head)
            and (state == "ALL" or p["state"] == state or (state == "CLOSED" and p["state"] == "MERGED"))]
    rows.sort(key=lambda p: -p["number"])
    fields = (opt("--json") or "number").split(",")
    out([{f: p.get(f) for f in fields} for p in rows])
elif cmd == "pr view":
    out({"state": read("view-state") or find(args[2])["state"]})
elif cmd == "pr create":
    head = opt("--head")
    if any(p["headRefName"] == head and not p["isCrossRepository"] and p["state"] == "OPEN" for p in prs):
        sys.stderr.write('a pull request for branch "%s" into branch "main" already exists\n' % head); sys.exit(1)
    n = max([p["number"] for p in prs] + [0]) + 1
    p = {"number": n, "url": "https://github.com/o/hive/pull/%d" % n, "state": "OPEN", "headRefName": head,
         "baseRefName": opt("--base"), "isCrossRepository": False, "mergedAt": None}
    keep_body(p); prs.append(p); save(); print(p["url"])
elif cmd == "pr edit":
    p = find(args[2]); keep_body(p); save()
    if "--add-reviewer" in args and os.path.exists(d + "/review-fails"):
        sys.stderr.write("could not request a review\n"); sys.exit(1)
elif cmd == "pr close":
    find(args[2])["state"] = "CLOSED"; save()
PY
EOF
chmod +x "$tmp/gh/gh"
echo o >"$tmp/gh/me"
ghj() { # <prs.json>: resets the stub's pull requests and its record of calls
    printf '%s\n' "$1" >"$tmp/gh/prs.json" && : >"$tmp/gh/calls"
}
ours_pr() { # <number> <state> [body]: one of our upgrade pull requests, as gh lists it
    printf '{"number": %s, "url": "https://github.com/o/hive/pull/%s", "state": "%s", "headRefName": "hive/upgrade", "baseRefName": "main", "isCrossRepository": false, "mergedAt": null, "body": "%s"}' "$1" "$1" "$2" "${3:-x}"
}
gh_calls() { grep -c -- "$1" "$tmp/gh/calls" 2>/dev/null || true; }
ghj '[]'
# GitHub URLs, served by local remotes: the hive, its core and a skills source.
git clone -q --bare "$tmp/core.git" "$tmp/upc.git" && git clone -q --bare "$tmp/extras.git" "$tmp/upx.git" && git clone -q --bare "$tmp/remote.git" "$tmp/up.git"
for r in hive:up hive-mind:upc extras:upx; do git config --file "$tmp/gitconfig" "url.$tmp/${r#*:}.git.insteadOf" "https://github.com/o/${r%%:*}"; done
git clone -q "$tmp/up.git" "$tmp/up-pr" &&
    printf 'hive-mind https://github.com/o/hive-mind %s\nextras https://github.com/o/extras %s\n' "$(tip upc)" "$(tip upx)" >"$tmp/up-pr/hive.lock" &&
    git -C "$tmp/up-pr" commit -qam "sources on GitHub" && git -C "$tmp/up-pr" push -q origin main
machine pu https://github.com/o/hive && run pu install >/dev/null 2>&1
pr() { (HIVE_GH_COMMAND="$tmp/gh/gh"; export HIVE_GH_COMMAND; run pu upgrade --pr); }
up_extras() { # <subject>: a new commit in the extras source; prints it
    rm -rf "$tmp/ux" && git clone -q "$tmp/upx.git" "$tmp/ux" && echo "$1" >>"$tmp/ux/NOTES" && git -C "$tmp/ux" add NOTES &&
        git -C "$tmp/ux" commit -qm "$1" && git -C "$tmp/ux" push -q -f origin HEAD:main && git -C "$tmp/ux" rev-parse HEAD
}
upgrade_tip() { git --git-dir="$tmp/up.git" rev-parse hive/upgrade; }
pu_head=$(git -C "$tmp/pu/hive" rev-parse HEAD)

out=$(run pu upgrade --pr 2>&1); rc=$?
check "upgrade --pr without gh says so and succeeds, for the tidy" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q 'upgrade --pr skipped: gh is not installed'"
touch "$tmp/gh/signed-out"; out=$(pr 2>&1); rc=$?; rm "$tmp/gh/signed-out"
check "so does gh signed out of github.com, asking about github.com's active account only" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q 'skipped: gh is not signed in to github.com' && grep -q '^auth status --hostname github.com --active' '$tmp/gh/calls'"
out=$( (HIVE_GH_COMMAND="$tmp/gh/gh"; export HIVE_GH_COMMAND; run a upgrade --pr) 2>&1); rc=$?
check "so does a hive whose origin is not on GitHub" "[ $rc = 0 ] && printf '%s' \"\$out\" | grep -q 'skipped: the hive.s origin, .* is not on GitHub'"

ghj "[$(ours_pr 5 OPEN)]"
out=$(pr 2>&1); rc=$?
check "with nothing to upgrade, it opens nothing, closes the open upgrade pull request, and says so for the log" "[ $rc = 0 ] && [ \"\$out\" = '- Upgrade: closed https://github.com/o/hive/pull/5' ] && [ \"\$(gh_calls 'pr create')\" = 0 ] && grep -q '^pr close 5 .*--comment' '$tmp/gh/calls'"

# R1: gh's --jq on an empty list prints "null null", not nothing.
ghj '[]'
u1=$(up_extras "Add the first upgrade")
out=$(pr 2>&1); rc=$?
check "R1: with no upgrade pull request open, a real gh's empty answer still opens one, and says so last" "[ $rc = 0 ] && [ \"\$(gh_calls 'pr create')\" = 1 ] && [ \"\$(printf '%s\n' \"\$out\" | tail -n 1)\" = '- Upgrade: https://github.com/o/hive/pull/1 (extras)' ]"
check "its branch is origin/main with only hive.lock changed, to the new pin" "[ \"\$(git --git-dir='$tmp/up.git' rev-parse hive/upgrade~1)\" = \"\$(git --git-dir='$tmp/up.git' rev-parse main)\" ] && [ \"\$(git --git-dir='$tmp/up.git' diff --name-only main hive/upgrade)\" = hive.lock ] && git --git-dir='$tmp/up.git' show hive/upgrade:hive.lock | grep -q '^extras https://github.com/o/extras $u1\$'"
check "the pull request lists the incoming commits, linked, and the compare" "grep -F \"https://github.com/o/extras/commit/$u1)\" '$tmp/gh/body' | grep -qF 'Add the first upgrade' && grep -q 'https://github.com/o/extras/compare/' '$tmp/gh/body' && ! grep -q 'force-pushed' '$tmp/gh/body'"
check "where gh acts as the hive's owner, the owner is assigned, not asked to review" "grep -q '^pr edit https://github.com/o/hive/pull/1 .*--add-assignee o' '$tmp/gh/calls' && ! grep -q -- '--add-reviewer' '$tmp/gh/calls'"
check "the live checkout never moves" "[ \"\$(git -C '$tmp/pu/hive' rev-parse HEAD)\" = '$pu_head' ] && [ -z \"\$(git -C '$tmp/pu/hive' status --porcelain)\" ] && ! grep -q '$u1' '$tmp/pu/hive/hive.lock'"

u2=$(up_extras "Add the second upgrade")
out=$(pr 2>&1)
check "the next run updates the open pull request rather than opening another" "[ \"\$(gh_calls 'pr create')\" = 1 ] && grep -q '^pr edit 1 .*--body-file' '$tmp/gh/calls' && grep -q 'Add the second upgrade' '$tmp/gh/body' && git --git-dir='$tmp/up.git' show hive/upgrade:hive.lock | grep -q '$u2'"

# R8: a run with nothing new since the last leaves the branch and the pull request as they are.
before=$(upgrade_tip); : >"$tmp/gh/calls"; sleep 1
out=$(pr 2>&1)
check "R8: a run where neither main nor any source moved does not rewrite hive/upgrade" "[ \"\$(upgrade_tip)\" = '$before' ] && ! grep -q '^pr edit' '$tmp/gh/calls' && [ \"\$(printf '%s\n' \"\$out\" | tail -n 1)\" = '- Upgrade: https://github.com/o/hive/pull/1 (extras)' ]"

# A pull request merged while the run worked is neither edited nor logged as waiting.
up_extras "Add a third upgrade" >/dev/null; echo MERGED >"$tmp/gh/view-state"; : >"$tmp/gh/calls"
out=$(pr 2>&1); rm "$tmp/gh/view-state"
check "a pull request merged mid-run is not edited, nor logged as waiting" "! grep -q '^pr edit' '$tmp/gh/calls' && printf '%s' \"\$out\" | grep -q 'merged or closed meanwhile' && ! printf '%s' \"\$out\" | grep -q '^- Upgrade: '"

# A failed pull request list stops the run before anything is pushed.
up_extras "Add a fourth upgrade" >/dev/null; before=$(upgrade_tip); touch "$tmp/gh/list-fails"
out=$(pr 2>&1); rc=$?; rm "$tmp/gh/list-fails"
check "a failed pull request list stops before any push, without failing the tidy" "[ $rc = 0 ] && [ \"\$(upgrade_tip)\" = '$before' ] && printf '%s' \"\$out\" | grep -q 'could not list the hive.s pull requests: HTTP 502'"

rm -rf "$tmp/ux" && git clone -q "$tmp/upx.git" "$tmp/ux" && git -C "$tmp/ux" reset -q --hard "$u1~2" && echo other >"$tmp/ux/OTHER" && git -C "$tmp/ux" add OTHER &&
    git -C "$tmp/ux" commit -qm "Rewrite history" && git -C "$tmp/ux" push -q -f origin HEAD:main
out=$(pr 2>&1)
check "a source force-pushed past its pin is flagged" "grep -q 'extras was force-pushed' '$tmp/gh/body' && printf '%s' \"\$out\" | grep -q 'flagged in the pull request, its history rewritten: extras'"

# Who reviews: the owner, asked and assigned, where gh acts as someone else; one refused call does not
# drop the other; in an organisation's hive, the one gh acts as is assigned.
ghj '[]'; echo bot >"$tmp/gh/me"; touch "$tmp/gh/review-fails"
out=$(pr 2>&1); rm "$tmp/gh/review-fails"
check "where gh acts as someone else, the owner is assigned and asked to review, each on its own" "grep -q '^pr edit https://github.com/o/hive/pull/1 -R o/hive --add-assignee o\$' '$tmp/gh/calls' && grep -q '^pr edit https://github.com/o/hive/pull/1 -R o/hive --add-reviewer o\$' '$tmp/gh/calls' && printf '%s' \"\$out\" | grep -q 'could not ask o to review'"
ghj '[]'; echo true >"$tmp/gh/org"
out=$(pr 2>&1); rm "$tmp/gh/org"; echo o >"$tmp/gh/me"
check "in an organisation's hive, no review is asked of the organisation, and gh's user is assigned" "grep -q '^pr edit https://github.com/o/hive/pull/1 -R o/hive --add-assignee bot\$' '$tmp/gh/calls' && ! grep -q -- '--add-reviewer' '$tmp/gh/calls'"
check "the live checkout still has not moved" "[ \"\$(git -C '$tmp/pu/hive' rev-parse HEAD)\" = '$pu_head' ] && [ -z \"\$(git -C '$tmp/pu/hive' status --porcelain)\" ]"

# R2: someone's fork has a branch named hive/upgrade too, with a pull request open from it.
ghj '[{"number": 41, "url": "https://github.com/o/hive/pull/41", "state": "OPEN", "headRefName": "hive/upgrade", "baseRefName": "main", "isCrossRepository": true, "mergedAt": null, "body": "x"}]'
up_extras "R2 move" >/dev/null
out=$(pr 2>&1)
check "R2: a pull request from a fork's hive/upgrade is never taken for the upgrade one, retitled or rewritten" "! grep -q '^pr edit 41 ' '$tmp/gh/calls' && ! printf '%s' \"\$out\" | grep -q 'pull/41'"

# R5: the user closed the upgrade pull request without merging it: those pins are turned down until a
# source moves past them.
ghj '[]'
out=$(pr 2>&1)
"$tmp/gh/gh" pr close 1 -R o/hive >/dev/null && : >"$tmp/gh/calls"
out=$(pr 2>&1)
check "R5: an upgrade the user closed unmerged is not proposed again until a source moves further" "[ \"\$(gh_calls 'pr create')\" = 0 ] && ! grep -q '^pr edit' '$tmp/gh/calls' && ! printf '%s' \"\$out\" | grep -q '^- Upgrade: '"
up_extras "Moves past the turned-down pins" >/dev/null
out=$(pr 2>&1)
check "and once a source moves past them, a new one is proposed" "[ \"\$(gh_calls 'pr create')\" = 1 ] && [ \"\$(printf '%s\n' \"\$out\" | tail -n 1)\" = '- Upgrade: https://github.com/o/hive/pull/2 (extras)' ]"

# R3: hive.lock may hold comments; the pull request changes pins, nothing else.
rm -rf "$tmp/up-c" && git clone -q "$tmp/up.git" "$tmp/up-c" &&
    { printf '# Sources this hive runs; see SETUP.md.\n\n'; cat "$tmp/up-c/hive.lock"; } >"$tmp/up-c/lock.new" && mv "$tmp/up-c/lock.new" "$tmp/up-c/hive.lock" &&
    git -C "$tmp/up-c" commit -qam "comment the lock" && git -C "$tmp/up-c" push -q origin main
up_extras "R3 move" >/dev/null
out=$(pr 2>&1)
check "R3: the upgrade pull request keeps hive.lock's comments and blank lines, changing only the moved pin" "git --git-dir='$tmp/up.git' show hive/upgrade:hive.lock | grep -qx '# Sources this hive runs; see SETUP.md.' && [ \"\$(git --git-dir='$tmp/up.git' diff --numstat main hive/upgrade -- hive.lock | cut -f1-2)\" = \"\$(printf '1\t1')\" ]"

# R4: commit subjects come from the source's authors, and GitHub renders the body.
up_extras "Fixes #1, thanks @someone" >/dev/null
up_extras "<!-- hides every older commit below" >/dev/null
up_extras 'A subject with `backticks` in it' >/dev/null
out=$(pr 2>&1)
# Fails when a line of <body>, code spans aside, holds an HTML comment, the mention or the closing keyword.
body_hazards() {
    python3 -I -c 'import re, sys
for line in open(sys.argv[1]):
    bare = re.sub(r"(`+).*?\1", "", line)
    if "<!--" in bare or "@someone" in bare or re.search(r"(?i)fixes #1", bare):
        sys.exit(1)' "$1"
}
check "R4: a source's commit subjects cannot close the hive's issues, mention people or hide lines in the body" "body_hazards '$tmp/gh/body' && grep -qF '\`\` A subject with \`backticks\` in it \`\`' '$tmp/gh/body'"

# R7: GitHub refuses a body over 65536 characters, so a long list must be cut.
rm -rf "$tmp/ux" && git clone -q "$tmp/upx.git" "$tmp/ux" &&
    { i=0; from="from refs/heads/main^0"; while [ "$i" -lt 600 ]; do i=$((i + 1)); m=$(printf 'Add skill number %05d to the collection of skills' "$i")
        printf 'commit refs/heads/main\ncommitter t <t@e> %s +0000\ndata %s\n%s\n%s' "$((1700000000 + i))" "${#m}" "$m" "${from:+$from
}"; from=""; done; } |
    git -C "$tmp/ux" fast-import --quiet && git -C "$tmp/ux" push -q -f origin main
out=$(pr 2>&1); rc=$?
check "R7: a source that moved by hundreds of commits still gets a body GitHub accepts" "[ $rc = 0 ] && [ \"\$(wc -c <'$tmp/gh/body' | tr -d ' ')\" -le 65536 ] && grep -q 'and [0-9]* more, in the compare below' '$tmp/gh/body'"

# A session start tells the user once per hive that an upgrade waits, from the newest tidy log's line.
mkdir -p "$a/hive/decisions/tidy"
printf '\n## Upgrade\n\n- Upgrade: https://github.com/o/hive/pull/7 (extras, hive-mind)\n' >>"$a/hive/decisions/tidy/$today.md"
run a save >/dev/null 2>&1
out=$(run b sync --hook 2>&1)
check "a session start says an upgrade waits for review" "printf '%s' \"\$out\" | grep -qx 'hive: an upgrade of extras, hive-mind waits for your review: https://github.com/o/hive/pull/7'"
out=$(run b sync --hook 2>&1)
check "and says it once" "! printf '%s' \"\$out\" | grep -q 'waits for your review'"
run b save >/dev/null 2>&1
out=$(run a sync --hook 2>&1)
check "once for the whole hive, not once per machine" "! printf '%s' \"\$out\" | grep -q 'waits for your review'"
printf -- '- Upgrade: https://github.com/o/hive/pull/8 (extras)\n' >>"$a/hive/decisions/tidy/$today.md"
run a save >/dev/null 2>&1; run c sync >/dev/null 2>&1
out=$( (HIVE_TIDY_SESSION=1; export HIVE_TIDY_SESSION; run c sync --hook) 2>&1)
check "a tidy session is not told, and leaves the notice for the next session" "! printf '%s' \"\$out\" | grep -q 'waits for your review' && [ \"\$(cat '$c/hive/decisions/tidy/upgrade-reported' 2>/dev/null)\" != https://github.com/o/hive/pull/8 ]"
out=$(run c sync --hook 2>&1)
check "a new upgrade pull request is told again" "printf '%s' \"\$out\" | grep -q 'upgrade of extras waits for your review: https://github.com/o/hive/pull/8'"
printf -- '- Upgrade: https://github.com/o/hive/pull/9 (extras)\n- Upgrade: closed https://github.com/o/hive/pull/9\n' >>"$a/hive/decisions/tidy/$today.md"
run c save >/dev/null 2>&1; run a save >/dev/null 2>&1
out=$(run a sync --hook 2>&1)
check "one the tidy logged as closed is not told" "! printf '%s' \"\$out\" | grep -q 'pull/9'"

# R6: a newer tidy that found nothing to upgrade (and closed the pull request) leaves an older,
# untold upgrade line behind.
printf '# Tidy, 2999-01-01\n\n## Upgrade\n\n- Upgrade: https://github.com/o/hive/pull/30 (extras)\n' >"$a/hive/decisions/tidy/2999-01-01.md"
printf '# Tidy, 2999-01-02\n\n## Upgrade\n\nNothing to upgrade; the open pull request was closed.\n' >"$a/hive/decisions/tidy/2999-01-02.md"
run a save >/dev/null 2>&1
out=$(run b sync --hook 2>&1)
check "R6: a session start does not announce an upgrade that a later tidy found nothing left of" "! printf '%s' \"\$out\" | grep -q 'pull/30'"
rm -f "$a"/hive/decisions/tidy/2999-01-0[12].md "$b"/hive/decisions/tidy/2999-01-0[12].md
run b save >/dev/null 2>&1; run a sync >/dev/null 2>&1; run b sync >/dev/null 2>&1

# The core comes first in hive.lock, as hive-mind, and runs from that clone; anything else fails clearly.
git clone -q --bare "$tmp/remote.git" "$tmp/rt-core.git"
machine cf "$tmp/rt-core.git" && run cf install >/dev/null 2>&1
cf_head=$(git -C "$tmp/cf/hive" rev-parse HEAD)
git clone -q "$tmp/rt-core.git" "$tmp/rt-core-pr" &&
    awk '$1 == "hive-mind" { core = $0; next } { print } END { print core }' "$tmp/rt-core-pr/hive.lock" >"$tmp/rt-lock" &&
    mv "$tmp/rt-lock" "$tmp/rt-core-pr/hive.lock" && git -C "$tmp/rt-core-pr" commit -qam "core last" && git -C "$tmp/rt-core-pr" push -q origin main
out=$(run cf sync 2>&1); rc=$?
check "a lock that does not pin the core first fails the sync, saying so" "[ $rc != 0 ] && printf '%s' \"\$out\" | grep -q 'hive.lock must pin the core first, named hive-mind' && [ \"\$(git -C '$tmp/cf/hive' rev-parse HEAD)\" = '$cf_head' ]"
machine cs && mv "$tmp/cs/hive/hive-mind" "$tmp/cs/hive/core"
out=$(HOME="$tmp/cs/home" CLAUDE_CONFIG_DIR="$tmp/cs/cfg" "$tmp/cs/hive/core/bin/hive" status 2>&1)
check "status flags a core that runs from another clone than hive-mind" "printf '%s' \"\$out\" | grep -q '^  fix   hive.lock must pin the core first.*runs from $tmp/cs/hive/core'"

# --- uninstall ------------------------------------------------------------------------------------

run a uninstall >/dev/null 2>&1
check "uninstall restores the other settings" "python3 -c \"import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(a != b)\" '$tmp/settings.orig' '$a/cfg/settings.json'"
check "uninstall removes the links" "[ ! -e '$a/cfg/rules/hive' ] && [ ! -e '$a/cfg/skills/hive-skill' ]"
check "uninstall keeps the checkout" "[ -f '$a/hive/memory/feedback_new.md' ]"
check "uninstall removes the hive command" "[ ! -e '$a/home/.local/bin/hive' ] && [ ! -L '$a/home/.local/bin/hive' ]"
run b uninstall >/dev/null 2>&1
check "uninstall leaves another hive command alone" "grep -qx '#!/bin/sh' '$b/home/.local/bin/hive'"

echo
[ "$failures" = 0 ] && echo "hive.test: all passed" || echo "hive.test: $failures failed"
exit "$failures"
