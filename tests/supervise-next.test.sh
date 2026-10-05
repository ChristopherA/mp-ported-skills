#!/bin/sh
# supervise-next.test.sh -- tests for the supervise skill's next.sh, which
# decides between tickets of a /supervise --loop run whether the loop goes
# on, and names the condition when it stops (#59).
#
# Each case runs against a scratch clone of a bare remote, with a canned
# state.sh report given through --from. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/supervise-next.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'command rm -rf "$work"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Every variable the scripts read, set or unset here, so the result does not
# depend on the session running the test.
unset CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PROJECT_DIR

g() { d=$1; shift; git -C "$d" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }

# A clone of a bare remote, on main, level with origin/main.
new_repo() { # <name> -- prints the clone's path
    git init -q --bare -b main "$work/$1.git"
    git clone -q "$work/$1.git" "$work/$1" 2>/dev/null
    g "$work/$1" commit -q --allow-empty -m "First"
    g "$work/$1" push -q origin main
    git -C "$work/$1" remote set-head origin main >/dev/null 2>&1
    printf '%s\n' "$work/$1"
}

you="you type it; user-invoked"
state() { # <next: line> -- writes a state.sh report ending in it
    printf 'branch: main\nnext: %s\nrunner-up: 7 nothing else in motion\n' "$1" >"$work/state.txt"
}
next() { # <dir> [args...] -- next.sh's output, then `exit N`
    out=$(sh "$scripts/next.sh" --dir "$@" --from "$work/state.txt" </dev/null 2>&1)
    printf '%s\nexit %s' "$out" "$?"
}

repo=$(new_repo level)
state "2 /implement #61 ($you): #61 t61"
check "next: landed, ready ticket" "next implement #61
exit 0" "$(next "$repo")"
check "next: a ticket this loop already ran" "stop repeat: #61 ran earlier in this loop and state.sh still recommends it; was its work committed with Closes #61?
exit 2" "$(next "$repo" --ran "59 61")"
check "next: a ran list without the ticket" "next implement #61
exit 0" "$(next "$repo" --ran "59 610")"

state "7 nothing in motion"
check "next: nothing left" "stop nothing-left: next: 7 nothing in motion
exit 2" "$(next "$repo")"
state "3 /triage ($you): 1 unlabelled, 0 needs-triage, replied needs-info: none"
check "next: another step" "stop other-step: next: 3 /triage ($you): 1 unlabelled, 0 needs-triage, replied needs-info: none
exit 2" "$(next "$repo")"

state "2 /implement #61 ($you): #61 t61"
repo=$(new_repo ahead)
g "$repo" commit -q --allow-empty -m "Unpushed"
check "next: a commit not on the upstream" "stop not-landed: 1 commit on main not on origin/main
exit 2" "$(next "$repo")"

repo=$(new_repo dirty)
echo x >"$repo/x.txt"
check "next: an uncommitted path" "stop not-landed: 1 uncommitted path in $repo
exit 2" "$(next "$repo")"

repo=$(new_repo behind)
git clone -q "$work/behind.git" "$work/other" 2>/dev/null
g "$work/other" commit -q --allow-empty -m "Elsewhere"
g "$work/other" push -q origin main
check "next: the upstream moved on (found by a fetch)" "stop behind: main is 1 commit behind origin/main; the next ticket would start from an old commit
exit 2" "$(next "$repo")"

repo=$(new_repo noup)
git -C "$repo" branch -q --unset-upstream
check "next: no upstream" "stop not-landed: main has no upstream, so its work is on no remote
exit 2" "$(next "$repo")"

repo=$(new_repo held)
echo abc12345 >"$(git -C "$repo" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
check "next: a worker's marker still held" "stop held: the checkout's marker still names worker abc12345, so it is read-only; finish its stop first
exit 2" "$(next "$repo")"

repo=$(new_repo hashes)
check "next: a ran list written with #" "stop repeat: #61 ran earlier in this loop and state.sh still recommends it; was its work committed with Closes #61?
exit 2" "$(next "$repo" --ran "#59, #61")"
state "1 work in flight: in motion #24 t24; next child #28 (ready-for-agent, /implement #28, $you): t28"
check "next: an in-motion parent's ready child" "next implement #28
exit 0" "$(next "$repo")"
state "2 /implement #61 ($you): #61 t61"

repo=$(new_repo detached)
git -C "$repo" checkout -q --detach
check "next: a detached HEAD" "stop not-landed: HEAD is detached in $repo
exit 2" "$(next "$repo")"

repo=$(new_repo gone)
git -C "$repo" config branch.main.merge refs/heads/elsewhere
check "next: an upstream branch the remote lacks" "stop not-landed: main's upstream origin/elsewhere does not exist
exit 2" "$(next "$repo")"

repo=$(new_repo nofetch)
git -C "$repo" remote set-url origin "$work/missing.git"
out=$(next "$repo")
check "next: a failed fetch is an error, with git's reason" "Error: git fetch origin failed in $repo, so whether main landed is unknown:
exit 1" "$(printf '%s\n' "$out" | sed 's/unknown: .*/unknown:/')"

# A count (--max) stops the loop once that many tickets ran (#149).
repo=$(new_repo count)
state "2 /implement #61 ($you): #61 t61"
check "next: count reached" "stop count-reached: 2 tickets ran, the 2 --loop asked for
exit 2" "$(next "$repo" --ran "59 60" --max 2)"
check "next: count not yet reached" "next implement #61
exit 0" "$(next "$repo" --ran "59" --max 2)"
check "next: count of one" "stop count-reached: 1 ticket ran, the 1 --loop asked for
exit 2" "$(next "$repo" --ran "#59" --max 1)"
echo x >"$repo/x.txt"
check "next: an earlier stop comes before the count" "stop not-landed: 1 uncommitted path in $repo
exit 2" "$(next "$repo" --ran "59 60" --max 2)"
command rm -f "$repo/x.txt"

# With --max and no --dir, next.sh only checks the count, before any launch.
count() { out=$(sh "$scripts/next.sh" --max "$1" </dev/null 2>&1); printf '%s\nexit %s' "$out" "$?"; }
check "next: a valid count alone" "count 2
exit 0" "$(count 2)"
for bad in 0 -1 two 1.5 '' 02x; do
    check "next: count '$bad' refused" "Error: --max needs a positive integer, not '$bad'
exit 1" "$(count "$bad")"
done
check "next: a bad count refused with --dir too" "Error: --max needs a positive integer, not '0'
exit 1" "$(next "$repo" --max 0)"

mkdir -p "$work/plain"
check "next: not a checkout" "Error: $work/plain is not a git checkout
exit 1" "$(next "$work/plain")"

echo "supervise-next: $pass passed, $fail failed"
[ "$fail" = 0 ]
