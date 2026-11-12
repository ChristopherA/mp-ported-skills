#!/bin/sh
# live-session-id.test.sh -- tests for tests/live/session-id.sh, the helper
# the live tests read a `claude --bg` session id with.
#
# Feeds it launch output in the forms Claude Code prints: a plain
# `backgrounded · <id>` line, one ending in ` · <name>` for a named session,
# and one with the id in colour codes, as FORCE_COLOR prints it, and checks
# it prints the id that launch.sh would read from each. Runs no `claude`.
#
# Usage: sh tests/live-session-id.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tests/live/session-id.sh"
launch_sh="$root/plugins/mp-ported-skills/skills/supervise/scripts/launch.sh"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

esc=$(printf '\033')

check "plain line" c2a368ee "$(bg_session_id "backgrounded · c2a368ee")"
check "named session" c2a368ee "$(bg_session_id "backgrounded · c2a368ee · mp-106 worker")"
check "colour codes" c2a368ee \
    "$(bg_session_id "backgrounded · ${esc}[36mc2a368ee${esc}[39m")"
check "colour codes and a name" c2a368ee \
    "$(bg_session_id "backgrounded · ${esc}[2m${esc}[36mc2a368ee${esc}[39m${esc}[22m · mp-106")"
check "among other lines" c2a368ee "$(bg_session_id "starting
backgrounded · c2a368ee · w
backgrounded · ffff0000")"
check "no backgrounded line" "" "$(bg_session_id "Workspace not trusted")"
check "id is hex only" "" "$(bg_session_id "backgrounded · not-an-id")"
check "a name with no separator is not an id" "" "$(bg_session_id "backgrounded · c2a368eezz")"

# The helper reads the line as launch.sh does: its pattern is launch.sh's.
pattern='s/^backgrounded · \([0-9a-f][0-9a-f]*\)\( · .*\)\{0,1\}$/\1/p'
check "launch.sh uses the same pattern" 1 "$(grep -cF "$pattern" "$launch_sh")"
check "the helper uses the same pattern" 1 "$(grep -cF "$pattern" "$root/tests/live/session-id.sh")"

# Every live test that launches `claude --bg` reads its id through the helper.
for f in "$root"/tests/live/*.sh; do
    case $f in */session-id.sh) continue ;; esac
    grep -q 'claude --bg\|claude "\$@"' "$f" || continue
    grep -q '^backgrounded\|sed -n .s/^backgrounded' "$f" &&
        check "$(basename "$f") parses the line itself" none found
    check "$(basename "$f") sources the helper" 1 "$(grep -c '^\. "\$root/tests/live/session-id.sh"$' "$f")"
done

printf 'live-session-id: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
