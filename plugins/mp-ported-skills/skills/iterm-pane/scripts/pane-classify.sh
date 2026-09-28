#!/bin/sh
set -eu

# Classify what a pane's session is doing. Prints exactly one of:
#   working  Claude Code is thinking or streaming a reply
#   waiting  Claude Code is idle at its input prompt
#   asking   a question, permission or trust prompt is open
#   shell    no Claude Code prompt at the bottom: a shell, or another program
#   gone     the pane no longer exists
#
# It reads the bottom of the screen and never the model name, so a session
# on any model classifies the same way.
#
# Usage:
#   pane-classify.sh --session ID --window ID --tab NUM
#   pane-classify.sh --file PATH      # a saved pane-read.sh capture; - for stdin

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""
FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)  pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)     pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --file)    pane_need_value "$@"; FILE="$2"; shift 2 ;;
        --help)
            printf "Usage: pane-classify.sh --session ID --window ID --tab NUM\n"
            printf "       pane-classify.sh --file PATH   (- for stdin)\n"
            printf "\nPrints one of: working, waiting, asking, shell, gone.\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

# The classifier. A Claude Code prompt box is a rule line (ending in a
# box-drawing dash) with a line starting "❯" under it. iTerm2's contents keep
# stale redraws of that box above the live one, so only the last box counts,
# and only when nothing but its footer lines follows it.
classify() {
    awk '
    function is_rule_end(s) { sub(/[ \t]+$/, "", s); return s ~ /─$/ }
    function is_pure_rule(s) { gsub(/[ \t]/, "", s); if (s == "") return 0; gsub(/─/, "", s); return s == "" }
    BEGIN { nbsp = "\302\240" }
    # Claude Code puts a no-break space after "❯"; read it as a space.
    { gsub(nbsp, " "); line[NR] = $0 }
    END {
        n = NR
        # gone: the capture is pane-read.sh saying the pane does not exist.
        text = 0; lone = ""
        for (i = 1; i <= n; i++) if (line[i] ~ /[^ \t]/) { text++; lone = line[i] }
        if (text == 1 && lone ~ /: no pane with session .*\(closed, or wrong coordinates\)$/) { print "gone"; exit }

        p = 0
        for (i = n; i > 1; i--) if (line[i] ~ /^❯/ && is_rule_end(line[i - 1])) { p = i; break }

        # asking: a dialog below the last prompt box, or with none at all.
        for (i = p + 1; i <= n; i++) if (line[i] ~ /Esc to cancel/) { print "asking"; exit }
        if (p == 0) { print "shell"; exit }

        # The box is live only when its bottom rule is followed by nothing
        # but a few indented footer lines (mode, status line).
        b = 0
        for (i = p + 1; i <= n; i++) if (is_pure_rule(line[i])) { b = i; break }
        if (b == 0 || n - b > 6) { print "shell"; exit }
        for (i = b + 1; i <= n; i++) if (line[i] != "" && line[i] !~ /^ /) { print "shell"; exit }

        # The anchor: the last user message or startup banner above the box.
        kind = "none"; a = 0
        for (i = p - 2; i >= 1; i--) {
            if (line[i] ~ /▐▛███▛█/) { kind = "banner"; a = i; break }
            if (line[i] ~ /^❯ / && line[i] !~ /^❯ Try "/ && line[i] ~ /^❯ [^ ]/) {
                kind = (line[i] ~ /^❯ \//) ? "command" : "message"; a = i; break
            }
        }
        # After the anchor, the latest spinner ("✢ Sprouting…") or done line
        # ("✻ Worked for 42s · done") decides. A message with neither under
        # it is a reply still streaming: no spinner shows while text streams.
        seen = ""
        for (i = a + 1; i < p - 1; i++) {
            if (line[i] ~ /^(✢|✳|✶|✻|✽|·|\*) [A-Z][a-z]+…/) seen = "working"
            else if (line[i] ~ /^(✢|✳|✶|✻|✽|·|\*) [A-Z][a-z]+ for [0-9]/) seen = "waiting"
        }
        if (seen != "") { print seen; exit }
        print (kind == "message") ? "working" : "waiting"
    }'
}

if [ -n "$FILE" ]; then
    if [ -n "$SESSION_ID$WINDOW_ID$TAB_NUM" ]; then
        printf "Error: give --file or the pane coordinates, not both\n" >&2
        exit 1
    fi
    if [ "$FILE" = - ]; then
        classify
    elif [ -f "$FILE" ]; then
        classify < "$FILE"
    else
        printf "Error: no such file: %s\n" "$FILE" >&2
        exit 1
    fi
    exit 0
fi

pane_check_coords
_err=$(mktemp)
if CONTENTS=$(sh "$SCRIPT_DIR/pane-read.sh" --session "$SESSION_ID" --window "$WINDOW_ID" --tab "$TAB_NUM" </dev/null 2>"$_err"); then
    command rm -f "$_err"
    printf '%s\n' "$CONTENTS" | classify
    exit 0
fi
if grep -q 'no pane with session' "$_err"; then
    command rm -f "$_err"
    printf 'gone\n'
    exit 0
fi
command cat "$_err" >&2
command rm -f "$_err"
exit 1
