#!/bin/sh
# session-tag.sh -- sourced helper: session_tag <config dir> prints the tag a
# session title and a worker's name put after the repo, as `<repo> (<tag>)`.
#
# The tag is the first line of <config dir>/session-tag, spaces around it
# trimmed, when that line is not empty. Otherwise it is the config folder's
# name without its `.claude-` prefix, as the status line names the profile,
# and `default` for ~/.claude itself. Used by session-title.sh and supervise's
# launch.sh, so a session and the workers it launches carry the same tag.

session_tag() { # <config dir>
    session_tag_line=""
    if [ -f "$1/session-tag" ]; then
        session_tag_line=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$1/session-tag" 2>/dev/null) \
            || session_tag_line=""
    fi
    if [ -n "$session_tag_line" ]; then
        printf '%s\n' "$session_tag_line"
        return 0
    fi
    session_tag_line=$(basename "$1")
    session_tag_line=${session_tag_line#.claude-}
    [ "$session_tag_line" = ".claude" ] && session_tag_line=default
    printf '%s\n' "$session_tag_line"
}
