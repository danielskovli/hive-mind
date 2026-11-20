#!/bin/sh
# Prints what people said to the agents recently, one section per session, for the consolidation
# pass to read. Every human message is shown with the tail of the agent message it answered, because
# a correction ("no, keep the flag") means nothing without what it corrected. Tool output, subagent
# traffic, compaction summaries, slash-command wrappers and system reminders are left out. Lines that
# do not parse (a transcript still being written) are skipped, not fatal.
#
#   recent-turns.sh <dir> [hours]      default: the last 26 hours
#
# <dir> is either a projects root (every project below it) or one project directory: the parent of a
# memory directory, where Claude Code keeps that project's transcripts.
#
# Sessions that only ran unattended (print mode, a one-line prompt) still appear, with that prompt.
# Requires jq.
set -eu

root=${1:?usage: recent-turns.sh <dir> [hours]}
hours=${2:-26}
[ -d "$root" ] || { echo "recent-turns: $root is not a directory" >&2; exit 1; }
command -v jq >/dev/null || { echo "recent-turns: jq is required" >&2; exit 1; }

# Session transcripts only. Subagent transcripts sit deeper (<project>/<session>/subagents/) and
# hold no human turns. Read line by line so paths with spaces survive.
all=$(find "$root" -maxdepth 2 -name '*.jsonl' -mmin -$((hours * 60)) | sort | while IFS= read -r f; do
    out=$(jq -R 'fromjson? // empty' "$f" | jq -rs '
        def text:
            if type == "string" then .
            elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n")
            else "" end;
        def human:
            .type == "user" and (.isMeta | not) and (.isSidechain | not) and (.isCompactSummary | not)
            and ((.message.content | text) as $t
                 | ($t | length) > 0
                 and ($t | test("^\\s*<(command-|local-command-|system-reminder|task-notification)") | not));
        def clip($n): if length > $n then .[0:$n] + " […]" else . end;
        def tail($n): if length > $n then "[…] " + .[length - $n:] else . end;

        (map(select(.cwd != null)) | first // {}) as $meta
        | reduce .[] as $e ({last: "", turns: []};
            if $e.type == "assistant" and ($e.isSidechain | not) then
                ($e.message.content | text) as $t
                | if ($t | length) > 0 then .last = $t else . end
            elif ($e | human) then
                .turns += [{agent: .last, human: ($e.message.content | text), at: $e.timestamp}]
                | .last = ""
            else . end)
        | select(.turns | length > 0)
        | "## Session \($meta.sessionId // "?") — \($meta.cwd // "?") on \($meta.gitBranch // "?")\n",
          (.turns[] |
            (if .agent != "" then "> agent: " + (.agent | tail(400) | gsub("\n"; "\n> ")) + "\n" else empty end),
            "**human** (\(.at // "?")): " + (.human | clip(1200)) + "\n")
    ') || { echo "recent-turns: could not read $f" >&2; continue; }
    [ -n "$out" ] && printf '%s\n\n' "$out"
done)

if [ -n "$all" ]; then printf '%s\n' "$all"; else echo "No human turns in the last $hours hours."; fi
