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
# line per step. A step that cannot run because an earlier one failed is
# not printed. Removes every session it started, a copy included, and the
# scratch folder, on any exit. It needs `claude`, `jq` and two model calls;
# without `claude` it prints SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not). Default claude-sonnet-5. MP_LIVE_TIMEOUT bounds each wait,
# default 300 seconds.
#
# Usage: sh tests/live/background-cli.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)

if ! command -v claude >/dev/null 2>&1; then
    echo "background-cli live: SKIP (claude is not on PATH)"
    exit 0
fi

timeout=${MP_LIVE_TIMEOUT:-300}
interval=5
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { # <step> [detail]
    fail=$((fail + 1))
    echo "FAIL $1"
    [ $# -lt 2 ] || printf '  %s\n' "$2"
}
finish() {
    echo "background-cli live: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] && exit 0 || exit 1
}

echo "claude version: $(claude --version </dev/null 2>&1)"

scratch="$root/.live-background-cli-$$"
token="background-cli-$$-$(date +%s)"
created=""
cleanup() {
    for c in $created; do
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

# wait_state <state>: poll until the session's state is STATE, or TIMEOUT
# passes. Leaves the last state read in $last.
wait_state() {
    begin=$(date +%s)
    while :; do
        last=$(row state)
        [ "$last" = "$1" ] && return 0
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
    bad "claude --bg launches a session and prints its id" "it printed: $out"
    finish
fi
created=$id
ok "claude --bg launches a session and prints its id ($id)"

sid=$(row sessionId)
case $sid in
    gone | error | null) bad "claude agents --json lists the session with its session id" "read: $sid"; finish ;;
esac
ok "claude agents --json lists the session with its session id ($sid)"

if wait_state done; then
    ok "the session's turn ends with state done"
else
    bad "the session's turn ends with state done" "last state after ${timeout}s: $last"
    finish
fi

if out=$(claude stop "$id" </dev/null 2>&1); then
    ok "claude stop exits 0"
else
    bad "claude stop exits 0" "it printed: $out"
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
    if [ "$last" = stopped ]; then
        safe="state stopped"
        break
    elif [ "$(row pid)" = null ] && [ "$last" != gone ] && [ "$last" != error ]; then
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
    ok "the stopped session is safe to resume: $safe"
else
    bad "the stopped session is safe to resume" "last state after ${timeout}s: $last, pid: $(row pid)"
    finish
fi

out=$(cd "$scratch" && claude --bg --resume "$sid" "Test $token, resumed. Use no tools. Reply with only OK." </dev/null 2>&1)
copy=$(printf '%s\n' "$out" | sed -n 's/.*started a copy as \([0-9a-f][0-9a-f]*\).*/\1/p' | head -n 1)
if [ -n "$copy" ]; then
    created="$created $copy"
    bad "claude --bg --resume wakes the original" "it started a copy as $copy: $out"
    finish
elif printf '%s\n' "$out" | grep -Eq "woke session $id([^0-9a-f]|$)"; then
    ok "claude --bg --resume wakes the original"
else
    bad "claude --bg --resume wakes the original" "it printed neither a wake nor a copy: $out"
    finish
fi

if wait_state done; then
    ok "the resumed turn ends with state done"
else
    bad "the resumed turn ends with state done" "last state after ${timeout}s: $last"
fi

now=$(row sessionId)
if [ "$now" = "$sid" ]; then
    ok "the resumed session keeps its session id"
else
    bad "the resumed session keeps its session id" "expected $sid, read $now"
fi

finish
