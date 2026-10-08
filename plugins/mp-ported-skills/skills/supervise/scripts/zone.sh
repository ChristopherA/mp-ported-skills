#!/bin/sh
# zone.sh -- a background session's zone reading, read from its transcript,
# and with --due, whether the supervisor should capture it now (#60).
#
# Prints the reading as status-line.sh --zone does ("41% of zone"): the
# context of the session's last call, input plus cache read and written, as
# a percentage of the smart zone (MP_SMART_ZONE_K, default 150k tokens),
# rounded down. That is the count the status line records, so the two agree
# for the same call. Only the main chain is read: a subagent's calls, on
# sidechain rows or in their own transcripts, are not the session's context.
# A background worker has no status line on screen, and its record is kept
# under whatever folder it runs in, so the transcript is the one source the
# supervisor can always read.
#
# With --due, a second line says whether the reading calls for a capture:
#   due                 at or past ZONE_CAPTURE, at a safe point
#   not due: <why>      below it, or not at a safe point, or no reading
# A safe point is one where stopping the session loses no work in flight:
# every tool call on the main chain has its result (a Bash command still
# running, a `git commit` included, or a foreground subagent, holds it), and
# every background command or async agent it started has reported back, by a
# <task-notification> naming its task id, as a prompt or queued.
#
# Usage:
#   zone.sh (--id ID | --session SESSION | --transcript FILE) [--due]
#
# --id reads the session from the job's state.json under $CLAUDE_CONFIG_DIR;
# --session finds its transcript in any project folder, since a session that
# entered a worktree has its transcript moved.
#
# Exits 0 with a reading (with --due: due), 2 with none yet (with --due: not
# due), 1 on an error.

set -u

# The worker's zone reading, in % of zone, at which the supervisor captures
# it and continues the ticket in a fresh session. It must be reached before
# the session compacts: with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE at 80, a 200k
# window compacts at about 106% of zone, and one tool result between polls
# can add up to Read's cap of 25k tokens, 17 points (tests/supervise-zone.test.sh).
ZONE_CAPTURE=80

ID=""
SESSION=""
FILE=""
DUE=""
sources=0
need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)         need_value "$@"; ID="$2"; sources=$((sources + 1)); shift 2 ;;
        --session)    need_value "$@"; SESSION="$2"; sources=$((sources + 1)); shift 2 ;;
        --transcript) need_value "$@"; FILE="$2"; sources=$((sources + 1)); shift 2 ;;
        --due)        DUE=1; shift ;;
        --help)
            printf 'Usage: zone.sh (--id ID | --session SESSION | --transcript FILE) [--due]\n'
            printf 'Prints "N%% of zone", then with --due "due" or "not due: <why>".\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ "$sources" -eq 1 ] || fail "give one of --id, --session or --transcript"
zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in '' | *[!0-9]* | 0) zone_k=150 ;; esac

if [ -n "$ID" ]; then
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the job is unknown"
    job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
    [ -f "$job" ] || fail "no job state for $ID under $CLAUDE_CONFIG_DIR/jobs"
    SESSION=$(jq -r '.sessionId // empty' "$job" 2>/dev/null)
    [ -n "$SESSION" ] || fail "job state $job names no session"
fi
if [ -n "$SESSION" ]; then
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the transcript is unknown"
    for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$SESSION".jsonl; do
        [ -f "$t" ] && { FILE=$t; break; }
    done
    [ -n "$FILE" ] || fail "no transcript for session $SESSION under $CLAUDE_CONFIG_DIR/projects"
fi
[ -f "$FILE" ] || fail "no such transcript: $FILE"

# One row: the reading, or -1 with no call yet, then the first thing still
# running, or empty at a safe point.
row=$(jq -rs --argjson z "$zone_k" '
    [.[] | objects] as $rows
    | [$rows[] | select((.isSidechain // false) | not)] as $main
    | ([$main[] | select(.type == "assistant" and .message.usage != null)] | last) as $last
    | (if $last == null then -1
       else $last.message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
            + (.cache_creation_input_tokens // 0)) * 100 / ($z * 1000) | floor end) as $pct
    | [$main[] | select(.type == "assistant") | .message.content[]? | objects
       | select(.type == "tool_use") | .id // empty] as $calls
    | [$main[] | select(.type == "user") | .message.content | if type == "array" then .[] else empty end
       | objects | select(.type == "tool_result") | .tool_use_id // empty] as $results
    | ([$main[] | select(.type == "user" or .type == "assistant")] | last) as $end
    | ($end != null and $end.type == "assistant"
       and any($end.message.content[]?; type == "object" and .type == "tool_use")) as $calling
    | [$main[] | select(.type == "user") | .toolUseResult? | objects
       | .backgroundTaskId // (select(.isAsync == true) | .agentId) // empty] as $started
    | [$rows[] | tostring | scan("<task-id>([^<]*)</task-id>") | .[0]] as $ended
    | ($started - $ended) as $running
    | [$pct, (if ($calls - $results) != [] or $calling then "a tool call is running"
              elif $running != [] then "background task \($running[0]) is running"
              else "" end)] | @tsv' "$FILE" 2>/dev/null) || fail "transcript $FILE could not be read"
pct=$(printf '%s\n' "$row" | cut -f1)
busy=$(printf '%s\n' "$row" | cut -f2)

if [ "$pct" -lt 0 ]; then
    echo "No reading yet: the session has made no call"
    [ -z "$DUE" ] || echo "not due: no reading"
    exit 2
fi
echo "$pct% of zone"
[ -n "$DUE" ] || exit 0
if [ "$pct" -lt "$ZONE_CAPTURE" ]; then
    echo "not due: below $ZONE_CAPTURE% of zone"
    exit 2
elif [ -n "$busy" ]; then
    echo "not due: $busy"
    exit 2
fi
echo due
