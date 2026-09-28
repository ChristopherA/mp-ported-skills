#!/bin/sh
set -eu

# Send a slash command to a Claude Code pane and submit it.
#
# Types "/name args" through pane-send.sh, then sends Return as a separate
# key: Claude Code can hold pasted text without submitting it. A leading /
# on the name is optional and never doubled. The arguments are joined with
# spaces and sent as written.
#
# Usage:
#   pane-slash.sh --session ID --window ID --tab NUM [--] NAME [ARGS...]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)  pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)     pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-slash.sh --session ID --window ID --tab NUM [--] NAME [ARGS...]\n"
            exit 0 ;;
        --) shift; break ;;
        -*) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
        *) break ;;
    esac
done

pane_check_coords

NAME=${1:-}
NAME=${NAME#/}
case "$NAME" in
    ''|' '*|'	'*) printf "Error: a command name is required\n" >&2; exit 1 ;;
esac
shift
TEXT="/$NAME${1+ $*}"

set -- --session "$SESSION_ID" --window "$WINDOW_ID" --tab "$TAB_NUM"
sh "$SCRIPT_DIR/pane-send.sh" "$@" --text "$TEXT" </dev/null
sh "$SCRIPT_DIR/pane-send.sh" "$@" --key return </dev/null
