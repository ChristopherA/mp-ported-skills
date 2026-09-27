#!/bin/sh
set -eu

# Open an iTerm2 split pane beside the caller's pane.
# Outputs: SESSION_ID WINDOW_ID TAB_NUM
#
# Usage:
#   pane-open.sh [--direction vertical|horizontal] [--command "cmd"] [--profile "Name"]
#
# --direction names the divider: vertical (the default) puts the new pane to
# the right, horizontal puts it below.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

DIRECTION="vertical"
COMMAND=""
PROFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --direction) pane_need_value "$@"; DIRECTION="$2"; shift 2 ;;
        --command)   pane_need_value "$@"; COMMAND="$2"; shift 2 ;;
        --profile)   pane_need_value "$@"; PROFILE="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-open.sh [--direction vertical|horizontal] [--command cmd] [--profile Name]\n"
            printf "Opens an iTerm2 split pane. Outputs: SESSION_ID WINDOW_ID TAB_NUM\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

case "$DIRECTION" in
    vertical|horizontal) ;;
    *) printf "Invalid direction: %s (use vertical or horizontal)\n" "$DIRECTION" >&2; exit 1 ;;
esac

# The caller's pane is the one on the first TTY up the process tree, so the
# split lands in the right window whichever one is frontmost.
CALLER_TTY=""
WALK_PID=$$
while [ -n "$WALK_PID" ] && [ "$WALK_PID" != "0" ] && [ "$WALK_PID" != "1" ]; do
    CANDIDATE=$(ps -o tty= -p "$WALK_PID" 2>/dev/null | tr -d ' ')
    if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "??" ]; then
        CALLER_TTY="/dev/$CANDIDATE"
        break
    fi
    WALK_PID=$(ps -o ppid= -p "$WALK_PID" 2>/dev/null | tr -d ' ')
done

if [ -z "$CALLER_TTY" ]; then
    printf "Error: could not determine calling TTY\n" >&2
    exit 1
fi

if [ -n "$PROFILE" ]; then
    PROFILE_CLAUSE="with profile $(pane_quote "$PROFILE")"
else
    PROFILE_CLAUSE="with default profile"
fi

# Find the iTerm2 session on the caller's TTY, split it, and return the new
# session's coordinates.
ERR=$(mktemp)
trap 'command rm -f "$ERR"' EXIT
if ! RESULT=$(osascript 2>"$ERR" <<APPLESCRIPT
tell application "iTerm2"
    set targetTTY to "${CALLER_TTY}"
    set foundSession to missing value
    set foundWindow to missing value
    set foundTabNum to 1
    repeat with w in windows
        repeat with ti from 1 to count of tabs of w
            repeat with s in sessions of (tab ti of w)
                if tty of s is targetTTY then
                    set foundSession to s
                    set foundWindow to w
                    set foundTabNum to ti
                end if
            end repeat
        end repeat
    end repeat
    if foundSession is missing value then
        error "No iTerm2 session found for TTY " & targetTTY
    end if
    tell foundSession
        set newSession to (split ${DIRECTION}ly ${PROFILE_CLAUSE})
    end tell
    return (id of newSession) & " " & (id of foundWindow) & " " & foundTabNum
end tell
APPLESCRIPT
); then
    printf "Error: could not open a pane: %s\n" "$(command cat "$ERR")" >&2
    exit 1
fi

printf "%s\n" "$RESULT"

if [ -n "$COMMAND" ]; then
    set -- $RESULT
    sh "$SCRIPT_DIR/pane-send.sh" --session "$1" --window "$2" --tab "$3" --text "$COMMAND"
fi
