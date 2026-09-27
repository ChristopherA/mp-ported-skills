#!/bin/sh
set -eu

# Resolve the TTY for an iTerm2 session by its unique ID.
#
# Usage:
#   pane-tty.sh SESSION_ID
#
# Outputs: the TTY path (e.g., /dev/ttys042), or nothing when no session has
# that id or iTerm2 cannot be asked. Exit 0 either way; the caller handles
# empty output.

if [ $# -lt 1 ] || [ -z "$1" ]; then
    printf "Usage: pane-tty.sh SESSION_ID\n" >&2
    exit 1
fi

SESSION_ID="$1"

# The id is spliced into AppleScript, so only ids iTerm2 hands out pass.
case "$SESSION_ID" in
    *[!A-Za-z0-9:-]*) printf "Error: invalid session id: %s\n" "$SESSION_ID" >&2; exit 1 ;;
esac

if [ "$(uname)" != "Darwin" ] || ! command -v osascript >/dev/null 2>&1; then
    exit 0
fi

TTY=$(osascript 2>/dev/null <<APPLE
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if unique ID of s is "${SESSION_ID}" then
                    return tty of s
                end if
            end repeat
        end repeat
    end repeat
    return ""
end tell
APPLE
) || TTY=""

printf '%s' "$TTY"
