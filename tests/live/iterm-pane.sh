#!/bin/sh
# iterm-pane.sh -- live smoke test for the iterm-pane skill's scripts.
#
# Opens a real iTerm2 pane below the calling session, types a command into
# it, reads the result back, closes the pane, and checks that reading the
# closed pane reports it gone. It lives apart from tests/*.test.sh because it
# needs iTerm2 and a session running inside it; without them it prints SKIP
# and exits 0.
#
# Usage: sh tests/live/iterm-pane.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/iterm-pane/scripts"

# Ask AppleScript, which does not launch the app. macOS pgrep leaves out its
# own ancestors unless given -a, and iTerm2 is one when this runs inside it.
if [ "$(uname)" != Darwin ] ||
    [ "$(osascript -e 'application "iTerm2" is running' 2>/dev/null)" != true ]; then
    echo "iterm-pane live: SKIP (iTerm2 is not running)"
    exit 0
fi

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

if ! coords=$(sh "$scripts/pane-open.sh" --direction horizontal </dev/null 2>&1); then
    case "$coords" in
        *"could not determine calling TTY"*|*"No iTerm2 session found"*)
            echo "iterm-pane live: SKIP (this session is not running in iTerm2)"
            exit 0 ;;
    esac
    echo "FAIL open: $coords"
    exit 1
fi
set -- $coords
pane="--session $1 --window $2 --tab $3"
check "open: three coordinates" 3 "$#"

check "tty: the pane has one" /dev/ "$(sh "$scripts/pane-tty.sh" "$1" </dev/null | cut -c1-5)"
check "find: recovers the coordinates" "$coords" "$(sh "$scripts/pane-find.sh" --session "$1" </dev/null)"

# The marker is computed by the shell, so the echoed command line cannot
# match it before the command has run.
sh "$scripts/pane-send.sh" $pane --text 'echo live-$((6 * 7))' </dev/null
seen=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if sh "$scripts/pane-read.sh" $pane --lines 5 </dev/null | grep -qx 'live-42'; then
        seen=yes; break
    fi
    sleep 0.5
done
check "send and read: the command's output appears" yes "$seen"

sh "$scripts/pane-close.sh" $pane </dev/null 2>/dev/null
check "close without --force: refused" 2 "$?"
sh "$scripts/pane-close.sh" $pane --force </dev/null
check "close --force: exit 0" 0 "$?"

sleep 0.5
err=$(sh "$scripts/pane-read.sh" $pane </dev/null 2>&1 >/dev/null)
check "read after close: pane reported gone" \
    "pane-read.sh: no pane with session $1 in tab $3 of window $2 (closed, or wrong coordinates)" "$err"

echo "iterm-pane live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
