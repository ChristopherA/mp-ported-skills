#!/bin/sh
# capturing.test.sh -- checks the capturing skill's text against what it
# depends on (#108).
#
# Capturing's first next step is read from resuming's state.sh, not reasoned
# out, so the two cannot disagree: this checks that the path capturing names
# resolves to the script from capturing's own folder, and that both skills
# carry the rule, and the use of what the step unblocks, in the same words.
# It also checks that move 1 reads a ticket's parent before moving the
# in-motion label, so an in-motion parent keeps it, and that a ticket the
# sweep files under a parent gets its blockers and a place in the parent's
# order (#124). What state.sh prints in
# that state is checked in tests/resuming.test.sh. Reads only files in this
# checkout.
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
# What the step unblocks reaches the reason in both, in the same words (#123).
unblocks="When the step's ticket is the last open blocker of a High ticket, \`state.sh\`'s \`next unblocks:\` or \`runner-up unblocks:\` line names it with \`(High)\`; say in the reason that the step unblocks it."
check "capturing names what the step unblocks" yes "$(contains "$capturing" "$unblocks")"
check "resuming names what the step unblocks" yes "$(contains "$resuming" "$unblocks")"

# Move 1 reads the parent before moving the label.
check "move 1 reads the ticket's parent" yes \
    "$(contains "$capturing" "gh api 'repos/{owner}/{repo}/issues/N/parent'")"
check "an in-motion parent keeps its label" yes \
    "$(contains "$capturing" "When the parent is labelled \`in-motion\`, change no label")"

# A ticket filed under a parent: blockers from what the session reasoned,
# a placement asked with the filing, and no reorder unattended (#124).
check "the new-ticket routes point at placing" yes \
    "$(contains "$capturing" "placed per **A new ticket under a parent**")"
check "an ordering reasoned in prose becomes a Blocked by line" yes \
    "$(contains "$capturing" "\"land #N first\" becomes \`Blocked by: #N\`")"
check "the placement is asked in the filing's question" yes \
    "$(contains "$capturing" "in the same AskUserQuestion that confirms the filing")"
check "a yes applies the placement through the priority API" yes \
    "$(contains "$capturing" "sub_issues/priority")"
check "unattended leaves the order alone" yes \
    "$(contains "$capturing" "no grant covers a sub-issue reorder")"

# A ticket left open for a live check is relabelled and moved after its
# parent's ready-for-agent children in one step, gated like the relabel, and
# the supervisor runs it on approval (#194). What the script does is checked
# in tests/capturing-live-check.test.sh.
live='sh "${CLAUDE_SKILL_DIR}/scripts/live-check.sh" N </dev/null'
check "capturing calls live-check.sh" yes "$(contains "$capturing" "$live")"
if [ -f "$skills/capturing/scripts/live-check.sh" ]; then found=yes; else found=no; fi
check "live-check.sh is in capturing's folder" yes "$found"
check "unattended, the capture waits on the relabel and the move" yes \
    "$(contains "$capturing" "on \`Waiting on: sh <this skill's folder>/scripts/live-check.sh --apply N\`")"
check "attended, the capture asks before the relabel and the move" yes \
    "$(contains "$capturing" "\`attended\`: both are tracker changes others see, so ask once")"
supervise="$skills/supervise/SKILL.md"
sup_call='sh "${CLAUDE_SKILL_DIR}/../capturing/scripts/live-check.sh" --dir "<project folder>" N </dev/null'
check "the supervisor routes the wait" yes \
    "$(contains "$supervise" "**\`blocked input needed\`** on \`live-check.sh --apply N\`")"
check "the supervisor calls live-check.sh from its own plugin" yes "$(contains "$supervise" "$sup_call")"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
