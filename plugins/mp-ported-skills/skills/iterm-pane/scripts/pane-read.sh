#!/bin/sh
set -eu

# Read contents from an iTerm2 pane.
#
# Usage:
#   pane-read.sh --session ID --window ID --tab NUM [--lines N]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""
LINES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)  pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)     pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --lines)   pane_need_value "$@"; LINES="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-read.sh --session ID --window ID --tab NUM [--lines N]\n"
            printf "Reads pane contents. Use --lines N to get only the last N lines.\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

pane_check_coords
case "$LINES" in
    ''|*[!0-9]*) printf "Error: invalid --lines: %s\n" "$LINES" >&2; exit 1 ;;
esac

CONTENTS=$(pane_osa "tell application \"iTerm2\" to tell $(pane_target) to get contents")

# Strip trailing blank lines: the terminal buffer pads with empty lines.
TRIMMED=$(printf "%s" "$CONTENTS" | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }')

if [ "$LINES" -gt 0 ]; then
    printf "%s\n" "$TRIMMED" | tail -n "$LINES"
else
    printf "%s\n" "$TRIMMED"
fi
