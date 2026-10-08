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
unset CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID MP_SMART_ZONE_K \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true
export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx"
mkdir -p "$WORKSTREAM_KIT_CONTEXT_DIR"

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
check "next: count reached" "stop count-reached: 2 tickets ran, the most --loop 2 allows
exit 2" "$(next "$repo" --ran "59 60" --max 2)"
check "next: count not yet reached" "next implement #61
exit 0" "$(next "$repo" --ran "59" --max 2)"
check "next: count of one" "stop count-reached: 1 ticket ran, the most --loop 1 allows
exit 2" "$(next "$repo" --ran "#59" --max 1)"
echo x >"$repo/x.txt"
check "next: an earlier stop comes before the count" "stop not-landed: 1 uncommitted path in $repo
exit 2" "$(next "$repo" --ran "59 60" --max 2)"
command rm -f "$repo/x.txt"

# With --max and no --dir, next.sh only checks the count, before any launch.
count_only() { out=$(sh "$scripts/next.sh" --max "$1" </dev/null 2>&1); printf '%s\nexit %s' "$out" "$?"; }
check "next: a valid count alone" "count 2
exit 0" "$(count_only 2)"
check "next: a count with a leading zero" "count 2
exit 0" "$(count_only 02)"
for bad in 0 00 -1 two 1.5 '' 02x; do
    check "next: count '$bad' refused" "Error: --max needs a positive integer, not '$bad'
exit 1" "$(count_only "$bad")"
done
check "next: a bad count refused with --dir too" "Error: --max needs a positive integer, not '0'
exit 1" "$(next "$repo" --max 0)"

# Run from a plugin cache, next.sh names the scripts the next ticket launches
# with: the newest installed version's, which a worker's push and plugin
# update may have put beside the loaded one (#169).
repo=$(new_repo cached)
state "2 /implement #61 ($you): #61 t61"
cache="$work/cache/mp-ported-skills/mp-ported-skills"
for v in 0.8.64 0.8.9 0.8.68; do
    mkdir -p "$cache/$v"
    command cp -R "$root/plugins/mp-ported-skills/." "$cache/$v/"
done
mkdir -p "$cache/latest/skills/supervise/scripts"
from_cache() { # <version> [args...] -- the cached next.sh's output, then `exit N`
    v=$1; shift
    out=$(sh "$cache/$v/skills/supervise/scripts/next.sh" --dir "$repo" "$@" --from "$work/state.txt" </dev/null 2>&1)
    printf '%s\nexit %s' "$out" "$?"
}
new="$cache/0.8.68/skills/supervise/scripts"
printf '#!/bin/sh\necho "implement #99"\n' >"$new/step.sh"
check "next: a newer version installed in the cache" "scripts 0.8.68 $new (newer than the loaded 0.8.64; use it for the rest of the loop)
next implement #99
exit 0" "$(from_cache 0.8.64)"
check "next: the newest version is the loaded one" "scripts 0.8.68 $new
next implement #99
exit 0" "$(from_cache 0.8.68)"
check "next: 0.8.9 sorts below 0.8.68" "scripts 0.8.68 $new (newer than the loaded 0.8.9; use it for the rest of the loop)
next implement #99
exit 0" "$(from_cache 0.8.9)"
check "next: a stop names no scripts" "stop repeat: #99 ran earlier in this loop and state.sh still recommends it; was its work committed with Closes #99?
exit 2" "$(from_cache 0.8.64 --ran 99)"
mkdir -p "$cache/0.8.70"
command cp -R "$root/plugins/mp-ported-skills/." "$cache/0.8.70/"
touch "$cache/0.8.70/.orphaned_at"
check "next: a newer folder the cache orphaned is passed over" "scripts 0.8.68 $new (newer than the loaded 0.8.64; use it for the rest of the loop)
next implement #99
exit 0" "$(from_cache 0.8.64)"
command rm -rf "$cache/0.8.68" "$cache/0.8.70"
touch "$cache/0.8.64/.orphaned_at"
check "next: no newer version, the loaded scripts, orphaned or not" "scripts 0.8.64 $cache/0.8.64/skills/supervise/scripts
next implement #61
exit 0" "$(from_cache 0.8.64)"

# The supervisor's own zone reading stops the loop before its next ticket
# (#78), read from the status line's record for its session and folder.
sup="$work/sup"; mkdir -p "$sup"
zrec() { # <session> <tokens> <window % remaining>
    printf '{"session_id":"%s","project_dir":"%s","tokens":%s,"remaining_pct":%s,"updated":"2026-01-01T00:00:00Z"}\n' \
        "$1" "$sup" "$2" "$3" >"$WORKSTREAM_KIT_CONTEXT_DIR/claude-$1-zone.json"
}
repo=$(new_repo zone)
state "2 /implement #61 ($you): #61 t61"
zrec z92 138000 86
check "next: the supervisor at 92% of zone stops the loop" "stop zone: the supervisor's reading is 92% of zone, at or past the 90% the loop stops at, so it starts no more tickets
exit 2" "$(next "$repo" --session z92 --session-dir "$sup")"
zrec z89 133500 86
check "next: the supervisor below the zone stop goes on" "next implement #61
exit 0" "$(next "$repo" --session z89 --session-dir "$sup")"
check "next: the session's id from the environment when --session is empty" "stop zone: the supervisor's reading is 92% of zone, at or past the 90% the loop stops at, so it starts no more tickets
exit 2" "$(export CLAUDE_CODE_SESSION_ID=z92; next "$repo" --session "" --session-dir "$sup")"
check "next: no reading for the session goes on, with a note" "note: no zone reading for session z00 in $sup, so the loop goes on without its zone stop
next implement #61
exit 0" "$(next "$repo" --session z00 --session-dir "$sup")"
check "next: no session id goes on, with a note" "note: no session id, so the loop goes on without its zone stop
next implement #61
exit 0" "$(next "$repo" --session "" --session-dir "$sup")"
check "next: without --session, no zone stop" "next implement #61
exit 0" "$(next "$repo")"
zrec z95 142500 85
echo x >"$repo/x.txt"
check "next: a landing stop comes before the zone" "stop not-landed: 1 uncommitted path in $repo
exit 2" "$(next "$repo" --session z95 --session-dir "$sup")"
command rm -f "$repo/x.txt"
check "next: a reached count comes before the zone" "stop count-reached: 1 ticket ran, the most --loop 1 allows
exit 2" "$(next "$repo" --ran 59 --max 1 --session z95 --session-dir "$sup")"

# The zone stop must sit below the session's auto-compact point, or the
# session compacts, and loses the loop, before the stop is read. The point
# is a share of the window, so it is read in zone units from the record.
# A 200k window at 60% of zone has 45% of it used: compacting at 60% of the
# window is 80% of zone, below the stop.
zrec w200 90000 55
check "next: a stop at or above the auto-compact point is refused" "Error: the loop's zone stop, 90% of zone, is at or above this session's auto-compact point, about 80% of zone (60% of its window), so it would compact before the loop stopped
exit 1" "$(export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; next "$repo" --session w200 --session-dir "$sup")"
check "next: a 200k window compacting at 80% is above the stop" "next implement #61
exit 0" "$(export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80; next "$repo" --session w200 --session-dir "$sup")"
check "next: no override reads Claude Code's 80%" "next implement #61
exit 0" "$(next "$repo" --session w200 --session-dir "$sup")"
# A reading early in a session gives too coarse a window to refuse on.
zrec early 3000 98
check "next: an early reading is not refused" "next implement #61
exit 0" "$(export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; next "$repo" --session early --session-dir "$sup")"

# The stop itself sits below the auto-compact point of the smallest window a
# supervisor runs on, 200k tokens, at the 80% this profile and Claude Code's
# status line read by default, against the default 150k zone: 106% of zone.
stop=$(sed -n 's/^ZONE_STOP=\([0-9][0-9]*\).*/\1/p' "$scripts/next.sh")
if [ -n "$stop" ] && [ $((stop * 150)) -lt $((80 * 200)) ]; then below=yes; else below="no (ZONE_STOP=$stop)"; fi
check "next: the zone stop is below a 200k window's auto-compact point" yes "$below"

mkdir -p "$work/plain"
check "next: not a checkout" "Error: $work/plain is not a git checkout
exit 1" "$(next "$work/plain")"

echo "supervise-next: $pass passed, $fail failed"
[ "$fail" = 0 ]
