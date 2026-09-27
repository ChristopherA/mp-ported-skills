# pane-common.sh -- sourced by the pane scripts that target one pane.
#
# The caller sets SESSION_ID, WINDOW_ID and TAB_NUM from its flags, then
# calls pane_check_coords once and pane_osa for each AppleScript command.

PANE_SCRIPT=$(basename "$0")

# Call as `pane_need_value "$@"` before taking a flag's value from $2.
pane_need_value() {
    if [ $# -lt 2 ]; then
        printf "Error: %s needs a value\n" "$1" >&2
        exit 1
    fi
}

# Exit 1 unless all three coordinates are set and well formed. The values
# are spliced into AppleScript, so only ids iTerm2 itself hands out pass.
pane_check_coords() {
    if [ -z "$SESSION_ID" ] || [ -z "$WINDOW_ID" ] || [ -z "$TAB_NUM" ]; then
        printf "Error: --session, --window, and --tab are required\n" >&2
        exit 1
    fi
    case "$SESSION_ID" in
        *[!A-Za-z0-9:-]*) printf "Error: invalid --session: %s\n" "$SESSION_ID" >&2; exit 1 ;;
    esac
    case "$WINDOW_ID" in
        *[!0-9]*) printf "Error: invalid --window: %s\n" "$WINDOW_ID" >&2; exit 1 ;;
    esac
    case "$TAB_NUM" in
        *[!0-9]*) printf "Error: invalid --tab: %s\n" "$TAB_NUM" >&2; exit 1 ;;
    esac
}

# An AppleScript string literal: backslashes and double quotes escaped.
pane_quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

pane_target() {
    printf 'session id "%s" of tab %s of window id %s' "$SESSION_ID" "$TAB_NUM" "$WINDOW_ID"
}

# Run one AppleScript command against iTerm2 and print its result. When the
# pane does not exist (AppleScript error -1728), say so plainly and exit 1;
# any other failure passes osascript's own message through.
pane_osa() {
    _err=$(mktemp)
    if _out=$(osascript -e "$1" 2>"$_err"); then
        command rm -f "$_err"
        [ -z "$_out" ] || printf '%s\n' "$_out"
        return 0
    fi
    if grep -q -- '-1728' "$_err"; then
        printf "%s: no pane with session %s in tab %s of window %s (closed, or wrong coordinates)\n" \
            "$PANE_SCRIPT" "$SESSION_ID" "$TAB_NUM" "$WINDOW_ID" >&2
    else
        printf "%s: " "$PANE_SCRIPT" >&2; command cat "$_err" >&2
    fi
    command rm -f "$_err"
    exit 1
}
