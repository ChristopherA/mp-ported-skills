#!/bin/sh
set -eu

# Open an iTerm2 split pane, change into a directory and start claude there.
# Outputs: SESSION_ID WINDOW_ID TAB_NUM
#
# Usage:
#   pane-launch.sh --dir PATH [--permission-mode MODE] [--message TEXT]
#                  [--direction vertical|horizontal]
#
# --message is the session's first message. The line is typed into the
# pane's interactive shell, so every value is single-quoted there: history
# expansion, $, backticks and double quotes do not act inside single quotes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

DIR=""
MODE=""
MESSAGE=""
DIRECTION="vertical"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)             pane_need_value "$@"; DIR="$2"; shift 2 ;;
        --permission-mode) pane_need_value "$@"; MODE="$2"; shift 2 ;;
        --message)         pane_need_value "$@"; MESSAGE="$2"; shift 2 ;;
        --direction)       pane_need_value "$@"; DIRECTION="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-launch.sh --dir PATH [--permission-mode MODE] [--message TEXT] [--direction vertical|horizontal]\n"
            printf "Opens an iTerm2 split pane and starts claude in PATH. Outputs: SESSION_ID WINDOW_ID TAB_NUM\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

if [ -z "$DIR" ]; then
    printf "Error: --dir is required\n" >&2
    exit 1
fi
if [ ! -d "$DIR" ]; then
    printf "Error: not a directory: %s\n" "$DIR" >&2
    exit 1
fi
# The new pane's shell starts in its own directory, so a relative path
# would resolve against the wrong one.
DIR=$(cd "$DIR" && pwd)

# A shell string literal: single quotes, each ' inside closed, escaped and
# reopened.
sh_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

LINE="cd $(sh_quote "$DIR") && claude"
[ -z "$MODE" ] || LINE="$LINE --permission-mode $(sh_quote "$MODE")"
[ -z "$MESSAGE" ] || LINE="$LINE $(sh_quote "$MESSAGE")"

exec sh "$SCRIPT_DIR/pane-open.sh" --direction "$DIRECTION" --command "$LINE"
