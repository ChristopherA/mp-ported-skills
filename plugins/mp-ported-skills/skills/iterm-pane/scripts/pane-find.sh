#!/bin/sh
set -eu

# Recover iTerm2 pane coordinates from a session id (partial or full).
# Outputs: SESSION_ID WINDOW_ID TAB_NUM, or, when several sessions match,
# one line each with the session name appended.
#
# Usage:
#   pane-find.sh --session <partial-or-full-id>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_PARTIAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_PARTIAL="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-find.sh --session <partial-or-full-id>\n"
            printf "Recovers iTerm2 pane coordinates by matching a session id substring.\n"
            printf "Outputs: SESSION_ID WINDOW_ID TAB_NUM\n"
            printf "When several match: one line per match with the session name appended.\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

if [ -z "$SESSION_PARTIAL" ]; then
    printf "Error: --session is required\n" >&2
    exit 1
fi

# Every session in every window and tab, one line each.
RAW=$(osascript <<'APPLESCRIPT'
tell application "iTerm2"
    set output to ""
    repeat with i from 1 to (count of windows)
        set w to window i
        set wid to id of w
        repeat with j from 1 to (count of tabs of w)
            set t to tab j of w
            repeat with s in sessions of t
                set sid to id of s
                set sname to name of s
                set output to output & "W:" & wid & " T:" & j & " S:" & sid & " Name:" & sname & linefeed
            end repeat
        end repeat
    end repeat
    return output
end tell
APPLESCRIPT
)

if [ -z "$RAW" ]; then
    printf "Error: no iTerm2 sessions found (is iTerm2 running?)\n" >&2
    exit 1
fi

# Keep the lines whose S: field contains the partial id.
MATCHES=$(printf "%s\n" "$RAW" | awk -v pat="$SESSION_PARTIAL" '
    /S:/ {
        match($0, /S:[^ ]+/)
        sid = substr($0, RSTART+2, RLENGTH-2)
        if (index(sid, pat) > 0) print $0
    }
')

if [ -z "$MATCHES" ]; then
    printf "Error: no session found matching '%s'\n" "$SESSION_PARTIAL" >&2
    printf "Hint: pass a substring of the session id pane-open.sh printed\n" >&2
    exit 1
fi

COUNT=$(printf "%s\n" "$MATCHES" | wc -l | tr -d ' ')

if [ "$COUNT" -gt 1 ]; then
    printf "Multiple sessions match '%s':\n" "$SESSION_PARTIAL" >&2
fi
# Fields by position, since a session name may itself contain "T:" or "S:".
printf "%s\n" "$MATCHES" | awk -v many="$([ "$COUNT" -gt 1 ] && echo 1 || echo 0)" '{
    wid = substr($1, 3); tnum = substr($2, 3); sid = substr($3, 3)
    if (many) {
        name = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ Name:/, "", name)
        print sid, wid, tnum, name
    } else {
        print sid, wid, tnum
    }
}'
