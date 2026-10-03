#!/bin/sh
# background-cli.sh -- live smoke test of the Claude Code background-session
# commands /supervise depends on (ADR 0003). Run it after each Claude Code
# update: the tests in tests/ use recorded `claude agents --json` output and a
# stubbed `claude`, so they do not catch a change in the real CLI.
#
# Drives the plain CLI, not supervise's scripts, through the stop-and-resume
# sequence resume.sh relies on: launches a no-op `claude --bg` session in a
# scratch folder inside this checkout (which needs no trust step), reads it
# from `claude agents --json --all`, waits for its turn to end, stops it,
# waits for `stopped` (or, as resume.sh does, for its row to show no pid for
# 60 seconds), resumes it with `claude --bg --resume <session id>` and no
# flags, and checks that the resume woke the original under the same
# session id rather than starting a copy.
#
# Prints the Claude Code version, then one `PASS <step>` or `FAIL <step>`
# line per step, and `SKIP <step>` for each step an earlier failure left
# unrun. Removes every session it started, a copy included, and the scratch
# folder, on any exit: those it read an id for, and any other background
# session in the scratch folder, so a launch or resume line it cannot parse
# leaves nothing behind. It needs `claude`, `jq` and two model calls; without
# either command it prints SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not). Default claude-sonnet-5. MP_LIVE_TIMEOUT bounds each wait,
# default 300 seconds.
#
# Usage: sh tests/live/background-cli.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)

for c in claude jq; do
    if ! command -v "$c" >/dev/null 2>&1; then
        echo "background-cli live: SKIP ($c is not on PATH)"
        exit 0
    fi
done

timeout=${MP_LIVE_TIMEOUT:-300}
interval=5
pass=0 fail=0 skip=0
# step <n>: the name of step N, so finish can print the steps left unrun.
steps=8
step() {
    case $1 in
        1) echo "claude --bg launches a session and prints its id" ;;
        2) echo "claude agents --json lists the session with its session id" ;;
        3) echo "the session's turn ends with state done" ;;
        4) echo "claude stop exits 0" ;;
        5) echo "the stopped session is safe to resume" ;;
        6) echo "claude --bg --resume wakes the original" ;;
        7) echo "the resumed turn ends with state done" ;;
        8) echo "the resumed session keeps its session id, with no other session started" ;;
    esac
}
done_steps=0
ok() { # <n> [detail]
    pass=$((pass + 1)); done_steps=$1
    echo "PASS $(step "$1")${2:+: $2}"
}
bad() { # <n> [detail]
    fail=$((fail + 1)); done_steps=$1
    echo "FAIL $(step "$1")"
    [ $# -lt 2 ] || printf '  %s\n' "$2"
}
finish() {
    while [ "$done_steps" -lt "$steps" ]; do
        done_steps=$((done_steps + 1)); skip=$((skip + 1))
        echo "SKIP $(step "$done_steps")"
    done
    echo "background-cli live: $pass passed, $fail failed, $skip skipped"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
}

echo "claude version: $(claude --version </dev/null 2>&1)"

scratch="$root/.live-background-cli-$$"
token="background-cli-$$-$(date +%s)"
created=""
removed=""
# in_scratch: the ids of every background session whose cwd is the scratch
# folder, which only this run uses.
in_scratch() {
    claude agents --json --all </dev/null 2>/dev/null |
        jq -r --arg d "$scratch" '.[] | select(.kind == "background" and .cwd == $d) | .id' 2>/dev/null
}
cleanup() {
    for c in $created $(in_scratch); do
        case " $removed " in *" $c "*) continue ;; esac
        removed="$removed $c"
        claude stop "$c" </dev/null >/dev/null 2>&1
        claude rm "$c" </dev/null >/dev/null 2>&1 ||
            echo "note: claude rm $c failed; remove it with claude rm $c"
    done
    command rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$scratch"

# row <field>: the session's field in `claude agents --json --all`, `gone`
# when it has no row, or `error` when the list cannot be read.
row() {
    claude agents --json --all </dev/null 2>/dev/null | jq -er --arg id "$id" --arg f "$1" '
        ([.[] | select(.kind == "background" and .id == $id)] | first) as $r
        | if $r == null then "gone" else ($r[$f] // "null" | tostring) end' 2>/dev/null ||
        echo error
}

# wait_state <state>: poll until the session's state is STATE, or fail when
# its row is gone or TIMEOUT passes. Leaves the last state read in $last.
wait_state() {
    begin=$(date +%s)
    while :; do
        last=$(row state)
        [ "$last" = "$1" ] && return 0
        [ "$last" != gone ] || return 1
        [ $(($(date +%s) - begin)) -lt "$timeout" ] || return 1
        sleep "$interval"
    done
}

out=$(cd "$scratch" && claude --bg --model "${MP_LIVE_MODEL:-claude-sonnet-5}" --permission-mode auto \
    "Test $token. Use no tools. Reply with only OK." </dev/null 2>&1)
# Each output is read as the supervise script that reads it does: this
# launch line as launch.sh reads it, past color (FORCE_COLOR colors the id)
# and a ` · <name>` tail, and the resume line below as resume.sh reads it.
esc=$(printf '\033')
id=$(printf '%s\n' "$out" | sed "s/$esc\[[0-9;]*m//g" |
    sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)\( · .*\)\{0,1\}$/\1/p' | head -n 1)
if [ -z "$id" ]; then
    bad 1 "it printed: $out"
    finish
fi
created=$id
ok 1 "$id"

sid=$(row sessionId)
case $sid in
    gone | error | null) bad 2 "read: $sid"; finish ;;
esac
ok 2 "$sid"

if wait_state done; then
    ok 3
else
    bad 3 "last state read: $last"
    finish
fi

if out=$(claude stop "$id" </dev/null 2>&1); then
    ok 4
else
    bad 4 "it printed: $out"
    finish
fi

# Safe to resume, by resume.sh's rule: the row shows `stopped`, or has shown
# no pid for SETTLE seconds, since `stopped` does not always show (on 2.1.288
# a stopped session stayed `done` with no pid). The step names which it saw.
settle=60
begin=$(date +%s)
since=""
safe=""
while :; do
    last=$(row state)
    now=$(date +%s)
    if [ "$last" = gone ]; then
        break
    elif [ "$last" = stopped ]; then
        safe="state stopped"
        break
    elif [ "$last" != error ] && [ "$(row pid)" = null ]; then
        [ -n "$since" ] || since=$now
        if [ $((now - since)) -ge "$settle" ]; then
            safe="no pid for ${settle}s, with state $last (stopped never showed)"
            break
        fi
    else
        since=""
    fi
    [ $((now - begin)) -lt "$timeout" ] || break
    sleep "$interval"
done
if [ -n "$safe" ]; then
    ok 5 "$safe"
else
    bad 5 "last state read: $last, pid: $(row pid)"
    finish
fi

out=$(cd "$scratch" && claude --bg --resume "$sid" "Test $token, resumed. Use no tools. Reply with only OK." </dev/null 2>&1)
copy=$(printf '%s\n' "$out" | sed -n 's/.*started a copy as \([0-9a-f][0-9a-f]*\).*/\1/p' | head -n 1)
if [ -n "$copy" ]; then
    created="$created $copy"
    bad 6 "it started a copy as $copy: $out"
    finish
elif printf '%s\n' "$out" | grep -Eq "woke session $id([^0-9a-f]|$)"; then
    ok 6
else
    bad 6 "it printed neither a wake nor a copy: $out"
    finish
fi

if wait_state done; then
    ok 7
else
    bad 7 "last state read: $last"
fi

# A resume that started a copy under an unrecognized line would show here as
# a second background session in the scratch folder.
resumed_sid=$(row sessionId)
others=$(in_scratch | grep -vx "$id" | tr '\n' ' ')
if [ "$resumed_sid" = "$sid" ] && [ -z "$others" ]; then
    ok 8
else
    bad 8 "session id $resumed_sid (launched as $sid); other sessions in the scratch folder: ${others:-none}"
fi

finish
