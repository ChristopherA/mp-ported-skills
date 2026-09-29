#!/bin/sh
# watch.sh -- watch one background session until it needs the supervisor.
#
# Reads `claude agents --json --all` and finds the background session with
# the given short id. Prints its state on the first line:
#   working            still running (the loop keeps polling)
#   done               its turn ended; the session is still live
#   blocked <what>     waiting on a human: `permission prompt`, `input needed`
#   stopped            stopped, conversation kept
#   gone               not in the list: removed, or never started
#   unknown <state>    a state this script does not know
# then `cwd <path>` (where the session runs), and for a blocked session
# `needs <text>` when its job's state.json under $CLAUDE_CONFIG_DIR names it.
#
# The state comes from `state`, not `status`: a session just launched shows
# `status: idle` while its `state` is `working`.
#
# Usage:
#   watch.sh --id ID [--interval SECONDS] [--timeout SECONDS]
#       poll until a state other than working; on timeout print the last
#       one and exit 124
#   watch.sh --id ID --file PATH
#       classify one saved `claude agents --json --all` output
#
# Exits 1 when the list cannot be read, which is never reported as gone.

set -u

ID=""
FILE=""
INTERVAL=30
TIMEOUT=14400

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --file)     need_value "$@"; FILE="$2"; shift 2 ;;
        --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --help)
            printf 'Usage: watch.sh --id ID [--interval S] [--timeout S] | watch.sh --id ID --file PATH\n'
            printf 'Prints: working, done, blocked <what>, stopped, gone or unknown <state>; then cwd and needs lines.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
case $INTERVAL in '' | *[!0-9]*) fail "--interval needs whole seconds, not '$INTERVAL'" ;; esac
case $TIMEOUT in '' | *[!0-9]*) fail "--timeout needs whole seconds, not '$TIMEOUT'" ;; esac
# claude agents and the job's state.json both follow the config dir, so an
# unset one would read another profile's sessions.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the profile being watched is unknown"

# classify <agents json>: the report lines for $ID, or exit 1 when the input
# is not a JSON array.
classify() {
    printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    printf '%s' "$1" | jq -r --arg id "$ID" '
        [.[] | select(.kind == "background" and .id == $id)] | first
        | if . == null then "gone"
          else (if .state == "working" or .state == "done" or .state == "stopped" then .state
                elif .state == "blocked" then "blocked \(.waitingFor // "unknown")"
                else "unknown \(.state // "none")" end),
               (.cwd // empty | "cwd \(.)")
          end'
}

# report <agents json>: classify, adding the job's needs to a blocked state.
report() {
    out=$(classify "$1") || return 1
    printf '%s\n' "$out"
    case $out in
        blocked*)
            job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
            if [ -f "$job" ]; then
                needs=$(jq -r '.needs // empty' "$job" 2>/dev/null)
                [ -z "$needs" ] || printf 'needs %s\n' "$needs"
            fi ;;
    esac
}

if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || { printf 'Error: no such file: %s\n' "$FILE" >&2; exit 1; }
    report "$(command cat "$FILE")" || { printf 'Error: not a JSON array: %s\n' "$FILE" >&2; exit 1; }
    exit 0
fi

start=$(date +%s)
while :; do
    if ! list=$(claude agents --json --all </dev/null); then
        printf 'Error: claude agents --json --all failed\n' >&2
        exit 1
    fi
    out=$(report "$list") || { printf 'Error: claude agents --json --all printed no JSON array\n' >&2; exit 1; }
    case $out in
        working*) ;;
        *) printf '%s\n' "$out"; exit 0 ;;
    esac
    if [ $(($(date +%s) - start)) -ge "$TIMEOUT" ]; then
        printf '%s\n' "$out"
        exit 124
    fi
    sleep "$INTERVAL"
done
