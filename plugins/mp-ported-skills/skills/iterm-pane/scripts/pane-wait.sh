#!/bin/sh
set -eu

# Wait until a pane's session reaches one of the given states.
#
# Polls pane-classify.sh, never the pane's text, so an echoed command cannot
# satisfy the wait. Prints the state reached and exits 0; on timeout prints
# the last state seen and exits 124.
#
# Usage:
#   pane-wait.sh --session ID --window ID --tab NUM --state waiting,asking \
#       [--timeout SECONDS] [--interval SECONDS]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""
STATES=""
TIMEOUT=300
INTERVAL=2

while [ $# -gt 0 ]; do
    case "$1" in
        --session)  pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)   pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)      pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --state)    pane_need_value "$@"; STATES="$2"; shift 2 ;;
        --timeout)  pane_need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --interval) pane_need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-wait.sh --session ID --window ID --tab NUM --state S[,S...] [--timeout SECONDS] [--interval SECONDS]\n"
            printf "\nStates: working, waiting, asking, shell, gone. Defaults: --timeout 300, --interval 2.\n"
            printf "Prints the state reached (exit 0), or the last state seen on timeout (exit 124).\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

pane_check_coords
if [ -z "$STATES" ]; then
    printf "Error: --state is required\n" >&2
    exit 1
fi
for s in $(printf '%s' "$STATES" | tr ',' ' '); do
    case "$s" in
        working|waiting|asking|shell|gone) ;;
        *) printf "Error: unknown state: %s (use working, waiting, asking, shell, gone)\n" "$s" >&2; exit 1 ;;
    esac
done
case "$TIMEOUT" in
    ''|*[!0-9]*) printf "Error: invalid --timeout: %s\n" "$TIMEOUT" >&2; exit 1 ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*|0) printf "Error: invalid --interval: %s\n" "$INTERVAL" >&2; exit 1 ;;
esac

last=""
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
    if ! state=$(sh "$SCRIPT_DIR/pane-classify.sh" --session "$SESSION_ID" --window "$WINDOW_ID" --tab "$TAB_NUM" </dev/null); then
        printf "pane-wait.sh: could not read the pane's state; last state: %s\n" "${last:-none}" >&2
        exit 1
    fi
    last=$state
    case ",$STATES," in
        *",$state,"*) printf '%s\n' "$state"; exit 0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '%s\n' "$state"
        printf "pane-wait.sh: timed out after %ss waiting for %s; last state: %s\n" "$TIMEOUT" "$STATES" "$state" >&2
        exit 124
    fi
    sleep "$INTERVAL"
done
