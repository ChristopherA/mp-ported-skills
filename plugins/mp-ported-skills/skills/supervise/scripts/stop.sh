#!/bin/sh
# stop.sh -- stop the supervisor's own finished worker and release its
# marker, in one command (#132).
#
# A bare `claude stop <id>` from the supervisor was refused by the auto-mode
# classifier, which read it as interfering with a running job, and so left
# the checkout read-only and the run unrecorded. This names the job as the
# worker this profile launched into DIR, and checks that before it stops
# anything: the job is in $CLAUDE_CONFIG_DIR/jobs, and DIR's marker names it
# or is gone.
#
# Then it runs `claude stop` and waits, with resume.sh's rule, for the first
# of:
#   - `claude agents --json --all` shows the session `stopped`, or no
#     longer lists it;
#   - its row has shown no pid for SETTLE seconds. `stopped` may never show
#     (#77), and a pid can show again; a pid showing starts the settle time
#     over. The worker's cost row is written at the stop, and a record read
#     right after a stop has missed it, so the wait is not cut short.
# Then it releases DIR's marker with release.sh.
#
# Prints `stopped ID` (or `gone ID` when the list no longer holds it), then
# `released ID` or `no marker in DIR`. When the worker was not seen to stop,
# or the marker was not released, it says so, with the marker's state and
# the command that finishes the run (`finish with: ...`).
#
# Usage:
#   stop.sh --dir DIR --id ID [--settle S] [--interval S] [--timeout S]
#
# DIR is the Project folder the worker was launched into, which holds the
# marker, even when the worker has moved elsewhere. SETTLE defaults to 60,
# INTERVAL (between reads of the list) to 5, TIMEOUT to 300.
#
# Exits 0 stopped and released (or no marker); 1 not stopped (nothing
# stopped when a check failed first) or not released.

set -u

ID=""
DIR=""
SETTLE=60
INTERVAL=5
TIMEOUT=300

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --settle)   need_value "$@"; SETTLE="$2"; shift 2 ;;
        --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --help)
            printf 'Usage: stop.sh --dir DIR --id ID [--settle S] [--interval S] [--timeout S]\n'
            printf 'Stops the worker this profile launched into DIR and releases its marker. Outputs: stopped ID (or gone ID), then released ID or no marker in DIR\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
for v in "settle $SETTLE" "interval $INTERVAL" "timeout $TIMEOUT"; do
    case ${v#* } in '' | *[!0-9]*) fail "--${v%% *} needs a whole number, not '${v#* }'" ;; esac
done
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the worker's job is unknown; not stopped"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

[ -f "$CLAUDE_CONFIG_DIR/jobs/$ID/state.json" ] ||
    fail "no job $ID in $CLAUDE_CONFIG_DIR/jobs, so it is not a worker this profile launched; not stopped"
marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) ||
    fail "$DIR is not a git checkout; not stopped"
if [ -f "$marker" ]; then
    held=$(head -n 1 "$marker")
    [ "$held" = "$ID" ] || fail "the marker in $DIR names worker $held, not $ID; not stopped"
fi

# unfinished <script>: the run is not finished. Say so, with the marker's
# state and the one command that finishes it, through stop.sh or release.sh.
unfinished() {
    if [ -f "$marker" ]; then
        printf 'marker kept: %s is still read-only for commits, held by %s\n' "$DIR" "$ID" >&2
    else
        printf 'no marker in %s\n' "$DIR" >&2
    fi
    printf 'finish with: sh "%s/%s" --dir "%s" --id %s\n' "$here" "$1" "$DIR" "$ID" >&2
    exit 1
}
unstopped() { printf 'Error: %s\n' "$1" >&2; unfinished stop.sh; }

# The stop's own status is not read, since stopping a stopped session may
# fail; the wait is what decides.
claude stop "$ID" </dev/null >/dev/null 2>&1
begin=$(date +%s)
since=""
while :; do
    list=$(claude agents --json --all </dev/null) ||
        unstopped "claude agents --json --all failed, so session $ID's state is unknown"
    v=$(printf '%s' "$list" | jq -er --arg id "$ID" '
        ([.[] | select(.kind == "background" and .id == $id)] | first) as $row
        | if $row == null then "gone"
          elif $row.state == "stopped" then "stopped"
          elif $row.pid == null then "nopid"
          else "pid" end' 2>/dev/null) ||
        unstopped "claude agents --json --all printed no list jq could read, so session $ID's state is unknown"
    now=$(date +%s)
    case $v in
        gone | stopped) break ;;
        pid) since="" ;;
        nopid)
            [ -n "$since" ] || since=$now
            [ $((now - since)) -lt "$SETTLE" ] || { v=stopped; break; } ;;
    esac
    [ $((now - begin)) -lt "$TIMEOUT" ] ||
        unstopped "session $ID was not stopped ${TIMEOUT}s after claude stop"
    sleep "$INTERVAL"
done
echo "$v $ID"
sh "$here/release.sh" --dir "$DIR" --id "$ID" || unfinished release.sh
