#!/bin/sh
# supervise-sections.test.sh -- checks that supervise's SKILL.md holds the
# path every run takes, and that each section only some runs reach lives in
# a file beside it, read at the step that needs it (#135).
#
# The whole of SKILL.md loads when the skill starts, so a section kept there
# costs every run its size, and a loop pays it once per ticket. This checks
# that each moved file exists, that SKILL.md tells the reader to read it,
# that its heading is gone from SKILL.md, that each moved file says what
# `${CLAUDE_SKILL_DIR}` means in it (Claude Code fills it in only in
# SKILL.md), and that every file SKILL.md names to read exists. Reads only
# files in this checkout.
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
    echo "$file says what CLAUDE_SKILL_DIR is:$(contains "$dir/$file" 'Claude Code fills it in only in `SKILL.md`')"
done > "${TMPDIR:-/tmp}/supervise-sections.$$"
while IFS=: read -r name got; do
    case $name in
        *'heading left SKILL.md') check "$name" no "$got" ;;
        *) check "$name" yes "$got" ;;
    esac
done < "${TMPDIR:-/tmp}/supervise-sections.$$"
command rm -f "${TMPDIR:-/tmp}/supervise-sections.$$"

# Every file SKILL.md tells the reader to read is there.
missing=
for f in $(sed -n 's/.*read `${CLAUDE_SKILL_DIR}\/\([a-z-]*\.md\)`.*/\1/p' "$skill" | sort -u); do
    [ -f "$dir/$f" ] || missing="$missing $f"
done
check "every file SKILL.md names exists" "" "$missing"

# The common path stays inline.
for heading in '## 1. Step' '## 2. Launch' '## 3. Watch' '## 4. Report' '### Stopping' '## Capture' '## Follow-ups'; do
    check "SKILL.md keeps $heading" yes "$(contains "$skill" "$heading")"
done
check "SKILL.md keeps the done item" yes "$(contains "$skill" '- **`done`**:')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
