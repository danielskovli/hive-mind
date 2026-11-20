#!/bin/sh
# Every offline check of the core: `sh tests/check.sh`. The content checks and the scenarios run against
# a hive built from template/, or against the hive checkout HIVE_TEST_HIVE names (a hive's own CI sets it
# to itself). Every check prints ok or FAIL; the exit code is the number of failures. Nothing here touches
# ~/.claude or any live checkout's git state.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
hive=${HIVE_TEST_HIVE:-$root/template}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

# Shell scripts parse under a strict POSIX shell (dash where available), and lint clean if shellcheck is
# installed.
posix=$(command -v dash || command -v sh)
for f in "$root"/bin/hive "$root"/tests/*.sh "$root"/skills/*/scripts/*.sh; do
    "$posix" -n "$f" 2>/dev/null && ok "parses: ${f#"$root"/}" || fail "parses: ${f#"$root"/}"
done
if command -v shellcheck >/dev/null; then
    for f in "$root/bin/hive"; do
        shellcheck -s sh "$f" >"$tmp/sc" 2>&1 && ok "shellcheck: ${f#"$root"/}" || { fail "shellcheck: ${f#"$root"/}"; sed 's/^/     /' "$tmp/sc"; }
    done
else
    echo "skip shellcheck: not installed"
fi
[ -x "$root/bin/hive" ] && ok "bin/hive is executable" || fail "bin/hive is executable"

# The core names no person and no employer: it is anyone's. The pattern is split so this file does not
# match itself; links to the core's and agent-skills' own repositories are their address, not a name.
names="dan""iel|sko""vli|alt""inn|dig""dir"
home="github\.com/dan""ielsko""vli/(hive-mind|agent-skills)"
named=$(cd "$root" && git ls-files -co --exclude-standard | grep -vx LICENSE | while IFS= read -r f; do
    [ -f "$f" ] || continue
    sed -E "s#$home##g" "$f" | grep -inE "$names" | sed "s#^#$f:#"
done)
[ -z "$named" ] && ok "the core names no person or employer" || { fail "the core names no person or employer"; printf '%s\n' "$named" | head -n 20 | sed 's/^/     /'; }

# The hive's content: the Worklog backup is whole JSON, as a restore needs it.
if [ -d "$hive/worklog/data" ]; then
    bad=$(find "$hive/worklog/data" -name '*.json' -exec sh -c 'python3 -m json.tool "$1" >/dev/null 2>&1 || echo "$1"' _ {} \; 2>/dev/null)
    [ -z "$bad" ] && ok "worklog backup is valid JSON ($(find "$hive/worklog/data" -name '*.json' | wc -l | tr -d ' ') documents)" || fail "worklog backup is valid JSON: $bad"
fi

# Memories carry the frontmatter the index relies on. date and verified are asked of sessions but not
# required here: the consolidation pass adds them where a session left them out.
for f in "$hive"/memory/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in MEMORY.md) continue ;; esac
    head -1 "$f" | grep -qx -- '---' \
        && grep -q '^name: .' "$f" \
        && grep -q '^description: .' "$f" \
        && grep -Eq '^  type: (feedback|project|reference|user)$' "$f" \
        && ok "memory frontmatter: $(basename "$f")" || fail "memory frontmatter: $(basename "$f") (name, description, metadata.type)"
done

# Decisions are dated, titled and say why.
for f in "$hive"/decisions/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = README.md ] && continue
    basename "$f" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md$' \
        && head -1 "$f" | grep -q '^# ' \
        && { grep -q '^\*\*Why' "$f" || basename "$f" | grep -Eq -- '-retro\.md$'; } \
        && ok "decision: $(basename "$f")" || fail "decision: $(basename "$f") (YYYY-MM-DD-slug.md, a # title, a **Why** section)"
done
# Tidy logs are dated and titled.
for f in "$hive"/decisions/tidy/*.md; do
    [ -f "$f" ] || continue
    basename "$f" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' && head -1 "$f" | grep -q '^# ' \
        && ok "tidy log: $(basename "$f")" || fail "tidy log: $(basename "$f") (YYYY-MM-DD.md, a # title)"
done

# Every skill, the core's and the hive's, has a SKILL.md whose name matches its directory.
for d in "$root"/skills/*/ "$hive"/skills/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    grep -qx "name: $s" "$d/SKILL.md" 2>/dev/null && ok "skill name: $s" || fail "skill name: $s"
done

# The template is a hive: a lock whose first source is this core, and the files setup fills in.
lock="$root/template/hive.lock"
[ "$(awk '!/^[[:space:]]*(#|$)/ { print $1; exit }' "$lock")" = hive-mind ] && ok "the template's lock pins the core first" || fail "the template's lock pins the core first"
for f in instructions/me.md instructions/working.md sandbox/host-instructions.md .gitignore .github/workflows/check.yml; do
    [ -f "$root/template/$f" ] && ok "the template has $f" || fail "the template has $f"
done

# recent-turns keeps human turns with the agent text they answered, and drops everything else.
turns="$root/skills/consolidate-hive/scripts/recent-turns.sh"
mkdir -p "$tmp/turns"
cp -R "$root/tests/fixtures/projects" "$tmp/turns/"
find "$tmp/turns" -name '*.jsonl' -exec touch {} +
out=$(sh "$turns" "$tmp/turns/projects" 1)
for want in "Implement issue 12345 please." "No, we don't want ! operators anywhere." "null-forgiving operator to silence" "Session s-1" "LAST-HUMAN-TURN"; do
    printf '%s' "$out" | grep -qF "$want" && ok "recent-turns keeps: $want" || fail "recent-turns keeps: $want"
done
for unwanted in META-CAVEAT COMMAND-WRAPPER TOOL-OUTPUT SIDECHAIN-TEXT REMINDER COMPACT-SUMMARY; do
    printf '%s' "$out" | grep -qF "$unwanted" && fail "recent-turns drops: $unwanted" || ok "recent-turns drops: $unwanted"
done
out=$(sh "$turns" "$tmp/turns/projects/-home-agent-code" 1)
printf '%s' "$out" | grep -qF "Session s-1" && ok "recent-turns accepts a project directory" || fail "recent-turns accepts a project directory"
mkdir -p "$tmp/with space" && cp -R "$tmp/turns/projects" "$tmp/with space/" && find "$tmp/with space" -name '*.jsonl' -exec touch {} +
out=$(sh "$turns" "$tmp/with space/projects" 1 2>&1)
printf '%s' "$out" | grep -qF "LAST-HUMAN-TURN" && ok "recent-turns survives a path with a space" || fail "recent-turns survives a path with a space"
find "$tmp/turns" -name '*.jsonl' -exec touch -t 202001010000 {} +
out=$(sh "$turns" "$tmp/turns/projects" 1)
printf '%s' "$out" | grep -qF "No human turns" && ok "recent-turns skips old transcripts" || fail "recent-turns skips old transcripts"

# The daily check fails when no tidy has run for ten days, as when the tidy is off everywhere, and
# passes again once one has.
stale="$tmp/stale"
mkdir -p "$stale/hive-mind/tests" "$stale/memory" "$stale/decisions"
cp -R "$root/bin" "$stale/hive-mind/" && cp "$root/tests/invariants.sh" "$stale/hive-mind/tests/" && cp "$root/template/hive.lock" "$stale/"
printf -- '---\nname: m\ndescription: d\nmetadata:\n  type: feedback\n---\nx\n' >"$stale/memory/m.md"
printf '/hive-mind/\nmemory/MEMORY.md\n' >"$stale/.gitignore"
sg() { GIT_CONFIG_GLOBAL=/dev/null git -C "$stale" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
# A subshell: in POSIX sh an assignment before a function call outlives it, and would backdate the next commit too.
sg init -q && sg add -A && (GIT_COMMITTER_DATE="$(( $(date +%s) - 11 * 86400 )) +0000"; export GIT_COMMITTER_DATE; sg commit -qm old)
sh "$stale/hive-mind/tests/invariants.sh" 2>/dev/null | grep -q '^FAIL no tidy has run for ten days' \
    && ok "the daily check fails ten days after the last tidy" || fail "the daily check fails ten days after the last tidy"
mkdir -p "$stale/decisions/tidy" && printf '# Tidy, 2099-01-01\n' >"$stale/decisions/tidy/2099-01-01.md" && sg add -A && sg commit -qm tidy
sh "$stale/hive-mind/tests/invariants.sh" 2>/dev/null | grep -q '^ok   the last tidy ran less than ten days ago' \
    && ok "the daily check passes after a tidy" || fail "the daily check passes after a tidy"

# A hive just made from the template has no memory yet, so its first daily check asks for no tidy.
fresh="$tmp/fresh"
mkdir -p "$fresh/hive-mind/tests" && cp -R "$root/template/." "$fresh/" && cp -R "$root/bin" "$fresh/hive-mind/" && cp "$root/tests/invariants.sh" "$fresh/hive-mind/tests/"
fg() { GIT_CONFIG_GLOBAL=/dev/null git -C "$fresh" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
fg init -q && fg add -A && fg commit -qm "A new hive"
sh "$fresh/hive-mind/tests/invariants.sh" >"$tmp/fresh.out" 2>&1 \
    && ok "the daily check passes on a hive just made from the template" || { fail "the daily check passes on a hive just made from the template"; grep '^FAIL' "$tmp/fresh.out" | sed 's/^/     /'; }

# bin/hive against throwaway machines, under this system's sh and under bash --posix, which is what
# /bin/sh is on macOS.
sh "$root/tests/hive.test.sh" >"$tmp/hive.log" 2>&1 && ok "hive scenarios ($(grep -c '^ok' "$tmp/hive.log") checks)" || { fail "hive scenarios"; sed 's/^/     /' "$tmp/hive.log"; }
if command -v bash >/dev/null; then
    HIVE_SH="bash --posix" sh "$root/tests/hive.test.sh" >"$tmp/hive-bash.log" 2>&1 && ok "hive scenarios under bash --posix" || { fail "hive scenarios under bash --posix"; grep '^FAIL' "$tmp/hive-bash.log" | sed 's/^/     /'; }
fi

echo
[ "$failures" = 0 ] && echo "check: all passed" || echo "check: $failures failed"
exit "$failures"
