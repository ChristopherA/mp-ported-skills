#!/bin/sh
# supervise-sections.test.sh -- checks that supervise's SKILL.md holds the
# path every run takes, and that each section only some runs reach lives in
# a file beside it, read at the step that needs it (#135).
#
# The whole of SKILL.md loads when the skill starts, so a section kept there
# costs every run its size, and a loop pays it once per ticket. This checks
# that each moved file exists, that SKILL.md tells the reader to read it,
# that its heading is gone from SKILL.md, that each moved file explains
# every `${CLAUDE_...}` it uses (Claude Code fills them in only in
# SKILL.md), and that every file a read instruction names exists. A step
# that sends the reader to a moved file, in SKILL.md or another moved
# file, tells the reader to read it; a mention that only says where a
# section lives names the file in parentheses. It also checks where the
# supervisor's own capture sits on that path, in SKILL.md's Report step and
# in loop.md (#205). Reads only files in this checkout.
#
# Usage: sh tests/supervise-sections.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir="$root/plugins/mp-ported-skills/skills/supervise"
skill="$dir/SKILL.md"

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

# <file> <heading as it read in SKILL.md>
moved='zone-capture.md|## Zone capture
push-on-approval.md|## Push on approval
post-on-approval.md|## Post on approval
loop.md|## Loop
routine-answers.md|## Routine answers
watching.md|## Watching
report-states.md|- **`moved`**
stop-refused.md|whether to run it again'

printf '%s\n' "$moved" | while IFS='|' read -r file heading; do
    if [ -f "$dir/$file" ]; then e=yes; else e=no; fi
    echo "$file exists:$e"
    echo "$file read from SKILL.md:$(contains "$skill" "read \`\${CLAUDE_SKILL_DIR}/$file\`")"
    echo "$file heading left SKILL.md:$(contains "$skill" "$heading")"
    # Each ${CLAUDE_...} the file uses is explained in it, since only
    # SKILL.md has them filled in; the shell does not set them.
    for v in $(grep -o '[$][{]CLAUDE_[A-Z_]*[}]' "$dir/$file" | sort -u); do
        echo "$file explains $v:$(contains "$dir/$file" "\`$v\` in the commands below is")"
    done
done > "${TMPDIR:-/tmp}/supervise-sections.$$"
while IFS=: read -r name got; do
    case $name in
        *'heading left SKILL.md') check "$name" no "$got" ;;
        *) check "$name" yes "$got" ;;
    esac
done < "${TMPDIR:-/tmp}/supervise-sections.$$"
command rm -f "${TMPDIR:-/tmp}/supervise-sections.$$"

# Every file SKILL.md or a moved file tells the reader to read is there.
missing=
for f in $(cat "$dir"/*.md | grep -o 'read `[$][{]CLAUDE_SKILL_DIR[}]/[a-z-]*[.]md`' | sed 's/.*\///; s/`$//' | sort -u); do
    [ -f "$dir/$f" ] || missing="$missing $f"
done
check "every file a read instruction names exists" "" "$missing"

# A moved file a step sends the reader to ("Post on approval, in
# `post-on-approval.md`") without a read instruction is one a run reaches
# without having read it. A mention that only names where a section lives
# reads "(Post on approval, `post-on-approval.md`)". Each mention is
# checked on its own, so a read instruction or another mention on the same
# line hides none.
bare=$(grep -o -n 'in `[a-z-]*[.]md`' "$dir"/*.md | sed 's/^.*\///; s/:in .*//' | sort -u | tr '\n' ' ')
check "no moved file is named without a read instruction" "" "$bare"

# The common path stays inline.
for heading in '## 1. Step' '## 2. Launch' '## 3. Watch' '## 4. Report' '### Stopping' '## Capture' '## Follow-ups'; do
    check "SKILL.md keeps $heading" yes "$(contains "$skill" "$heading")"
done
check "SKILL.md keeps the done item" yes "$(contains "$skill" '- **`done`**:')"

# The supervisor captures itself at each pause, not only at the end (#205):
# in the Report step, after each worker's report and before a question that
# ends its turn, listed in that order; and in a loop, between tickets, before
# next.sh, with the Zone stop's capture still last.
line_no() { # <file> <fixed string> -- first line number, or 0
    n=$(grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1)
    echo "${n:-0}"
}
before() { # <a> <b> -- yes when 0 < a < b
    if [ "$1" -gt 0 ] && [ "$1" -lt "$2" ]; then echo yes; else echo no; fi
}
report=$(line_no "$skill" '## 4. Report')
own=$(line_no "$skill" '### Capturing this session')
after_report=$(line_no "$skill" "1. **After each worker's report**")
before_question=$(line_no "$skill" '2. **Before a question to the maintainer**')
worker_capture=$(line_no "$skill" '## Capture')
check "SKILL.md's own capture is in the Report step" yes "$(before "$report" "$own")"
check "SKILL.md's own capture comes before the worker's Capture" yes "$(before "$own" "$worker_capture")"
check "the capture after a report is listed first" yes "$(before "$own" "$after_report")"
check "the capture before a question is listed second" yes "$(before "$after_report" "$before_question")"
check "the own capture's list ends before Capture" yes "$(before "$before_question" "$worker_capture")"
check "SKILL.md says each capture covers only what changed" yes \
    "$(contains "$skill" 'Each capture covers only what changed since the last one')"
check "Done when names the capture after each report" yes \
    "$(contains "$skill" "this session's capture after each worker's report")"

loop="$dir/loop.md"
between=$(line_no "$loop" 'Between tickets, first capture this session')
next_cmd=$(line_no "$loop" 'next.sh" --dir')
zone_stop=$(line_no "$loop" '## Zone stop')
check "loop.md captures between tickets before next.sh" yes "$(before "$between" "$next_cmd")"
check "loop.md names the Report step's own capture" yes \
    "$(contains "$loop" "(Capturing this session, \`SKILL.md\`)")"
final=$(line_no "$loop" '3. **Capture.** After the final report')
check "loop.md keeps the final capture in Zone stop" yes "$(before "$zone_stop" "$final")"
check "the final capture covers what changed since the last ticket's" yes \
    "$(contains "$loop" 'covering only what changed since the capture after the last ticket')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
