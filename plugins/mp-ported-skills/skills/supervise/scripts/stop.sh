#!/bin/sh
# stop.sh -- stop the supervisor's own finished worker and release its
# marker, in one command (#132).
#
# A bare `claude stop <id>` from the supervisor was refused by the auto-mode
# classifier as interfering with a workload (#132), which left the checkout
# read-only and the run unrecorded. This names the job as the worker this
# profile launched into DIR, and checks that before it stops anything: the
# job is in $CLAUDE_CONFIG_DIR/jobs, and DIR's marker names it or is gone.
#
# Then it runs `claude stop`, and waits until `claude agents --json --all`
# shows the session `stopped`, with no pid, or not at all. `stopped` may
# never show (#77), but no pid means the process is gone, and the worker's
# cost row is written by then. Then it releases DIR's marker, as release.sh
# does.
#
# Prints `stopped ID` (or `gone ID` when the list no longer holds it), then
# `released ID` or `no marker in DIR`. When the worker was not seen to stop,
# it says so with the marker kept and the command that finishes the run.
#
# Usage:
#   stop.sh --dir DIR --id ID [--interval S] [--timeout S]
#
# INTERVAL (between reads of the list) defaults to 5, TIMEOUT to 120.
#
# Exits 0 stopped and released (or no marker); 1 not stopped or not
# released, the marker left as it was.

set -u

ID=""
DIR=""
INTERVAL=5
TIMEOUT=120

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --help)
            printf 'Usage: stop.sh --dir DIR --id ID [--interval S] [--timeout S]\n'
            printf 'Stops the worker this profile launched into DIR and releases its marker. Outputs: stopped ID (or gone ID), then released ID or no marker in DIR\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
for v in "interval $INTERVAL" "timeout $TIMEOUT"; do
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

# unstopped <why>: the worker was not seen to stop. Say so, with the
# marker's state and the one command that finishes the run.
unstopped() {
    printf 'Error: %s\n' "$1" >&2
    if [ -f "$marker" ]; then
        printf 'marker kept: %s is still read-only for commits, held by %s\n' "$DIR" "$ID" >&2
    else
        printf 'no marker in %s\n' "$DIR" >&2
    fi
    printf 'finish with: sh "%s/stop.sh" --dir "%s" --id %s\n' "$here" "$DIR" "$ID" >&2
    exit 1
}

# The stop's own status is not read, since stopping a stopped session may
# fail; the wait is what decides.
claude stop "$ID" </dev/null >/dev/null 2>&1
begin=$(date +%s)
while :; do
    list=$(claude agents --json --all </dev/null) ||
        unstopped "claude agents --json --all failed, so session $ID's state is unknown"
    v=$(printf '%s' "$list" | jq -er --arg id "$ID" '
        ([.[] | select(.kind == "background" and .id == $id)] | first) as $row
        | if $row == null then "gone"
          elif $row.state == "stopped" or $row.pid == null then "stopped"
          else "live" end' 2>/dev/null) ||
        unstopped "claude agents --json --all printed no list jq could read, so session $ID's state is unknown"
    [ "$v" = live ] || break
    [ $(($(date +%s) - begin)) -lt "$TIMEOUT" ] ||
        unstopped "session $ID was not stopped ${TIMEOUT}s after claude stop"
    sleep "$INTERVAL"
done
echo "$v $ID"
exec sh "$here/release.sh" --dir "$DIR" --id "$ID"
