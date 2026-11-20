#!/bin/sh
# supervise-unrouted-capture.test.sh -- checks the supervise skill's route
# for a capture that ends `blocked input needed` on a shared action no
# supervisor route takes (anything but a push, a post or a live check),
# #244.
#
# When the work is settled (the branch even with its upstream, and the
# Distribution repo's, and the ticket closed or relabelled), the run ends
# with finish.sh as for `done`, and the blocked command is listed for the
# maintainer in the report and the loop summary. When it is not, the block
# is reported with `claude attach` as before. This checks the route in
# SKILL.md's Capture step 3, report-states.md, zone-capture.md (per the
# Capture routes rule) and loop.md. Reads only files in this checkout.
#
# Usage: sh tests/supervise-unrouted-capture.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir="$root/plugins/mp-ported-skills/skills/supervise"
skill="$dir/SKILL.md"
states="$dir/report-states.md"
zone="$dir/zone-capture.md"
loop="$dir/loop.md"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
# line <file> <fixed string>: the first line holding the string.
line() { grep -F -- "$2" "$1" | head -n 1; }
# has_in <text> <fixed string> -- yes or no
has_in() { if printf '%s\n' "$1" | grep -qF -- "$2"; then echo yes; else echo no; fi; }
# lineno <file> <fixed string>: the first line number holding the string.
lineno() { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1; }
before() { # <a> <b> -- yes when both are set and a < b
    if [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; then echo yes; else echo no; fi
}

head_unrouted="**\`blocked input needed\`** on any other shared action no grant covers"
settled="the branch even with its upstream"
dist="\`git -C \"<distribution repo>\" status -sb\`"
closed="the ticket is closed or labelled \`ready-for-human\`"
listed="list the blocked command among the actions waiting on the maintainer"

# SKILL.md's Capture step 3.
cap=$(line "$skill" "   - $head_unrouted")
check "Capture's step 3 has the unrouted route" yes "$(has_in "$cap" "$head_unrouted")"
check "the route checks the branch is even" yes "$(has_in "$cap" "$settled")"
check "the route checks a Distribution repo too" yes "$(has_in "$cap" "$dist")"
check "the route checks the ticket" yes "$(has_in "$cap" "$closed")"
check "settled work ends with finish.sh as for done" yes \
    "$(has_in "$cap" "end the run with \`finish.sh\` (Finishing, above) as for \`done\`")"
check "the blocked command is listed for the maintainer" yes "$(has_in "$cap" "$listed")"
check "the command is in the report and the loop summary" yes \
    "$(has_in "$cap" "in this run's report and, with \`--loop\`, the loop summary")"
check "unsettled work is still reported with claude attach" yes \
    "$(has_in "$cap" "Otherwise the work is not settled: report the block as the Report step says for \`blocked input needed\`, with \`claude attach ID\`, the worker left running")"
check "another wait in the message goes first" yes \
    "$(has_in "$cap" "When the capture's message also names a wait a bullet above takes")"
check "Capture's route comes before Any other state" yes \
    "$(before "$(lineno "$skill" "   - $head_unrouted")" "$(lineno "$skill" "   - **Any other state**: the Report step for that state.")")"

# Finishing names the new settled end.
fin=$(line "$skill" "A settled run (")
check "Finishing counts the unrouted capture block as settled" yes \
    "$(has_in "$fin" "a capture's block with no route and its work settled (Capture's step 3)")"

# report-states.md leaves the settled case to Capture's step 3.
blk=$(line "$states" "Leave the worker running, and its marker in place. Report any")
check "report-states sends a settled capture block to Capture" yes \
    "$(has_in "$blk" "A capture's own \`blocked input needed\` on an action no route in Capture's step 3 takes, with its work settled, is not reported here")"
check "report-states names finish.sh for it" yes \
    "$(has_in "$blk" "that step ends the run with \`finish.sh\` and lists the blocked command for the maintainer")"
check "report-states still reports an unsettled one" yes \
    "$(has_in "$blk" "An unsettled one is reported here, as above")"

# zone-capture.md gets the same route.
zcap=$(line "$zone" "   - $head_unrouted")
check "zone capture has the unrouted route" yes "$(has_in "$zcap" "$head_unrouted")"
check "zone route holds only when the work has landed" yes \
    "$(has_in "$zcap" "the work has landed and is settled")"
check "zone route checks the branch is even" yes "$(has_in "$zcap" "$settled")"
check "zone route checks a Distribution repo too" yes "$(has_in "$zcap" "$dist")"
check "zone route goes on to step 4" yes "$(has_in "$zcap" "go on to step 4")"
check "zone route lists the blocked command" yes "$(has_in "$zcap" "$listed")"
check "zone route reports an unsettled one with no continuation" yes \
    "$(has_in "$zcap" "Otherwise \`SKILL.md\`'s Report step for \`blocked input needed\`, with \`claude attach ID\` and no continuation")"
check "zone route comes before Any other state" yes \
    "$(before "$(lineno "$zone" "   - $head_unrouted")" "$(lineno "$zone" "   - **Any other state**")")"

# loop.md counts it as settled and lists the command in the summary.
settle=$(line "$loop" "A ticket's run goes on to the next only when")
check "loop settles on an unrouted capture block with settled work" yes \
    "$(has_in "$settle" "one ending on an action no route takes, with its work settled and the command listed for the maintainer, included")"
summary=$(line "$loop" "each ticket the loop ran, built or parked, in order")
check "loop summary lists the blocked command" yes \
    "$(has_in "$summary" "any command its capture blocked on that no route takes, waiting on the maintainer")"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
