#!/bin/sh
# End-to-end checks against a real Claude Code: sessions load the hive, a memory a session writes is
# pushed by the hooks, and a machine that only has the host-wide pointer is brought up by its first
# session, which follows the pointer. Opt-in, because it spends tokens: `sh tests/claude.test.sh`.
#
# Needs `claude` signed in with credentials in a file (${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json,
# as on Linux and in agentctl sandboxes; macOS keeps them in the keychain). HIVE_TEST_MODEL picks the
# model, default claude-sonnet-5-5: Haiku passes the rest but follows the host-wide pointer unprompted
# only now and then (1 run in 4 on 2026-10-25), while Sonnet (2 runs) and Opus (1) did each time.
# Built from the working tree, like hive.test.sh.
# shellcheck disable=SC2015,SC2030,SC2031 # `test && ok || fail`; AGENT_NAME set per session, in subshells
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
model=${HIVE_TEST_MODEL:-claude-sonnet-5-5}
# Some sessions here run with permissions skipped, so they can write memory and try the guard unattended:
# only inside a sandbox, where nothing they do can reach the machine running them.
[ -n "${AGENT_NAME:-}" ] || { echo "skip: runs Claude with permissions skipped; only inside an agentctl sandbox"; exit 0; }
creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
[ -f "$creds" ] || { echo "skip: no credentials file at $creds"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --file "$tmp/gitconfig" user.name tester
git config --file "$tmp/gitconfig" user.email tester@example.com
git config --file "$tmp/gitconfig" init.defaultBranch main
unset CLAUDE_CODE_SESSION_ID AGENT_NAME CLAUDECODE
export HIVE_TIDY=off

# The core's remote is the working tree; the hive's is the template, plus a memory and an instruction
# carrying codewords, pinning that core alone.
mkdir -p "$tmp/core-src" "$tmp/src"
(cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 tar cf - | tar xf - -C "$tmp/core-src")
git -C "$tmp/core-src" init -q && git -C "$tmp/core-src" add -A && git -C "$tmp/core-src" commit -qm snapshot
git clone -q --bare "$tmp/core-src" "$tmp/core.git"
(cd "$root/template" && git ls-files -co --exclude-standard -z | xargs -0 tar cf - | tar xf - -C "$tmp/src")
printf 'hive-mind %s %s\n' "$tmp/core.git" "$(git -C "$tmp/core-src" rev-parse HEAD)" >"$tmp/src/hive.lock"
printf -- '---\nname: codeword\ndescription: the memory codeword is CW-UNIFORM\nmetadata:\n  type: reference\n  date: 2026-10-25\n  verified: test fixture\n---\nCW-UNIFORM\n' \
    >"$tmp/src/memory/reference_codeword.md"
printf '## Test\n\nThe instructions codeword is CW-VICTOR.\n' >"$tmp/src/instructions/zz-test.md"
# No tidy logs, so the one the test tidy writes is the only one, and the check below can tell.
rm -rf "$tmp/src/decisions/tidy"
git -C "$tmp/src" init -q && git -C "$tmp/src" add -A && git -C "$tmp/src" commit -qm snapshot
git clone -q --bare "$tmp/src" "$tmp/remote.git"

machine() { # <name>: a home whose .claude holds credentials, and a work directory
    mkdir -p "$tmp/$1/home/.claude" "$tmp/$1/work"
    cp "$creds" "$tmp/$1/home/.claude/"
}
claude_on() { # <machine> <prompt> [extra flags]
    m=$1 p=$2; shift 2
    (cd "$tmp/$m/work" && HOME="$tmp/$m/home" CLAUDE_CONFIG_DIR="$tmp/$m/home/.claude" \
        claude -p --model "$model" "$@" "$p" </dev/null 2>&1)
}
ask_codewords='Without using any tools: list every token of the exact form CW-<LETTERS> that appears anywhere in your context (instructions, memory index, hook output). Reply with only the tokens, sorted, space separated, or NONE.'
on_remote() { git --git-dir="$tmp/remote.git" "$@"; }
# bring_up <dir>: the hive and its core, as the pointer's snippet clones them.
bring_up() {
    git clone -q "$tmp/remote.git" "$1" && git clone -q "$tmp/core.git" "$1/hive-mind" &&
        git -C "$1/hive-mind" checkout -q --detach "$(awk '{ print $3; exit }' "$1/hive.lock")"
}

# --- an installed machine -------------------------------------------------------------------------

machine a
bring_up "$tmp/a/home/hive"
HOME="$tmp/a/home" CLAUDE_CONFIG_DIR="$tmp/a/home/.claude" "$tmp/a/home/hive/hive-mind/bin/hive" install >/dev/null
out=$(claude_on a "$ask_codewords")
case "$out" in *CW-UNIFORM*) ok "an installed session loads the memory index" ;; *) fail "an installed session loads the memory index: $out" ;; esac
case "$out" in *CW-VICTOR*) ok "an installed session loads the instructions" ;; *) fail "an installed session loads the instructions: $out" ;; esac

claude_on a 'Save a memory, following your memory instructions exactly: the user told you the test password word is CW-WHISKEY. Then reply done.' \
    --dangerously-skip-permissions >"$tmp/write.log"
i=0
while [ $i -lt 60 ] && ! on_remote grep -q CW-WHISKEY main -- memory >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
if on_remote grep -q CW-WHISKEY main -- memory >/dev/null 2>&1; then ok "a memory written in a session is pushed by the hooks"
else fail "a memory written in a session is pushed by the hooks"; sed 's/^/     /' "$tmp/write.log"; cat "$tmp/a/home/hive/.git/hive/log" 2>/dev/null | sed 's/^/     log: /'; fi
subject=$(on_remote log -1 --format=%s main)
case "$subject" in "memory: add "*) ok "the push is one memory commit ($subject)" ;; *) fail "the push is one memory commit: $subject" ;; esac

# The guard: an instruction edit through the rules link is refused, and the checkout is untouched.
out=$(claude_on a 'Use your Edit or Write tool (not Bash) to append the line "CW-XRAY" to ~/.claude/rules/hive/working.md. If a hook refuses, quote its reason.' \
    --dangerously-skip-permissions)
if grep -q CW-XRAY "$tmp/a/home/hive/instructions/working.md"; then fail "the guard refuses an instruction edit: the file changed"
else ok "the guard refuses an instruction edit through the rules link"; fi
case "$out" in *"pull request"*|*worktree*) ok "the refusal says how instructions change" ;; *) fail "the refusal says how instructions change: $out" ;; esac

# A real automatic tidy, with its real permissions: it merges a memory holding two versions, logs what
# it did, and the hooks push both.
cat >"$tmp/a/home/hive/memory/feedback_twice.md" <<'MEM'
---
name: twice
description: example-repo PRs: squash-merge
metadata:
  type: feedback
  date: 2026-10-20
  verified: the user said so
---
Squash-merge pull requests in example-repo.

<!-- hive:sibling -->
Another session changed memory/feedback_twice.md at the same time. Both versions are kept: the one above and the one below. Reconcile them into one, and delete this marker and everything after it.

~~~~~~~~
---
name: twice
description: example-repo PRs: squash-merge, and delete the branch
metadata:
  type: feedback
  date: 2026-10-21
  verified: the user said so
---
Squash-merge pull requests in example-repo, and delete the branch afterwards.
~~~~~~~~
MEM
HOME="$tmp/a/home" CLAUDE_CONFIG_DIR="$tmp/a/home/.claude" "$tmp/a/home/hive/hive-mind/bin/hive" save >/dev/null 2>&1
HOME="$tmp/a/home" CLAUDE_CONFIG_DIR="$tmp/a/home/.claude" HIVE_TIDY=on HIVE_TIDY_MODEL="$model" \
    "$tmp/a/home/hive/hive-mind/bin/hive" tidy --auto
i=0
while [ $i -lt 120 ] && ! on_remote ls-tree -r --name-only main -- decisions | grep -q -- '^decisions/tidy/[^/]*\.md$'; do sleep 5; i=$((i + 1)); done
if on_remote ls-tree -r --name-only main -- decisions | grep -q -- '^decisions/tidy/[^/]*\.md$'; then ok "a real tidy logs what it did, and the log is pushed"
else fail "a real tidy logs what it did"; tail -n 20 "$tmp/a/home/hive/.git/hive/tidy.log" | sed 's/^/     /'; fi
sleep 10
if on_remote show main:memory/feedback_twice.md 2>/dev/null | grep -q 'hive:sibling'; then fail "a real tidy merges a memory with two versions"
else ok "a real tidy merges a memory with two versions"; fi
on_remote show main:memory/feedback_twice.md 2>/dev/null | grep -qi 'delete the branch' && ok "the merge keeps what both versions learned" || fail "the merge keeps what both versions learned"

# --- a sandbox with only the host-wide pointer, as agentd would put it in ~/.claude/CLAUDE.md --------

machine c
sed "s|https://github.com/OWNER/hive|$tmp/remote.git|g" "$root/template/sandbox/host-instructions.md" \
    >"$tmp/c/home/.claude/CLAUDE.md"
# A first message that is just a question, with no hint about instructions; only the hive's memory
# can answer it.
out=$(claude_on c "Quick one: what's the test password word I told you about? Answer with just the word." \
    --dangerously-skip-permissions)
case "$out" in *CW-WHISKEY*) ok "a pointer-only session brings the hive up unprompted and answers from its memory" ;; *) fail "a pointer-only session brings the hive up unprompted: $out" ;; esac
[ -L "$tmp/c/home/.claude/rules/hive" ] && ok "the machine is linked afterwards" || fail "the machine is linked afterwards"
out=$(claude_on c "$ask_codewords")
case "$out" in *CW-UNIFORM*CW-VICTOR*|*CW-VICTOR*CW-UNIFORM*) ok "its next session loads the hive natively" ;; *) fail "its next session loads the hive natively: $out" ;; esac

# --- sandboxes whose sessions check the hive with `hive status` before the first reply ------------

# Pointer, hive cloned and installed, as in a sandbox after its first session. In machine e the agent's
# own home has put back a settings.json that only blanks attribution, as some teams' agents ship.
for m in d e; do
    machine "$m"
    sed "s|https://github.com/OWNER/hive|$tmp/remote.git|g" "$root/template/sandbox/host-instructions.md" \
        >"$tmp/$m/home/.claude/CLAUDE.md"
    bring_up "$tmp/$m/home/hive"
    HOME="$tmp/$m/home" CLAUDE_CONFIG_DIR="$tmp/$m/home/.claude" "$tmp/$m/home/hive/hive-mind/bin/hive" install >/dev/null
done
printf '{\n  "attribution": {\n    "commit": "",\n    "pr": ""\n  }\n}\n' >"$tmp/e/home/.claude/settings.json"
ask_sum='Quick one: what is 6 times 7? Answer with just the number.'
ran_status() { grep -qs 'hive/hive-mind/bin/hive status' "$tmp/$1/home/.claude/projects"/*/*.jsonl; }
out=$(export AGENT_NAME=test-agent; claude_on d "$ask_sum" --dangerously-skip-permissions)
ran_status d && ok "a sandbox session runs hive status before its first reply" || fail "a sandbox session runs hive status before its first reply"
case "$out" in *42*) ;; *) fail "a healthy sandbox's session answers: $out" ;; esac
case "$out" in *sandbox/home*|*"use the hive"*) fail "a healthy sandbox's session warns about nothing: $out" ;; *) ok "a healthy sandbox's session warns about nothing" ;; esac
out=$(export AGENT_NAME=test-agent; claude_on e "$ask_sum" --dangerously-skip-permissions)
ran_status e || fail "a session whose settings lack the hive runs hive status"
case "$out" in *sandbox/home*42*) ok "a session whose settings lack the hive opens with the fix, then answers" ;;
    *) fail "a session whose settings lack the hive opens with the fix, then answers: $out" ;; esac

echo
[ "$failures" = 0 ] && echo "claude.test: all passed" || echo "claude.test: $failures failed"
exit "$failures"
