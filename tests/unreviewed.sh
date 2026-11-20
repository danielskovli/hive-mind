#!/bin/sh
# Prints the commits on the hive's HEAD since [since] (default: a day ago) that change more than
# memory/, decisions/, worklog/ and hive.lock, which hooks and `hive upgrade` commit: anything else should
# come by pull request. The hive's first commit, made by its setup, is not one. The hive's daily workflow
# asks GitHub which of these belong to a pull request. Runs against the hive this core sits in.
set -u

root=$(dirname "$(cd "$(dirname "$0")/.." && pwd)")
git -C "$root" rev-list --since="${1:-1 day ago}" --no-merges --min-parents=1 HEAD | while IFS= read -r sha; do
    outside=$(git -C "$root" show --name-only --format= "$sha" | grep -v -e '^memory/' -e '^decisions/' -e '^worklog/' -e '^hive\.lock$' || true)
    [ -z "$outside" ] || echo "$sha"
done
