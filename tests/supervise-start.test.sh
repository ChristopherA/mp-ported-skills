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
has_line() { # <file> <whole line> -- yes or no
    if [ -f "$1" ] && grep -qxF -- "$2" "$1"; then echo yes; else echo no; fi
}

unused=$(sed -n 's/^UNUSED="\(.*\)"$/\1/p' "$launch")
check "launch.sh names its unused tools on one UNUSED line" \
    "Artifact Workflow ScheduleWakeup SendFeedback" "$unused"
commas=$(printf '%s' "$unused" | tr ' ' ',')
quoted=$(printf '%s' "$unused" | sed 's/[^ ]*/"&"/g; s/ /, /g')

check "SKILL.md has a section on starting the supervisor's session" yes \
    "$(has_line "$skill" '## Starting this session')"
check "the start command drops launch.sh's unused tools and Chrome" \
    "claude --disallowedTools $commas --no-chrome" \
    "$(grep -x "claude --disallowedTools [A-Za-z,]* --no-chrome" "$skill")"
check "the section says why each tool is left out" yes \
    "$(contains "$skill" 'publish a page, run a workflow, schedule a `/loop` wakeup, draft feedback or drive a browser')"
check "the section names the saving's source" yes \
    "$(contains "$skill" '`docs/research/supervisor-context.md`')"
# The terminal route: a shell function the maintainer copies. Run the
# function as written in SKILL.md, against a fake claude that prints its
# arguments one per line, so the check reads what claude would receive.
fn=$(sed -n '/^claude-supervise() {$/,/^}$/p' "$skill")
check "SKILL.md gives the claude-supervise function" yes \
    "$([ -n "$fn" ] && echo yes || echo no)"
# Under bash, not sh: a function name with a hyphen is fine in zsh and bash
# but refused by POSIX sh, which macOS /bin/sh enforces.
args_of() { # <args to the function...> -- claude's arguments, one per line
    env -u BASH_ENV bash -c 'claude() { printf "%s\n" "$@"; }; eval "$1"; shift; claude-supervise "$@"' \
        _ "$fn" "$@"
}
nl='
'
check "the function's start: the flags, then the loop command as the prompt" \
    "--disallowedTools${nl}$commas${nl}--no-chrome${nl}/mp-ported-skills:supervise . --loop --model claude-opus-5-5 --effort medium" \
    "$(args_of)"
check "the function's arguments replace the default command's" \
    "--disallowedTools${nl}$commas${nl}--no-chrome${nl}/mp-ported-skills:supervise ../app --loop 2" \
    "$(args_of ../app --loop 2)"
check "the function calls claude by name, so the maintainer's wrapper runs" yes \
    "$(printf '%s\n' "$fn" | grep -q '^ *claude --disallowedTools' && echo yes || echo no)"
check "the section says a positional slash command runs as the skill" yes \
    "$(contains "$skill" 'runs it as the skill, not as plain text')"

# The Claude app route: a server kept for supervising, with the deny in a
# settings file it hands its sessions, in place of the folder's own settings.
check "the app route gives the server command" \
    "claude remote-control --spawn same-dir --no-chrome --permission-mode auto --settings <file>" \
    "$(grep -x 'claude remote-control .*' "$skill")"
check "the app route gives the settings file with the same tools" \
    "{\"permissions\": {\"deny\": [$quoted]}}" \
    "$(grep -x '{"permissions": .*' "$skill")"
check "the app route says why same-dir" yes \
    "$(contains "$skill" 'saves its spawn mode for the folder')"
check "the app route says the file takes the exclude list" yes \
    "$(contains "$skill" '`claudeMdExcludes`')"
check "the app route says auto-compact stays off" yes \
    "$(contains "$skill" 'Auto-compact stays off')"
check "the folder route stays until the server's first call is read" yes \
    "$(contains "$skill" 'Until that reading shows the four tools gone, the measured route stays')"
check "the folder route gives the same tools as a settings deny" yes \
    "$(contains "$skill" "\"permissions\": {\"deny\": [$quoted]}\` (57,752")"
check "the folder route says to git-ignore the settings file" yes \
    "$(contains "$skill" 'Add the file to `.gitignore` when git does not already ignore it')"

check "the research records the start command's first call" yes \
    "$(has_line "$research" '### A supervisor started without its unused tools (#229)')"
check "the research records the start command against its base" yes \
    "$(contains "$research" '| Started with the start command | 57,747 |')"
check "the research records the one-word start's live checks" yes \
    "$(has_line "$research" '### A one-word start (#262)')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
