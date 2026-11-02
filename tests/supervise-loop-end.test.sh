#!/bin/sh
# supervise-loop-end.test.sh -- checks that supervise's text posts the loop
# summary whenever a --loop run ends, whatever ended it (#160).
#
# A maintainer who leaves a loop running overnight reads one comment in the
# morning: the loop summary on the tickets' parent. Before #160 it was posted
# only on a zone stop, so a run that ended on a next.sh stop, a blocked
# worker or an error left its results spread over the run records and the
# supervisor's terminal. This checks that every end reaches the Loop end
# section, that the summary there lists each ticket built or parked, the
# unposted findings, the actions waiting on the maintainer and any worker
# left live, each with its command, and that the final report gives its URL.
# Reads only files in this checkout.
#
# Usage: sh tests/supervise-loop-end.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir="$root/plugins/mp-ported-skills/skills/supervise"
skill="$dir/SKILL.md"
loop="$dir/loop.md"
adr="$root/docs/adr/0003-supervise-drives-background-sessions.md"

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
line_no() { # <file> <fixed string> -- first line number, or 0
    n=$(grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1)
    echo "${n:-0}"
}
section() { # <file> <heading> -- the lines from the heading to the next ## heading
    awk -v h="$2" '$0 == h { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}
section_has() { # <file> <heading> <fixed string> -- yes or no
    if section "$1" "$2" | grep -qF -- "$3"; then echo yes; else echo no; fi
}

end='## Loop end'
check "loop.md has a Loop end section" yes "$(contains "$loop" "$end")"

# Every end reaches it: next.sh's stops, its errors, and a ticket that
# ended the loop.
check "every end of a loop reaches Loop end" yes \
    "$(contains "$loop" 'Every end of a `--loop` run, whatever ended it, goes on to Loop end')"
check "next.sh's stops go to Loop end" yes \
    "$(contains "$loop" 'and the loop ends there (Loop end, below):')"
check "next.sh's error goes to Loop end" yes \
    "$(contains "$loop" 'Exit 1: report the error, and end the loop (Loop end, below).')"
check "a ticket that ends the loop goes to Loop end" yes \
    "$(contains "$loop" 'Any other outcome ends the loop at that ticket (Loop end, below)')"
check "a loop that ran no ticket posts no summary" yes \
    "$(section_has "$loop" "$end" 'A loop that ends before its first launch posts no summary')"

# The summary is posted under the no-ask rule, on each distinct parent.
check "Loop end posts the summary on the parent" yes \
    "$(section_has "$loop" "$end" 'gh issue comment <parent> --body-file "<scratchpad>/loop-summary.md"')"
check "the summary is posted without asking" yes \
    "$(section_has "$loop" "$end" 'the summary is a comment the supervisor posts without asking')"
check "Zone stop no longer posts its own summary" no \
    "$(section_has "$loop" '## Zone stop' 'gh issue comment <parent>')"
check "Zone stop goes on to Loop end" yes \
    "$(section_has "$loop" '## Zone stop' 'then go on to Loop end, below')"

# What the summary lists.
for item in \
    'the condition that ended the run, as its `stop` line, error or outcome' \
    'for a parked ticket, its question, the URL of its `## Parked` comment and its branch `parked-N`' \
    'each finding a capture could not post, with the command that posts it' \
    'each push, merge or issue close waiting on the maintainer, with the command that takes it in a fenced code block' \
    'each worker left live, with `claude attach <id>`'
do
    check "the summary lists: $item" yes "$(section_has "$loop" "$end" "$item")"
done
check "the summary lists built and parked tickets alike" yes \
    "$(section_has "$loop" "$end" 'each ticket the loop ran, built or parked, in order')"

# The final report gives the summary's URL for every end, and the capture
# stays last.
check "the final report gives the summary's URL" yes \
    "$(section_has "$loop" "$end" 'the loop summary'"'"'s URL')"
capture=$(line_no "$loop" '3. **Capture.** After the final report')
endl=$(line_no "$loop" "$end")
if [ "$endl" -gt 0 ] && [ "$capture" -gt "$endl" ]; then after=yes; else after=no; fi
check "the final capture is in Loop end" yes "$after"
check "Done when gives the summary's URL for any loop end" yes \
    "$(contains "$skill" 'and for a loop, whatever ended it, the loop summary'"'"'s URL')"
check "Done when no longer ties the summary to a zone stop" no \
    "$(contains "$skill" "for a loop's \`zone\` stop, the loop summary's URL")"
check "ADR 0003 says the summary is posted whenever a loop ends" yes \
    "$(contains "$adr" 'a loop'"'"'s summary of those records on the tickets'"'"' parent whenever the loop ends (#78, #160)')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
