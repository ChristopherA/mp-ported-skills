#!/bin/sh
# supervise-start.test.sh -- checks that supervise's SKILL.md gives the
# maintainer a start command for a supervisor session that leaves out the
# tools no supervisor step calls, the same ones launch.sh leaves out of a
# worker (#229), and a route for a session started from the Claude app.
#
# A supervisor is started by hand, so it loads every tool unless its start
# command drops them. The list here is read from launch.sh, so a tool added
# to the worker's list and not to the supervisor's command fails here.
# Reads only files in this checkout.
#
# Usage: sh tests/supervise-start.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir="$root/plugins/mp-ported-skills/skills/supervise"
skill="$dir/SKILL.md"
launch="$dir/scripts/launch.sh"
research="$root/docs/research/supervisor-context.md"

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
    if [ -f "$1" ] && grep -qF -- "$2" "$1"; then echo yes; else echo no; fi
}

unused=$(sed -n 's/^UNUSED="\(.*\)"$/\1/p' "$launch")
check "launch.sh names its unused tools on one UNUSED line" \
    "Artifact Workflow ScheduleWakeup SendFeedback" "$unused"
commas=$(printf '%s' "$unused" | tr ' ' ',')
quoted=$(printf '%s' "$unused" | sed 's/[^ ]*/"&"/g; s/ /, /g')

check "SKILL.md has a section on starting the supervisor's session" yes \
    "$(contains "$skill" '## Starting this session')"
check "the start command drops launch.sh's unused tools and Chrome" \
    "claude --disallowedTools $commas --no-chrome" \
    "$(grep -x "claude --disallowedTools [A-Za-z,]* --no-chrome" "$skill")"
check "the section says why each tool is left out" yes \
    "$(contains "$skill" 'publish a page, run a workflow, schedule a `/loop` wakeup, draft feedback or drive a browser')"
check "the section names the saving's source" yes \
    "$(contains "$skill" '`docs/research/supervisor-context.md`')"
check "the app route names the server's lack of a tool deny" yes \
    "$(contains "$skill" '`claude remote-control` server')"
check "the app route gives the same tools as a settings deny" yes \
    "$(contains "$skill" "\"permissions\": {\"deny\": [$quoted]}")"
check "the app route says the settings file must be git-ignored" yes \
    "$(contains "$skill" 'git-ignored')"

check "the research records the start command's first call" yes \
    "$(contains "$research" '## A supervisor started without its unused tools (#229)')"
check "the research records the start command against its base" yes \
    "$(contains "$research" '| Started with the start command | 57,747 |')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
