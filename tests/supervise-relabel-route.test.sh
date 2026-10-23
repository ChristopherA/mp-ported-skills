#!/bin/sh
# supervise-relabel-route.test.sh -- checks the supervise skill's route for
# a worker that pushed its ticket and then waits on relabelling it
# ready-for-human (#204).
#
# No grant covers that relabel, so the build's turn ends on `Waiting on: gh
# issue edit N --add-label ready-for-human ...`. The work is settled, and
# the capture's live-check step already takes the relabel and the reorder
# on one question, so the Report step sends the capture rather than leaving
# the worker running. This checks that route in SKILL.md, that a capture
# waiting on the live check and on a push or a post reaches the live-check
# question in SKILL.md and zone-capture.md, that routine-answers.md leaves
# the block to the Report step, and that loop.md counts a capture ending on
# the live check as settled. Reads only files in this checkout.
#
# Usage: sh tests/supervise-relabel-route.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir="$root/plugins/mp-ported-skills/skills/supervise"
skill="$dir/SKILL.md"
zone="$dir/zone-capture.md"
loop="$dir/loop.md"
routine="$dir/routine-answers.md"

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

# The Report step routes the post-push relabel to the capture.
head_relabel="**\`blocked input needed\`** whose \`needs\` line relabels the worker's own ticket to \`ready-for-human\`"
report=$(line "$skill" "- $head_relabel")
check "the Report step has the relabel route" yes "$(has_in "$report" "$head_relabel")"
check "the route holds only when the work is pushed" yes \
    "$(has_in "$report" "shows the branch even with its upstream")"
check "the route sends the capture" yes "$(has_in "$report" "Send the capture (Capture, below)")"
check "the route asks the maintainer nothing first" yes \
    "$(has_in "$report" "ask the maintainer nothing first")"
check "the capture's live check takes the relabel and the move" yes \
    "$(has_in "$report" "its live-check step runs \`live-check.sh\`, which takes the relabel and the move")"
check "the live check is one question" yes \
    "$(has_in "$report" "which Capture's step 3 puts to the maintainer as one question")"
check "the route checks a Distribution repo too" yes \
    "$(has_in "$report" "with a Distribution repo, that repo's too")"
check "a capture that ends done leaves no shipped ticket ready-for-agent" yes \
    "$(has_in "$report" "When the capture then returns \`done\` with the ticket still labelled \`ready-for-agent\`")"
check "a branch still ahead is reported as other states are" yes \
    "$(has_in "$report" "A branch ahead of its upstream")"
report_line=$(grep -nF -- "- $head_relabel" "$skill" | cut -d: -f1)
other_line=$(grep -nF -- '- **Any other state** (`moved`' "$skill" | cut -d: -f1)
check "the route comes before Any other state" yes \
    "$([ -n "$report_line" ] && [ -n "$other_line" ] && [ "$report_line" -lt "$other_line" ] && echo yes || echo no)"

# Capture's When list names the block.
when=$(line "$skill" "- **When:**")
check "Capture runs after the relabel block" yes \
    "$(has_in "$when" "the post-push \`ready-for-human\` relabel of the worker's own ticket")"

# A capture waiting on a push and the live check reaches the live check:
# the needs line holds only the last Waiting on line.
both="names \`live-check.sh --apply N\` as well"
push=$(line "$skill" "   - **\`blocked input needed\`** on a \`git push\` no grant covers")
check "Capture's push route names the second wait" yes "$(has_in "$push" "$both")"
check "Capture's push route defers to the live check" yes \
    "$(has_in "$push" "take the \`live-check.sh\` bullet below instead")"
live=$(line "$skill" "   - **\`blocked input needed\`** on \`live-check.sh --apply N\`")
check "Capture's live-check route says how a push is seen" yes \
    "$(has_in "$live" "When a \`git push\` also waits (the capture's message names one, or")"
check "Capture's live check comes before finish.sh" yes \
    "$(has_in "$live" "Push on approval first, up to its step 6")"
check "Capture's live-check route sees a Distribution push" yes \
    "$(has_in "$live" "with a Distribution repo \`git -C \"<distribution repo>\" status -sb\` shows that one ahead")"
check "Capture's live-check route ends with step 6, a post, or done" yes \
    "$(has_in "$live" "Then Push on approval's step 6 when it ran; or else, when the capture's message names a \`gh issue comment\` or \`gh issue create\` no grant covers, Post on approval")"
post=$(line "$skill" "   - **\`blocked input needed\`** on a \`gh issue comment\` or \`gh issue create\`")
check "Capture's post route names the second wait" yes "$(has_in "$post" "$both")"
check "Capture's post route defers to the live check" yes \
    "$(has_in "$post" "take the \`live-check.sh\` bullet below instead, which posts after the live check")"
zpush=$(line "$zone" "   - **\`blocked input needed\`** on a \`git push\`")
check "the zone capture's push route names the second wait" yes "$(has_in "$zpush" "$both")"
check "the zone capture's push route defers to the live check" yes \
    "$(has_in "$zpush" "take the \`live-check.sh\` bullet below")"
zlive=$(line "$zone" "   - **\`blocked input needed\`** on \`live-check.sh --apply N\`")
check "the zone capture's live check comes before finish.sh" yes \
    "$(has_in "$zlive" "up to its step 6")"
check "the zone capture's live-check route posts before step 4" yes \
    "$(has_in "$zlive" "Post on approval (read \`\${CLAUDE_SKILL_DIR}/post-on-approval.md\` and follow it), whose last step runs \`finish.sh\` in place of step 4")"
zpost=$(line "$zone" "   - **\`blocked input needed\`** on a \`gh issue comment\` or \`gh issue create\`")
check "the zone capture's post route names the second wait" yes "$(has_in "$zpost" "$both")"
check "the zone capture's post route defers to the live check" yes \
    "$(has_in "$zpost" "take the \`live-check.sh\` bullet above, which posts after the live check")"

# Routine answers' not-routine exit leaves a settled route to the Report step.
exit2=$(line "$routine" "- **Exit 2**")
check "a not-routine block goes on by the Report step" yes \
    "$(has_in "$exit2" "Go on by the items of \`SKILL.md\`'s Report step")"
check "claude attach only for a block reported to the maintainer" yes \
    "$(has_in "$exit2" "for one they report to the maintainer, add \`claude attach ID\`")"

# loop.md counts an ordinary capture ending on the live check as settled.
settle=$(line "$loop" "A ticket's run goes on to the next only when")
check "loop settles on the relabel block" yes \
    "$(has_in "$settle" "the post-push \`ready-for-human\` relabel of its own ticket")"
check "loop settles on a capture ending on the live check" yes \
    "$(has_in "$settle" "its capture ran (Capture, in \`SKILL.md\`), one ending on \`live-check.sh --apply N\` included")"

check "loop goes on past the relabel and the live check" yes \
    "$(has_in "$settle" "other than that push, that relabel, or a capture's issue comment, new issue or live check")"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
