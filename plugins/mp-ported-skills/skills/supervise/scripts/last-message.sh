#!/bin/sh
# last-message.sh -- print a supervised worker's last message, from its
# transcript (#71).
#
# Finds the background session with the given short id in `claude agents
# --json --all`, takes its sessionId, and reads the transcript
# `$CLAUDE_CONFIG_DIR/projects/*/<session id>.jsonl` in any project folder:
# a worker that entered a worktree has its whole transcript moved to the
# worktree's folder, so its cwd does not locate it (#73). Prints the text of
# the worker's last assistant message, or of its last N with --count, oldest
# first and separated by a blank line. A subagent's rows (isSidechain) are
# left out.
#
# Not `claude logs ID`: that prints the worker's raw terminal stream, cursor
# moves and colour codes included, with characters lost where the screen
# redrew them.
#
# When the transcript's last conversation row is not the end of a turn, or
# is a turn_duration row with background agents pending, the message may not
# be the worker's final one: their reports start another turn, and the text
# before them is often an interim "waiting for agents" note. A `note:` line
# on stderr says so.
#
# Usage:
#   last-message.sh --id ID [--count N]
#
# Exits 0 when it printed a message; 1, printing nothing on stdout, when
# `claude agents` could not be read, names no such worker, its transcript
# is not found, or it holds no message from the worker yet.

set -u

ID=""
COUNT=1

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)    need_value "$@"; ID="$2"; shift 2 ;;
        --count) need_value "$@"; COUNT="$2"; shift 2 ;;
        --help)
            printf 'Usage: last-message.sh --id ID [--count N]\n'
            printf 'Prints the worker'\''s last assistant message (or last N) from its transcript\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
case $COUNT in
    '' | *[!0-9]* | 0 | 0*) fail "--count must be a whole number of 1 or more" ;;
esac
# claude agents and the transcripts both follow the config dir, so an unset
# one would read another profile's sessions.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the worker's profile is unknown"

agents=$(claude agents --json --all </dev/null 2>/dev/null) &&
    printf '%s' "$agents" | jq -e 'type == "array"' >/dev/null 2>&1 ||
    fail "claude agents --json --all could not be read"
sid=$(printf '%s' "$agents" | jq -r --arg id "$ID" '
    [.[] | select(.kind == "background" and .id == $id)] | first | .sessionId // empty')
[ -n "$sid" ] || fail "claude agents lists no background session $ID"

transcript=""
for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl; do
    [ -f "$t" ] && { transcript=$t; break; }
done
[ -n "$transcript" ] || fail "no transcript for worker $ID (session $sid) under $CLAUDE_CONFIG_DIR/projects"

# One JSON value: the last COUNT messages' text, and the transcript's last
# conversation row, to tell whether the turn is over. Claude Code writes an
# assistant row per content block, so rows sharing a message id are one
# message; a row with no id is a message of its own.
read_out=$(jq -s --argjson n "$COUNT" '
    [.[] | select(.isSidechain | not)] as $rows
    | {
        texts: ([$rows | to_entries[] | select(.value.type == "assistant")
                 | {key: (.value.message.id // "row \(.key)"),
                    text: [.value.message.content[]? | select(.type == "text") | .text // empty]}]
                | reduce .[] as $r ([];
                    if length > 0 and .[-1].key == $r.key
                    then .[-1].text += $r.text else . + [$r] end)
                | [.[] | select(.text | length > 0) | .text | join("\n\n")] | .[-$n:]),
        last: ([$rows[] | select(.type == "user" or .type == "assistant" or .type == "system")] | last)
      }' "$transcript" 2>/dev/null) || fail "the transcript $transcript could not be read"

[ "$(printf '%s' "$read_out" | jq '.texts | length')" -gt 0 ] ||
    fail "the transcript of worker $ID holds no message from it yet"

printf '%s' "$read_out" | jq -r '.texts | join("\n\n")'

printf '%s' "$read_out" | jq -r '
    .last
    | if .type == "system" and .subtype == "turn_duration" then
        if (.pendingBackgroundAgentCount // 0) > 0 then
          "note: the worker'"'"'s turn ended with \(.pendingBackgroundAgentCount) background agents pending; this may be an interim message, not its final summary"
        else empty end
      else
        "note: the worker'"'"'s turn has not ended; this is its latest message so far"
      end' >&2
