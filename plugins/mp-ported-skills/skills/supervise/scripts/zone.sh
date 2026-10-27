#!/bin/sh
# zone.sh -- a background session's zone reading, read from its transcript,
# and with --due, whether the supervisor should capture it now (#60).
#
# Prints the reading as status-line.sh --zone does ("41% of zone"): the
# context of the session's last call, input plus cache read and written, as
# a percentage of the smart zone (MP_SMART_ZONE_K, default 150k tokens),
# rounded down. That is the count the status line records when it renders
# after a call, so the two agree as of the session's last call; between
# calls the status line can run a few points ahead, by what was added since. Only the main chain is read: a subagent's calls, on
# sidechain rows or in their own transcripts, are not the session's context.
# A background worker has no status line on screen, and its record is kept
# under whatever folder it runs in, so the transcript is the one source the
# supervisor can always read.
#
# With --due, a second line says whether the reading calls for a capture:
#   due                 at or past the capture point, at a safe point; or at
#                       or past the force point with no tool call running,
#                       when the line is `due: background task <id> is cut`
#   not due: <why>      below it, or not at a safe point, or no reading
# The capture point follows the worker's model, given with --model (#215):
# see ZONE_CAPTURE_WIDE below. With no --model, or a model whose window is
# not known, it is ZONE_CAPTURE.
# A safe point is one where stopping the session loses no work in flight:
# every tool call on the main chain has its result (a Bash command still
# running, a `git commit` included, or a foreground subagent, holds it), and
# every background command or async agent it started has reported back, by a
# <task-notification> naming its task id, as a prompt or queued. A worker's
# review agents can run for minutes, and workers crossed 100% of zone during
# review, so from the force point a background task no longer holds the capture:
# the stop ends it, and the continuation runs it again. A running tool call
# always holds it, since the stop would cut a command such as a commit.
#
# The transcript is parsed line by line, so a last line still being written
# is skipped rather than failing the read.
#
# With --compact MODEL, as watch.sh --zone runs it before its first poll,
# it reads no transcript: it works out the auto-compact point of a session
# on MODEL, in % of zone, from the model's context window and the override
# in force (compact.sh), and prints
#   compact point <N>% of zone (<P>% of a <W>k window)
#   capture due at <C>% of zone, forced at <F>%
# or refuses, exit 1, when the force point plus ZONE_MARGIN_K reaches it: the
# session could compact before a poll saw it due. A model whose window is
# not known, or an empty MODEL, is read as the smallest window, 200k, with a
# `note:` line on stderr saying so.
#
# Usage:
#   zone.sh (--id ID | --session SESSION | --transcript FILE) [--due [--model MODEL]]
#   zone.sh --compact MODEL
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
# the session compacts, by more than a worker's context grows between two
# polls: ZONE_MARGIN_K, the largest growth in 30 seconds measured in 107
# worker transcripts, 49,990 tokens (docs/research/zone-poll-margin.md).
# On a 200k window at CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 80, the smallest a
# worker runs on, the session compacts at 160k tokens, about 106% of zone,
# so the force point plus the margin, 72% of 150k plus 50k, stays below it
# (tests/supervise-zone.test.sh); --compact checks the running case.
ZONE_CAPTURE=64
# The reading from which a background task still running no longer holds
# the capture, 8 points past ZONE_CAPTURE.
ZONE_FORCE=72
ZONE_MARGIN_K=50
# A worker whose auto-compact point is at least ZONE_CAPTURE_ROOM points past
# ZONE_CAPTURE_WIDE, 150% of zone, is captured at ZONE_CAPTURE_WIDE instead,
# and forced the same 8 points later, at 108% (#215). The zone protects the
# build; the capture only reads the session back and writes a few comments
# and commits, so it may spend the room above 100%. Workers' captures added
# 10 to 13 points in the runs on #215, and 50 leaves room for a larger one.
# A 1M window at the default override compacts at about 533% of zone and
# takes the wide point; a 200k window, at about 106%, or one not known,
# keeps ZONE_CAPTURE.
ZONE_CAPTURE_WIDE=100
ZONE_CAPTURE_ROOM=50

ID=""
SESSION=""
FILE=""
DUE=""
COMPACT=""
HAS_COMPACT=""
MODEL=""
HAS_MODEL=""
sources=0
need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)         need_value "$@"; ID="$2"; sources=$((sources + 1)); shift 2 ;;
        --session)    need_value "$@"; SESSION="$2"; sources=$((sources + 1)); shift 2 ;;
        --transcript) need_value "$@"; FILE="$2"; sources=$((sources + 1)); shift 2 ;;
        --due)        DUE=1; shift ;;
        --compact)    need_value "$@"; COMPACT="$2"; HAS_COMPACT=1; shift 2 ;;
        --model)      need_value "$@"; MODEL="$2"; HAS_MODEL=1; shift 2 ;;
        --help)
            printf 'Usage: zone.sh (--id ID | --session SESSION | --transcript FILE) [--due [--model MODEL]]\n'
            printf '       zone.sh --compact MODEL\n'
            printf 'Prints "N%% of zone", then with --due "due" or "not due: <why>";\n'
            printf 'with --compact, "compact point N%% of zone (P%% of a Wk window)"\n'
            printf 'and "capture due at C%% of zone, forced at F%%", or refuses.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in '' | *[!0-9]* | 0) zone_k=150 ;; esac

# capture_points <model>: sets override and window_k as compact.sh gives them for
# the model, and capture and force, the points in % of zone that apply to
# it. Returns 1 when the window is not known.
capture_points() {
    . "$(dirname -- "$0")/compact.sh"
    override=$(compact_pct)
    known=0
    window_k=$(compact_window_k "$1") || known=1
    # The compact point against the wide point plus its room, both as tokens
    # in tens, so a point of exactly 150% takes the wide point.
    if [ $((window_k * override)) -ge $(((ZONE_CAPTURE_WIDE + ZONE_CAPTURE_ROOM) * zone_k)) ]; then
        capture=$ZONE_CAPTURE_WIDE
    else
        capture=$ZONE_CAPTURE
    fi
    force=$((capture + ZONE_FORCE - ZONE_CAPTURE))
    return $known
}

if [ -n "$HAS_COMPACT" ]; then
    [ "$sources" -eq 0 ] && [ -z "$DUE" ] && [ -z "$HAS_MODEL" ] || fail "--compact reads no transcript; give it alone"
    if capture_points "$COMPACT"; then :
    elif [ -z "$COMPACT" ]; then
        printf "note: the worker's model is not known, so the smallest context window, %sk, is used\n" "$window_k" >&2
    else
        printf 'note: the context window of model %s is not known, so the smallest, %sk, is used\n' "$COMPACT" "$window_k" >&2
    fi
    point="$((window_k * override / zone_k))% of zone ($override% of a ${window_k}k window)"
    # The force point's tokens plus the margin, against the window's share,
    # each in tens of tokens.
    [ $((force * zone_k + ZONE_MARGIN_K * 100)) -lt $((window_k * override)) ] ||
        fail "the zone capture's force point, $force% of zone, plus the largest growth measured between two polls, ${ZONE_MARGIN_K}k tokens, reaches the worker's auto-compact point, $point, so it could compact before the capture"
    echo "compact point $point"
    echo "capture due at $capture% of zone, forced at $force%"
    exit 0
fi
[ "$sources" -eq 1 ] || fail "give one of --id, --session or --transcript"
[ -z "$HAS_MODEL" ] || [ -n "$DUE" ] || fail "--model is read only with --due"
capture_points "$MODEL" || :

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
row=$(jq -Rrn --argjson z "$zone_k" '
    [inputs | fromjson? | objects] as $rows
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
    | [$rows[] | if .type == "queue-operation" then .content
                 elif .type == "user" and .origin.kind? == "task-notification" then .message.content
                 else empty end
       | if type == "array" then map(.text? // empty) | join("\n") else . end
       | strings | scan("<task-id>([^<]*)</task-id>") | .[0]] as $ended
    | ($started - $ended) as $running
    | [$pct, (if ($calls - $results) != [] or $calling then "call" else "" end),
       ($running[0] // "")] | @tsv' "$FILE" 2>/dev/null) || fail "transcript $FILE could not be read"
pct=$(printf '%s\n' "$row" | cut -f1)
calling=$(printf '%s\n' "$row" | cut -f2)
task=$(printf '%s\n' "$row" | cut -f3)
case $pct in '' | *[!0-9-]*) fail "transcript $FILE gave no reading" ;; esac

if [ "$pct" -lt 0 ]; then
    echo "No reading yet: the session has made no call"
    [ -z "$DUE" ] || echo "not due: no reading"
    exit 2
fi
echo "$pct% of zone"
[ -n "$DUE" ] || exit 0
if [ "$pct" -lt "$capture" ]; then
    echo "not due: below $capture% of zone"
    exit 2
elif [ -n "$calling" ]; then
    echo "not due: a tool call is running"
    exit 2
elif [ -n "$task" ] && [ "$pct" -lt "$force" ]; then
    echo "not due: background task $task is running"
    exit 2
elif [ -n "$task" ]; then
    echo "due: background task $task is cut"
    exit 0
fi
echo due
