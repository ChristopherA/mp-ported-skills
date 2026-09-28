#!/bin/sh
set -eu

# Classify what a pane's session is doing. Prints exactly one of:
#   working  Claude Code is thinking or streaming a reply, or a program other
#            than Claude Code is running (no shell prompt is last)
#   waiting  Claude Code is idle at its input prompt
#   asking   a question, permission or trust prompt is open
#   shell    Claude Code is not running and a shell prompt is last
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
# and only while no shell prompt has appeared below it.
classify() {
    awk '
    function is_rule_end(s) { sub(/[ \t]+$/, "", s); return s ~ /─$/ }
    function is_pure_rule(s) { gsub(/[ \t]/, "", s); if (s == "") return 0; gsub(/─/, "", s); return s == "" }
    # A shell prompt: an unindented line ending in a prompt character. The
    # footer lines under a Claude Code box are indented, so never match.
    function is_shell_prompt(s) { return s ~ /^❯ ?$/ || s ~ /^[^ \t].*(%|\$|#|>|❯) ?$/ }
    BEGIN { nbsp = "\302\240" }
    # Claude Code puts a no-break space after "❯"; read it as a space.
    { gsub(nbsp, " "); line[NR] = $0 }
    END {
        n = NR
        text = 0; last = 0
        for (i = 1; i <= n; i++) if (line[i] ~ /[^ \t]/) { text++; last = i }
        # gone: the capture is pane-read.sh saying the pane does not exist.
        if (text == 1 && line[last] ~ /: no pane with session .*\(closed, or wrong coordinates\)$/) { print "gone"; exit }

        prompt_at = 0
        for (i = n; i > 1; i--) if (line[i] ~ /^❯/ && is_rule_end(line[i - 1])) { prompt_at = i; break }

        # asking: a dialog below the last prompt box, or with none at all.
        for (i = prompt_at + 1; i <= n; i++) if (line[i] ~ /Esc to cancel/) { print "asking"; exit }

        # With no box, or a shell prompt below the box, Claude Code is not
        # running there. A pane with no prompt last runs some other program,
        # which counts as working, so a safe close leaves it alone.
        border_at = 0
        for (i = prompt_at + 1; i <= n; i++) if (is_pure_rule(line[i])) { border_at = i; break }
        if (prompt_at == 0 || border_at == 0 || last > border_at && line[last] !~ /^[ \t]/) {
            print (last > 0 && is_shell_prompt(line[last])) ? "shell" : "working"; exit
        }

        # The anchor: the last user message or startup banner above the box.
        kind = "none"; anchor_at = 0
        for (i = prompt_at - 2; i >= 1; i--) {
            if (line[i] ~ /▐▛███▛█/) { kind = "banner"; anchor_at = i; break }
            if (line[i] ~ /^❯ [^ ]/ && line[i] !~ /^❯ Try "/) {
                kind = (line[i] ~ /^❯ \//) ? "command" : "message"; anchor_at = i; break
            }
        }
        # After the anchor, the latest spinner ("✢ Sprouting…") or turn end
        # decides. A turn ends with a done line ("✻ Worked for 42s · done"),
        # or with an interrupt or API error under the message. A message with
        # none of these under it is a reply still streaming: no spinner shows
        # while text streams.
        seen = ""
        for (i = anchor_at + 1; i < prompt_at - 1; i++) {
            if (line[i] ~ /^(✢|✳|✶|✻|✽|·|\*) [A-Z][a-z]+…/) seen = "working"
            else if (line[i] ~ /^(✢|✳|✶|✻|✽|·|\*) [A-Z][a-z]+ for [0-9]/) seen = "waiting"
            else if (line[i] ~ /^ +⎿ +(Interrupted|API Error)/) seen = "waiting"
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
