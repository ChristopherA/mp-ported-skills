#!/bin/sh
# supervise-done-report.test.sh -- checks the supervise skill's `done`
# report for a Project with a Distribution repo (#219).
#
# A worker in such a Project commits its code in the Distribution repo, so
# a report that lists only the Project repo's `<start>..HEAD` shows a worker
# that committed only there as having no commits, and the "no commits and
# the ticket open" check then reads a finished run as a blocked one. This
# checks that the `done` item in SKILL.md's Report step lists the
# Distribution repo's commits from step 1's `<dist start>` under that
# repo's name, counts both repos in the no-commits check, and keeps the
# Project-only report for a Project with none. Reads only files in this
# checkout.
#
# Usage: sh tests/supervise-done-report.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skill="$root/plugins/mp-ported-skills/skills/supervise/SKILL.md"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
# has_in <text> <fixed string> -- yes or no
has_in() { if printf '%s\n' "$1" | grep -qF -- "$2"; then echo yes; else echo no; fi; }

done_head='- **`done`**: '
done_item=$(grep -F -- "$done_head" "$skill" | head -n 1)
check "the Report step has the done item" yes "$(has_in "$done_item" "$done_head")"
check "done lists the Project repo's commits" yes \
    "$(has_in "$done_item" 'its commits, `git -C <cwd> log --oneline <start>..HEAD`')"
check "done lists the Distribution repo's commits from <dist start>" yes \
    "$(has_in "$done_item" '`git -C "<dist>" log --oneline <dist start>..HEAD`')"
check "the Distribution repo's commits only with a dist head line" yes \
    "$(has_in "$done_item" 'When step 1'"'"'s snapshot has a `dist head` line')"
check "the Distribution repo is the snapshot's distribution line" yes \
    "$(has_in "$done_item" '`<dist>` the path on its `distribution` line')"
check "each repo's commits under its own name" yes \
    "$(has_in "$done_item" "each repo's commits under its own name")"
check "the no-commits check counts both repos" yes \
    "$(has_in "$done_item" 'with no commits in either repo and the ticket open')"
check "the old Project-only no-commits check is gone" no \
    "$(has_in "$done_item" 'with no commits and the ticket open')"
check "a Project with no Distribution repo reports as before" yes \
    "$(has_in "$done_item" 'With no `dist head` line, only the Project repo')"

# The same gap in the other reports that list a worker's commits.
dir=$(dirname -- "$skill")
zone_line=$(grep -F -- 'On a no, a failed check or a failed push, the report also lists the unpushed commits' "$dir/zone-capture.md" | head -n 1)
check "a declined zone-capture push lists the Distribution repo's commits too" yes \
    "$(has_in "$zone_line" '`git -C "<dist>" log --oneline <dist start>..HEAD`')"
loop_line=$(grep -F -- '- each ticket the loop ran, built or parked, in order:' "$dir/loop.md" | head -n 1)
check "the loop summary lists the Distribution repo's commits too" yes \
    "$(has_in "$loop_line" "that repo's \`<dist start>..<end>\` and count too, under its own name")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
