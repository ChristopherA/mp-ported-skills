#!/bin/sh
# supervise-glance.test.sh -- checks that supervise's text reports the
# supervisor's own zone reading at each worker end (#151).
#
# The glance line in each worker's report is how a maintainer on a remote
# client, with no status line, sees the supervisor approach its zone, where
# a loop stops (#78). This checks that the path supervise
# names resolves to glance.sh from supervise's own folder, that the Report
# step puts the line in the worker's report as printed, reasons included, and
# that the Loop's final report lists it per ticket, and that the
# loop reads the same reading between tickets and wraps up at its stop.
# What glance.sh prints is checked in tests/glance.test.sh. Reads only files in this checkout.
#
# Usage: sh tests/supervise-glance.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skills="$root/plugins/mp-ported-skills/skills"
supervise="$skills/supervise/SKILL.md"
# Sections only some runs reach live beside SKILL.md (#135).
push="$skills/supervise/push-on-approval.md"
loop="$skills/supervise/loop.md"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
contains() { # <file> <fixed string> -- yes or no
    if grep -qF -- "$2" "$1"; then echo yes; else echo no; fi
}

# The glance.sh call, with CLAUDE_SKILL_DIR as supervise's folder.
# Its folder is this session's own: the reading is matched on the folder the
# session started in, so the Project folder finds none from the Hub.
call='sh "${CLAUDE_SKILL_DIR}/../glance/scripts/glance.sh" "$PWD" "${CLAUDE_SESSION_ID}" </dev/null'
check "supervise calls glance.sh" yes "$(contains "$supervise" "$call")"
# The path as the text quotes it, resolved from supervise's folder.
quoted=$(printf '%s' "$call" | sed -n 's/^sh "${CLAUDE_SKILL_DIR}\/\([^"]*\)".*/\1/p')
if [ -n "$quoted" ] && [ -f "$skills/supervise/$quoted" ]; then found=yes; else found=no; fi
check "the path resolves from supervise's folder" yes "$found"

check "the text says why not the Project folder" yes \
    "$(contains "$supervise" "Pass this session's own folder, \`\$PWD\`, not the Project folder")"

# The Report step takes the reading when the run ends, as printed.
check "the reading goes in the worker's report" yes \
    "$(contains "$supervise" "put the line it prints in that worker's report")"
check "a session with no reading reports the reason" yes \
    "$(contains "$supervise" "report that line as it reads, never a number in its place")"
check "Push on approval's report carries the glance" yes \
    "$(contains "$push" "the capture's report, the glance and the run record")"
# The Loop's final report lists the reading for each ticket.
check "the final report lists each ticket's reading" yes \
    "$(contains "$loop" "its outcome, the supervisor's glance line at its end, its commits")"

# Between tickets, next.sh reads this session's reading from the same
# folder the glance passes, and stops the loop at its zone stop (#78).
check "the loop passes next.sh this session and its folder" yes \
    "$(contains "$loop" '--session "${CLAUDE_SESSION_ID}" --session-dir "$PWD" </dev/null')"
check "a zone stop posts a loop summary" yes \
    "$(contains "$loop" 'gh issue comment <parent> --body-file "<scratchpad>/loop-summary.md"')"
check "a zone stop lists what waits on the maintainer and takes none" yes \
    "$(contains "$loop" "Take none of them")"
check "a zone stop ends with this session's capture" yes \
    "$(contains "$loop" 'After the final report, run `/mp-ported-skills:capturing` in this session')"
check "the old not-a-stop text is gone" no \
    "$(contains "$loop" "not yet a stop condition")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
