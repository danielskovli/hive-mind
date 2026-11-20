#!/bin/sh
# What must hold in a hive however it got there: its content, the memory index within budget, the tidy
# running, the Worklog backup intact. The hive's own workflow (template/.github/workflows/check.yml) runs
# it on every pull request and daily. The hooks and bin/hive prevent each of these; this catches what
# slips past them. Runs against the hive this core sits in: `sh <hive>/hive-mind/tests/invariants.sh`.
# Prints ok or FAIL per check; the exit code is the number of failures.
# shellcheck disable=SC2015 # `test && ok || fail`: ok only prints
set -u

core=$(cd "$(dirname "$0")/.." && pwd)
root=$(dirname "$core")
failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

# Memories carry the frontmatter the index relies on. date and verified are asked of sessions but not
# required here: the consolidation pass adds them where a session left them out.
for f in "$root"/memory/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in MEMORY.md) continue ;; esac
    head -1 "$f" | grep -qx -- '---' \
        && grep -q '^name: .' "$f" \
        && grep -q '^description: .' "$f" \
        && grep -Eq '^  type: (feedback|project|reference|user)$' "$f" \
        && ok "memory frontmatter: $(basename "$f")" || fail "memory frontmatter: $(basename "$f") (name, description, metadata.type)"
done

# Decisions are dated, titled and say why; tidy logs are dated and titled.
for f in "$root"/decisions/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = README.md ] && continue
    basename "$f" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md$' \
        && head -1 "$f" | grep -q '^# ' \
        && { grep -q '^\*\*Why' "$f" || basename "$f" | grep -Eq -- '-retro\.md$'; } \
        && ok "decision: $(basename "$f")" || fail "decision: $(basename "$f") (YYYY-MM-DD-slug.md, a # title, a **Why** section)"
done
for f in "$root"/decisions/tidy/*.md; do
    [ -f "$f" ] || continue
    basename "$f" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' && head -1 "$f" | grep -q '^# ' \
        && ok "tidy log: $(basename "$f")" || fail "tidy log: $(basename "$f") (YYYY-MM-DD.md, a # title)"
done

# Every skill of the hive's own has a SKILL.md whose name matches its directory.
for d in "$root"/skills/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    grep -qx "name: $s" "$d/SKILL.md" 2>/dev/null && ok "skill name: $s" || fail "skill name: $s"
done

markers=$(grep -rlE '^(<<<<<<<|>>>>>>>) ' "$root/memory" "$root/decisions" 2>/dev/null)
[ -z "$markers" ] && ok "no conflict markers in memory or decisions" || fail "conflict markers in: $markers"

"$core/bin/hive" index
grep -q 'more memories are not listed' "$root/memory/MEMORY.md" \
    && fail "the memory index is over its budget: $(tail -n 1 "$root/memory/MEMORY.md")" \
    || ok "the memory index is within its budget ($(wc -l <"$root/memory/MEMORY.md" | tr -d ' ') lines)"

siblings=$(grep -l '^<!-- hive:sibling' "$root"/memory/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$siblings" -le 5 ] && ok "$siblings memory file(s) with two versions" || fail "$siblings memory files with two versions: is the tidy running?"

# The tidy: ten days since the last one, or, before the first, since the first memory (the template's
# memory/.gitkeep is none). A hive with no memory has nothing to tidy.
if ! git -C "$root" ls-tree -r --name-only HEAD -- memory | grep '\.md$' | grep -qv '^memory/MEMORY\.md$'; then
    ok "no memory yet, so no tidy is due"
else
    last=$(git -C "$root" log -1 --format=%ct -- 'decisions/tidy/*.md')
    [ -n "$last" ] || last=$(git -C "$root" log --reverse --format=%ct -- 'memory/*.md' | head -n 1)
    if [ $(( $(date +%s) - last )) -gt $((10 * 86400)) ]; then
        fail "no tidy has run for ten days: is the tidy off on every machine?"
    else
        ok "a tidy ran, or memory began, less than ten days ago"
    fi
fi

# The Worklog backup, where the hive keeps one: whole JSON, as a restore needs it, and fresh.
now=$(git -C "$root" ls-tree -r --name-only HEAD -- worklog/data | grep -c '\.json$')
if [ "$now" != 0 ]; then
    bad=$(find "$root/worklog/data" -name '*.json' -exec sh -c 'python3 -m json.tool "$1" >/dev/null 2>&1 || echo "$1"' _ {} \; 2>/dev/null)
    [ -z "$bad" ] && ok "worklog backup is valid JSON ($now documents)" || fail "worklog backup is valid JSON: $bad"
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
