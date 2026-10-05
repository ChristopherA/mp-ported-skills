#!/bin/sh
# capturing.test.sh -- checks the capturing skill's text against what it
# depends on (#108).
#
# Capturing's first next step is read from resuming's state.sh, not reasoned
# out, so the two cannot disagree: this checks that the path capturing names
# resolves to the script from capturing's own folder, and that both skills
# carry the rule in the same words. It also checks that move 1 reads a
# ticket's parent before moving the in-motion label, so an in-motion parent
# keeps it. What state.sh prints in that state is checked in
# tests/resuming.test.sh. Reads only files in this checkout.
#
# Usage: sh tests/capturing.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skills="$root/plugins/mp-ported-skills/skills"
capturing="$skills/capturing/SKILL.md"
resuming="$skills/resuming/SKILL.md"

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

# The state.sh call, with CLAUDE_SKILL_DIR as capturing's folder.
call='sh "${CLAUDE_SKILL_DIR}/../resuming/scripts/state.sh" </dev/null'
check "capturing calls state.sh" yes "$(contains "$capturing" "$call")"
# The path as the text quotes it, resolved from capturing's folder.
quoted=$(printf '%s' "$call" | sed -n 's/^sh "${CLAUDE_SKILL_DIR}\/\([^"]*\)".*/\1/p')
if [ -n "$quoted" ] && [ -f "$skills/capturing/$quoted" ]; then found=yes; else found=no; fi
check "the path resolves from capturing's folder" yes "$found"

# The rule both skills state, word for word.
rule="capturing's one first next step is the in-motion ticket \`state.sh\`'s \`next:\` line names, or that ticket's next child when the line names one; otherwise the ticket on its \`2 /implement\` line, in \`next:\` or \`runner-up:\`. When the line names every open child of that ticket blocked, the step is the blockers it names."
check "capturing states the shared rule" yes "$(contains "$capturing" "$rule")"
check "resuming states the shared rule" yes "$(contains "$resuming" "$rule")"

# Move 1 reads the parent before moving the label.
check "move 1 reads the ticket's parent" yes \
    "$(contains "$capturing" "gh api 'repos/{owner}/{repo}/issues/N/parent'")"
check "an in-motion parent keeps its label" yes \
    "$(contains "$capturing" "When the parent is labelled \`in-motion\`, change no label")"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
