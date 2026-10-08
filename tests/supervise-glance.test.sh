#!/bin/sh
# supervise-glance.test.sh -- checks that supervise's text reports the
# supervisor's own zone reading at each worker end (#151).
#
# Leaving the zone is not a stop condition (#78), so the glance line in each
# worker's report is how a maintainer on a remote client, with no status
# line, sees the supervisor approach it. This checks that the path supervise
# names resolves to glance.sh from supervise's own folder, that the Report
# step puts the line in the worker's report as printed, reasons included, and
# that the Loop's final report lists it per ticket. What glance.sh prints is
# checked in tests/glance.test.sh. Reads only files in this checkout.
#
# Usage: sh tests/supervise-glance.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skills="$root/plugins/mp-ported-skills/skills"
supervise="$skills/supervise/SKILL.md"

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
    "$(contains "$supervise" "the capture's report, the glance and the run record")"
# The Loop's final report lists the reading for each ticket.
check "the final report lists each ticket's reading" yes \
    "$(contains "$supervise" "its outcome, the supervisor's glance line at its end, its commits")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
