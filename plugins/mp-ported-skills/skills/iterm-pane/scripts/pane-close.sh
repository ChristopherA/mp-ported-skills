#!/bin/sh
set -eu

# Close an iTerm2 pane.
#
# Safety: without --force it classifies the pane first (pane-classify.sh).
# It closes a pane at a shell, reports a pane already gone (exit 0), and
# refuses one with a Claude Code session working, waiting or asking (exit 2).
# --force closes without looking.
#
# Usage:
#   pane-close.sh --session ID --window ID --tab NUM [--force]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""
FORCE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)  pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)     pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --force)   FORCE=true; shift ;;
        --help)
            printf "Usage: pane-close.sh --session ID --window ID --tab NUM [--force]\n"
            printf "\nWithout --force, closes only a pane at a shell; refuses a Claude Code session.\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

pane_check_coords

if [ "$FORCE" = false ]; then
    if ! STATE=$(sh "$SCRIPT_DIR/pane-classify.sh" --session "$SESSION_ID" --window "$WINDOW_ID" --tab "$TAB_NUM" </dev/null); then
        printf "pane-close.sh: could not read the pane's state, so it stays open\n" >&2
        exit 1
    fi
    case "$STATE" in
        shell) ;;
        gone)
            printf "gone: the pane is already closed\n"
            exit 0 ;;
        *)
            printf "REFUSED: a Claude Code session in the pane is %s. End it, or use --force.\n" "$STATE" >&2
            exit 2 ;;
    esac
fi

pane_osa "tell application \"iTerm2\" to tell $(pane_target) to close"
