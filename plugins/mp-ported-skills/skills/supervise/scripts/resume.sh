#!/bin/sh
# resume.sh -- send a follow-up prompt to a background session, by stop and
# resume.
#
# No command sends input to a running background session, so this stops the
# session, waits until it is safe to resume, and runs `claude --bg --resume
# <session id> '<prompt>'` in DIR, with no flags: any flag makes the resume
# start a copy (ADR 0003). The session id is the job's `sessionId`, the
# original id, which stays the handle for resuming even after a /clear.
#
# Safe to resume is the first of:
#   - `claude agents --json --all` shows the session `stopped`;
#   - its row has shown no pid for SETTLE seconds. `stopped` may never show
#     (#77 saw it missing 30 seconds after a stop that had finished), and a
#     resume issued the moment the pid went started a copy, while the same
#     resume 47 seconds later woke the original. A pid showing again starts
#     the settle time over.
# Before each resume it checks that no other background session is live in
# the worker's checkout, since two workers there interleave their commits.
#
# `claude --bg --resume` prints `woke session <id>` when it woke the original
# and `started a copy as <id>` when it did not. A copy runs without the
# launch's saved options (the EnterWorktree deny, auto mode, the chosen
# model), so it is stopped and removed at once and the resume retried on the
# original, up to TRIES resumes in all.
#
# Prints `copy <id> stopped and removed` for each copy (or `stopped, not
# removed` when `claude rm` failed), then `after <epoch>` and `resumed <id>`.
# `after` is the time, in epoch seconds, taken just before the resume that
# woke the worker: pass it to the next watch.sh as --after, or that watch
# reads the turn that ended before the stop as the resumed turn's end (#122).
# On a wake it writes the worker's marker in DIR, and in the Project's
# Distribution repo when it names one, as launch.sh does (#76, #125), with
# a `note` line before `after` for each it could not write.
#
# Usage:
#   resume.sh --id ID --dir DIR --prompt TEXT [--settle S] [--interval S]
#             [--timeout S] [--tries N]
#
# DIR is the Project folder the worker runs in. SETTLE defaults to 60,
# INTERVAL (between reads of the list) to 5, TIMEOUT (for each wait) to 300,
# TRIES to 3.
#
# Exits 0 resumed the original; 1 nothing resumed (the session is left as
# the stop left it); 2 every resume started a copy, each removed, and the
# original is left stopped.

set -u

ID=""
DIR=""
PROMPT=""
SETTLE=60
INTERVAL=5
TIMEOUT=300
TRIES=3

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --prompt)   need_value "$@"; PROMPT="$2"; shift 2 ;;
        --settle)   need_value "$@"; SETTLE="$2"; shift 2 ;;
        --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --tries)    need_value "$@"; TRIES="$2"; shift 2 ;;
        --help)
            printf 'Usage: resume.sh --id ID --dir DIR --prompt TEXT [--settle S] [--interval S] [--timeout S] [--tries N]\n'
            printf 'Stops the session, waits until it is safe, and resumes it with the prompt. Prints copy lines, then: after EPOCH, resumed ID\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$PROMPT" ] || fail "--prompt is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
for v in "settle $SETTLE" "interval $INTERVAL" "timeout $TIMEOUT" "tries $TRIES"; do
    case ${v#* } in '' | *[!0-9]*) fail "--${v%% *} needs a whole number, not '${v#* }'" ;; esac
done
[ "$TRIES" -gt 0 ] || fail "--tries needs at least 1"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the session's job is unknown"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)

job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
sid=$(jq -r '.sessionId // empty' "$job" 2>/dev/null)
[ -n "$sid" ] || fail "no session id in $job, so there is nothing to resume"

# verdict <agents json>: one word for the session's row: `gone`, `others
# <list>` (another live background session in its checkout, copies this run
# made left out), `stopped`, `pid` or `nopid`. Exits non-zero when jq fails.
# Another session is live unless it is stopped, or done with no pid, the
# same rule as launch.sh's.
verdict() {
    printf '%s' "$1" | jq -er --arg id "$ID" --arg d "$DIR" --arg copies "$copies" '
        ($copies | split(" ")) as $mine
        | . as $all
        | ([$all[] | select(.kind == "background" and .id == $id)] | first) as $row
        | if $row == null then "gone"
          else ($row.cwd // $d) as $cwd
               | [$all[] | select(.kind == "background" and .id != $id and .cwd == $cwd
                               and .state != "stopped" and (.state != "done" or .pid != null)
                               and (.id | IN($mine[]) | not))
                  | "\(.id) (\(.state // "unknown"))"] as $others
               | if ($others | length) > 0 then "others \($cwd): \($others | join(", "))"
                 elif $row.state == "stopped" then "stopped"
                 elif $row.pid != null then "pid"
                 else "nopid" end
          end' 2>/dev/null
}

# wait_safe: poll until the session is stopped, or has shown no pid for
# SETTLE seconds (a pid showing again starts that over), or exit 1.
wait_safe() {
    since=""
    begin=$(date +%s)
    while :; do
        list=$(claude agents --json --all </dev/null) ||
            fail "claude agents --json --all failed, so session $ID's state is unknown; not resumed"
        v=$(verdict "$list") ||
            fail "claude agents --json --all printed no list jq could read, so session $ID's state is unknown; not resumed"
        now=$(date +%s)
        case $v in
            gone) fail "session $ID is not in claude agents; not resumed" ;;
            others\ *) fail "another live background session in ${v#others }; not resumed" ;;
            stopped) return 0 ;;
            pid) since="" ;;
            nopid)
                [ -n "$since" ] || since=$now
                [ $((now - since)) -lt "$SETTLE" ] || return 0 ;;
            *) fail "unexpected verdict '$v' on session $ID; not resumed" ;;
        esac
        [ $((now - begin)) -lt "$TIMEOUT" ] ||
            fail "session $ID was not stopped ${TIMEOUT}s after claude stop; not resumed"
        sleep "$INTERVAL"
    done
}

# The stop is repeated before each retry: a copy means the original was
# live again, as when `claude attach` woke it. Its status is not read, since
# stopping a stopped session may fail; the wait is what decides.
copies=""
kept=""
try=0
while [ "$try" -lt "$TRIES" ]; do
    try=$((try + 1))
    claude stop "$ID" </dev/null >/dev/null 2>&1
    wait_safe
    resumed_at=$(date +%s)
    out=$(cd "$DIR" && claude --bg --resume "$sid" "$PROMPT" </dev/null 2>&1)
    copy=$(printf '%s\n' "$out" | sed -n 's/.*started a copy as \([0-9a-f][0-9a-f]*\).*/\1/p' | head -n 1)
    if [ -n "$copy" ]; then
        claude stop "$copy" </dev/null >/dev/null 2>&1
        if claude rm "$copy" </dev/null >/dev/null 2>&1; then
            echo "copy $copy stopped and removed"
        else
            echo "copy $copy stopped, not removed"
            kept="${kept:+$kept }$copy"
        fi
        copies="${copies:+$copies }$copy"
        continue
    fi
    if printf '%s\n' "$out" | grep -Eq "woke session $ID([^0-9a-f]|$)"; then
        # The worker is live again, so its checkout is held read-only again
        # (#76), after the Report step's release.sh cleared the marker.
        # A Distribution repo (#125) is held again too, each marker naming
        # the other repo, as launch.sh writes them.
        dist=$(sh "$(dirname -- "$0")/distribution.sh" --dir "$DIR" </dev/null 2>/dev/null)
        if [ -n "$dist" ]; then
            dist_marker=$(git -C "$dist" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) &&
                printf '%s\nproject %s\n' "$ID" "$DIR" >"$dist_marker" ||
                echo "note the marker for $ID was not written in Distribution repo $dist, so it is not held read-only"
            line="distribution $dist"
        else
            line=""
        fi
        marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) &&
            printf '%s\n%s' "$ID" "${line:+$line
}" >"$marker" ||
            echo "note the marker for $ID was not written in $DIR, so the checkout is not held read-only"
        echo "after $resumed_at"
        echo "resumed $ID"
        exit 0
    fi
    printf 'Error: claude --bg --resume printed neither a wake nor a copy:\n%s\n' "$out" >&2
    exit 1
done
if [ -z "$kept" ]; then
    printf 'Error: every resume of session %s started a copy (%s); each was removed, and %s is left stopped\n' \
        "$ID" "$copies" "$ID" >&2
else
    printf 'Error: every resume of session %s started a copy (%s); %s stopped but not removed, and %s is left stopped\n' \
        "$ID" "$copies" "$kept" "$ID" >&2
fi
exit 2
