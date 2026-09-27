#!/bin/sh
set -eu

# Close an iTerm2 pane.
#
# Safety: without --force this refuses every close (exit 2), because nothing
# here can yet tell whether a Claude Code session in the pane is busy. Read
# the pane first, then pass --force.
#
# Usage:
#   pane-close.sh --session ID --window ID --tab NUM --force

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
            printf "\nRefuses to close without --force: check the pane first.\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

pane_check_coords

if [ "$FORCE" = false ]; then
    printf "REFUSED: pane-close.sh cannot yet tell whether a session in the pane is busy. Check the pane, then use --force.\n" >&2
    exit 2
fi

pane_osa "tell application \"iTerm2\" to tell $(pane_target) to close"
