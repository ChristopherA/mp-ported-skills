#!/bin/sh
# supervise-helpers.test.sh -- tests for the supervise skill's shared
# helpers: marker.sh (the checkout's worker marker) and settle.sh (stop a
# worker and wait until it has settled) (#137).
#
# Sources each helper and runs its function against a scratch repo and a
# fake `claude` first on PATH. The fake logs each call and answers
# `agents --json --all` with the next of the lists agents.1, agents.2, ...
# in its folder, staying on the last, and fails when FAKE_AGENTS_FAIL is
# set. With each list N it writes roster.N, when there is one, as the
# daemon's roster file, so the roster changes with the list. Touches
# nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-helpers.test.sh

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

unset FAKE_AGENTS_FAIL CLAUDE_CODE_SESSION_ATTENDED MP_SESSION_TITLE

# --- fake claude -----------------------------------------------------------
mkdir -p "$work/bin" "$work/lists"
cat >"$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/claude-calls"
case "\$*" in
    "agents --json --all")
        [ -z "\${FAKE_AGENTS_FAIL:-}" ] || exit 1
        n=\$(command cat "$work/count" 2>/dev/null || echo 0)
        n=\$((n + 1))
        [ -f "$work/lists/agents.\$n" ] || n=\$((n - 1))
        echo "\$n" >"$work/count"
        [ ! -f "$work/lists/roster.\$n" ] || command cp -f "$work/lists/roster.\$n" "$work/roster.json"
        command cat "$work/lists/agents.\$n" ;;
    stop\ *) ;;
    *) echo "fake claude: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/claude"
PATH="$work/bin:$PATH"
[ "$(command -v claude)" = "$work/bin/claude" ] || {
    echo "FAIL the fake claude is not the one found; not running the rest"
    exit 1
}

# lists <json>...: the lists the fake answers, in order.
lists() {
    command rm -f "$work"/lists/agents.* "$work"/lists/roster.* "$work/roster.json" "$work/count" "$work/claude-calls"
    i=0
    for l in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$l" >"$work/lists/agents.$i"
    done
}
# rosters <json>...: the roster files written with lists 1, 2, ..., in order.
rosters() {
    i=0
    for r in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$r" >"$work/lists/roster.$i"
    done
}
held='{"workers":{"c2a368ee":{"pid":202}}}'
freed='{"workers":{"0ca7d123":{"pid":303}}}'
row() { printf '[{"kind":"background","id":"c2a368ee","state":"%s","pid":%s}]' "$1" "$2"; }

# --- marker.sh -------------------------------------------------------------
. "$scripts/marker.sh"

git init -q "$work/repo"
repo=$(CDPATH= cd -- "$work/repo" && pwd -P)
check "marker_path names the checkout's git dir" "$repo/.git/mp-supervise-worker" "$(marker_path "$repo")"
mkdir "$work/repo/sub"
check "marker_path from a folder inside the checkout" "$repo/.git/mp-supervise-worker" "$(marker_path "$repo/sub")"
mkdir "$work/plain"
out=$(marker_path "$work/plain" 2>/dev/null); rc=$?
check "marker_path outside a checkout fails" "1 " "$([ "$rc" -ne 0 ] && echo 1) $out"
err=$(marker_path "$work/plain" 2>&1 >/dev/null)
check "marker_path leaves git's error on stderr for the caller" "yes" "$([ -n "$err" ] && echo yes)"

# --- settle.sh -------------------------------------------------------------
. "$scripts/settle.sh"

lists "$(row running 101)" "$(row stopped null)"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "stopped ends the wait" "0 stopped" "$rc $out"
check "the stop comes before the first read" "stop c2a368ee" "$(head -n 1 "$work/claude-calls")"

lists '[]'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "a session no longer listed is gone" "0 gone" "$rc $out"

lists "$(row done null)"
out=$(stop_and_settle c2a368ee 0 0 300 settle_row); rc=$?
check "no pid for the settle time reads as stopped" "0 stopped" "$rc $out"

# A pid showing again starts the settle time over: with a 1-second settle,
# nopid, pid, nopid, nopid... ends only after the pid, so at least two reads
# follow it.
lists "$(row done null)" "$(row running 101)" "$(row done null)"
out=$(stop_and_settle c2a368ee 1 1 300 settle_row); rc=$?
reads=$(grep -c '^agents' "$work/claude-calls")
check "a pid showing again restarts the settle time" "0 stopped yes" "$rc $out $([ "$reads" -ge 4 ] && echo yes)"

lists "$(row running 101)"
out=$(stop_and_settle c2a368ee 60 0 0 settle_row); rc=$?
check "a session not seen to stop times out" "1 session c2a368ee was not stopped 0s after claude stop" "$rc $out"

lists "$(row running 101)"
out=$(FAKE_AGENTS_FAIL=1; export FAKE_AGENTS_FAIL; stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "a failed agents read is reported" "1 claude agents --json --all failed, so session c2a368ee's state is unknown" "$rc $out"

lists 'not json'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "an unreadable list is reported" "1 claude agents --json --all printed no list jq could read, so session c2a368ee's state is unknown" "$rc $out"

# The daemon lets the job go a moment after `claude agents` shows it
# stopped, and a resume in that moment starts a copy (#185). So a session
# the roster still lists is not settled yet, whichever way it was read as
# stopped, and the wait goes on until the roster drops it.
lists "$(row stopped null)" "$(row stopped null)" "$(row stopped null)"
rosters "$held" "$held" "$freed"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "stopped waits until the roster drops the job" "0 stopped 3" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row done null)" "$(row done null)"
rosters "$held" "$freed"
out=$(stop_and_settle c2a368ee 0 0 300 settle_row "$work/roster.json"); rc=$?
check "the settle time's stopped waits for the roster too" "0 stopped 2" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row stopped null)"
rosters "$held"
out=$(stop_and_settle c2a368ee 60 0 0 settle_row "$work/roster.json"); rc=$?
check "a job the roster keeps is stopped at the timeout" "0 stopped" "$rc $out"

lists "$(row stopped null)" "$(row stopped null)"
rosters 'not json' "$freed"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "an unreadable roster is read again" "0 stopped 2" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row stopped null)"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "no roster file means no daemon holds the job" "0 stopped" "$rc $out"

lists "$(row stopped null)"
rosters '{"proto":1}'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "a roster with no workers holds no job" "0 stopped" "$rc $out"

lists "$(row stopped null)"
rosters '{"workers":[]}'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "a roster whose workers is no object holds no job" "0 stopped" "$rc $out"

# Only a stop waits for the roster: gone and a caller's own word end the
# wait as they did.
lists '[]'
rosters "$held"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "gone does not wait for the roster" "0 gone" "$rc $out"

# A caller's own verdict: any word but pid and nopid ends the wait with it.
mine() { echo "others somewhere"; }
lists "$(row running 101)"
out=$(stop_and_settle c2a368ee 60 0 300 mine); rc=$?
check "a caller's verdict word ends the wait" "0 others somewhere" "$rc $out"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
