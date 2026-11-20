#!/bin/sh
# What must hold on a hive's main however it got there, checked daily by the hive's own workflow
# (template/.github/workflows/check.yml), which tells its owner when it fails. The hooks and bin/hive
# prevent each of these; this catches what slips past them. Runs against the hive this core sits in:
# `sh <hive>/hive-mind/tests/invariants.sh`. Prints ok or FAIL per check; the exit code is the number
# of failures.
set -u

core=$(cd "$(dirname "$0")/.." && pwd)
root=$(dirname "$core")
failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

markers=$(grep -rlE '^(<<<<<<<|>>>>>>>) ' "$root/memory" "$root/decisions" 2>/dev/null)
[ -z "$markers" ] && ok "no conflict markers in memory or decisions" || fail "conflict markers in: $markers"

"$core/bin/hive" index
grep -q 'more memories are not listed' "$root/memory/MEMORY.md" \
    && fail "the memory index is over its budget: $(tail -n 1 "$root/memory/MEMORY.md")" \
    || ok "the memory index is within its budget ($(wc -l <"$root/memory/MEMORY.md" | tr -d ' ') lines)"

siblings=$(grep -l '^<!-- hive:sibling' "$root"/memory/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$siblings" -le 5 ] && ok "$siblings memory file(s) with two versions" || fail "$siblings memory files with two versions: is the tidy running?"
# A hive with no memory yet has nothing for a tidy to do.
if [ -z "$(git -C "$root" log -1 --format=%H -- memory 2>/dev/null)" ]; then
    ok "no memory yet, so no tidy is due"
else
    last=$(git -C "$root" log -1 --format=%ct -- 'decisions/tidy/*.md')
    if [ -z "$last" ] || [ $(( $(date +%s) - last )) -gt $((10 * 86400)) ]; then
        fail "no tidy has run for ten days: is the tidy off on every machine?"
    else
        ok "the last tidy ran less than ten days ago"
    fi
fi

# The Worklog backup, where the hive keeps one.
now=$(git -C "$root" ls-tree -r --name-only HEAD -- worklog/data | grep -c '\.json$')
if [ "$now" != 0 ]; then
    day=$(git -C "$root" rev-list -1 --before="1 day ago" HEAD 2>/dev/null)
    if [ -n "$day" ]; then
        then_=$(git -C "$root" ls-tree -r --name-only "$day" -- worklog/data | grep -c '\.json$')
        [ "$now" -ge $((then_ / 2)) ] && ok "Worklog backup: $now documents (a day ago: $then_)" \
            || fail "the Worklog backup fell from $then_ to $now documents in a day"
    fi
    last=$(git -C "$root" log -1 --format=%ct -- worklog/data)
    if [ -n "$last" ] && [ $(( $(date +%s) - last )) -gt $((14 * 86400)) ]; then
        fail "the Worklog backup is more than two weeks old"
    else
        ok "the Worklog backup is less than two weeks old"
    fi
fi

echo
[ "$failures" = 0 ] && echo "invariants: all hold" || echo "invariants: $failures broken"
exit "$failures"
