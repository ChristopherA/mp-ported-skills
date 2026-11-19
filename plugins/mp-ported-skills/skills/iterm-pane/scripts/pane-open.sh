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

SPLIT_TIMEOUT=10
OSA_TIMEOUT=10

# The split got no answer within SPLIT_TIMEOUT seconds. Its pane, when it
# made one, is the session that was in no window before the split; it is
# looked for in every window, since iTerm2 can hold a new pane in another
# one (#200), and up to LIST_TRIES times, LIST_WAIT seconds apart, since the
# split may still be making it. One such pane is closed; when it cannot be
# closed its coordinates are printed first, as for a pane the command could
# not be typed into, so the caller can close it. Exits 1 in every case: no
# pane is left open for use.
# Usage: unanswered BEFORE_ID...
LIST_TRIES=3 LIST_WAIT=1
unanswered() {
    U_BEFORE=" $* "
    U_WHY="iTerm2 did not answer the split within $SPLIT_TIMEOUT seconds"
    U_TRIES=1
    while :; do
        if ! U_AFTER=$(osascript 2>"$ERR" <<APPLESCRIPT
with timeout of ${OSA_TIMEOUT} seconds
tell application "iTerm2"
    set out to ""
    repeat with w in windows
        set wid to id of w
        repeat with ti from 1 to count of tabs of w
            repeat with s in sessions of (tab ti of w)
                set out to out & (id of s) & " " & wid & " " & ti & linefeed
            end repeat
        end repeat
    end repeat
    return out
end tell
end timeout
APPLESCRIPT
        ); then
            printf "Error: could not open a pane: %s, and its panes could not be listed, so a pane it made may be open: %s\n" \
                "$U_WHY" "$(command cat "$ERR")" >&2
            exit 1
        fi
        U_NEW=$(printf '%s\n' "$U_AFTER" | awk -v before="$U_BEFORE" '
            NF == 3 && $1 ~ /^[A-Za-z0-9:-]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ &&
                index(before, " " $1 " ") == 0 { printf "%s%s", sep, $0; sep = ", " }')
        [ -z "$U_NEW" ] && [ "$U_TRIES" -lt "$LIST_TRIES" ] || break
        U_TRIES=$((U_TRIES + 1))
        sleep "$LIST_WAIT"
    done
    case "$U_NEW" in
        '')
            printf "Error: could not open a pane: %s, and no new pane is open\n" "$U_WHY" >&2 ;;
        *', '*)
            printf "Error: could not open a pane: %s, and more than one pane appeared since the split, so none was closed: %s\n" \
                "$U_WHY" "$U_NEW" >&2 ;;
        *)
            set -- $U_NEW
            SESSION_ID=$1 WINDOW_ID=$2 TAB_NUM=$3
            if osascript -e "with timeout of ${OSA_TIMEOUT} seconds
tell application \"iTerm2\" to tell $(pane_target) to close
end timeout" >/dev/null 2>"$ERR"; then
                printf "Error: could not open a pane: %s, so the pane it made (%s) was closed\n" "$U_WHY" "$SESSION_ID" >&2
            else
                printf "%s\n" "$U_NEW"
                printf "Error: could not open a pane: %s, and the pane it made could not be closed: %s\n" \
                    "$U_WHY" "$(command cat "$ERR")" >&2
            fi ;;
    esac
    exit 1
}

# Find the iTerm2 session on the caller's TTY, split it, and return the new
# session's coordinates. `w` is a reference by place in the window list,
# which the split can reorder, so the window's id is read when the session is
# found: read after the split, it named another window (#200).
#
# The split gives the new pane keyboard focus, so a key the user types before
# the command is typed would land in the new pane ahead of it (#146). The
# caller's pane is selected again in the same script, right after the split.
# A failed select does not fail the open: the pane is already split.
#
# iTerm2 can make the split and never answer it (#273): osascript then waits
# out AppleScript's 120-second default and fails with -1712. So the split
# waits SPLIT_TIMEOUT seconds, and when it gets no answer the script returns
# `unanswered` and the ids of every session open before the split, for
# `unanswered` to find and close the pane it made. Each AppleEvent sent to
# find the caller's pane, list the panes and close one waits OSA_TIMEOUT
# seconds at most. The AppleScript holds no apostrophe: inside $( ), macOS
# /bin/sh (bash 3.2) reads one in a heredoc as an open quote.
ERR=$(mktemp)
trap 'command rm -f "$ERR"' EXIT
if ! RESULT=$(osascript 2>"$ERR" <<APPLESCRIPT
with timeout of ${OSA_TIMEOUT} seconds
tell application "iTerm2"
    set targetTTY to "${CALLER_TTY}"
    set foundSession to missing value
    set foundWindowId to missing value
    set foundTabNum to 1
    set beforeIds to ""
    repeat with w in windows
        repeat with ti from 1 to count of tabs of w
            repeat with s in sessions of (tab ti of w)
                set beforeIds to beforeIds & " " & (id of s)
                if tty of s is targetTTY then
                    set foundSession to s
                    set foundWindowId to id of w
                    set foundTabNum to ti
                end if
            end repeat
        end repeat
    end repeat
    if foundSession is missing value then
        error "No iTerm2 session found for TTY " & targetTTY
    end if
    try
        with timeout of ${SPLIT_TIMEOUT} seconds
            tell foundSession
                set newSession to (split ${DIRECTION}ly ${PROFILE_CLAUSE})
            end tell
        end timeout
    on error errMsg number errNum
        if errNum is not -1712 then error errMsg number errNum
        return "unanswered" & beforeIds
    end try
    try
        tell foundSession to select
    end try
    return (id of newSession) & " " & foundWindowId & " " & foundTabNum
end tell
end timeout
APPLESCRIPT
); then
    printf "Error: could not open a pane: %s\n" "$(command cat "$ERR")" >&2
    exit 1
fi

case $RESULT in
    unanswered|'unanswered '*) unanswered ${RESULT#unanswered} ;;
esac

# Printed before the command is typed, so a caller learns of a split pane
# even when typing into it fails (supervise's view.sh closes it, #200).
printf "%s\n" "$RESULT"

# Right after the split, iTerm2 can refuse the new pane at the coordinates
# the split returned (-1728, "no pane with session") before it lists it there
# (#265), or hold it in another window (#200). So a typing that found no pane
# is tried again, after a short wait and a lookup of the pane by session id,
# up to SEND_TRIES times in all, SEND_WAIT seconds apart. Nothing was typed when no pane was found, so the
# command is never typed twice; any other failure is not retried.
if [ -n "$COMMAND" ]; then
    set -- $RESULT
    SEND_SESSION=$1 SEND_WINDOW=$2 SEND_TAB=$3
    SEND_TRIES=6 SEND_WAIT=0.5
    TRIES=1
    while :; do
        if SEND_ERR=$(sh "$SCRIPT_DIR/pane-send.sh" --session "$SEND_SESSION" --window "$SEND_WINDOW" \
                --tab "$SEND_TAB" --text "$COMMAND" 2>&1); then
            exit 0
        fi
        case $SEND_ERR in
            *'no pane with session'*) [ "$TRIES" -lt "$SEND_TRIES" ] || break ;;
            *) break ;;
        esac
        TRIES=$((TRIES + 1))
        sleep "$SEND_WAIT"
        # pane-find.sh matches part of an id, so only a line for the whole id counts.
        if FOUND=$(sh "$SCRIPT_DIR/pane-find.sh" --session "$SEND_SESSION" </dev/null 2>/dev/null); then
            FOUND=$(printf '%s\n' "$FOUND" | awk -v s="$SEND_SESSION" '$1 == s && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $2, $3; exit }')
            if [ -n "$FOUND" ]; then
                SEND_WINDOW=${FOUND% *} SEND_TAB=${FOUND#* }
            fi
        fi
    done
    printf '%s\n' "${SEND_ERR:-pane-send.sh failed}" >&2
    exit 1
fi
