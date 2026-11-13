#!/bin/sh
# supervise-watch.sh -- live check of supervise's view.sh (#68): a tmux
# viewer on a background worker closes when the worker is stopped, does not
# re-attach, and a stop followed by a resume leaves one worker, not a copy.
#
# Starts `claude --bg --permission-mode auto` in a scratch folder inside this
# checkout, opens its viewer with view.sh on a private tmux server
# (TMUX_TMPDIR in the scratch folder's parent temp dir), waits for its turn
# to end, then sends a follow-up through resume.sh, as /supervise does, and
# opens the viewer again. Checks the window ran `claude attach`, closed at
# the stop, that resume.sh woke the original, that one background session
# runs in the folder, and that stopping the worker and view.sh --close leave
# no tmux session. Removes the session, its marker in this checkout, the
# folder and the tmux server, at the end or when interrupted (INT, TERM). It
# needs `claude`, tmux and two model calls; without either command it prints
# SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not). Default claude-sonnet-5.
#
# Usage: sh tests/live/supervise-watch.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
. "$root/tests/live/session-id.sh"
. "$root/tests/live/worker-cleanup.sh"
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
. "$scripts/agents.sh"
: "${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR must be set, as watch.sh, resume.sh and view.sh read it}"

for c in claude tmux; do
    if ! command -v "$c" >/dev/null 2>&1; then
        echo "supervise-watch live: SKIP ($c is not on PATH)"
        exit 0
    fi
done

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# resume.sh and watch.sh run git; a worker-style session's 0 would make
# the git wrappers refuse what a real supervisor runs.
unset TMUX TMUX_PANE MP_VIEW_WAIT CLAUDE_CODE_SESSION_ATTENDED
tmp=$(mktemp -d)
export TMUX_TMPDIR="$tmp"
scratch="$root/.live-watch-$$"
token="watch-live-$$-$(date +%s)"
# view.sh names the session for the folder; read from its first line.
session=""

windows() { [ -n "$session" ] && tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null; }
live_here() { # background sessions in the scratch folder that are not stopped
    # Through agents_list, which kills a hung call: the cleanup trap runs
    # this, and a hang there would block an interrupted run's exit.
    agents_list 2>/dev/null |
        jq -r --arg d "$scratch" '[.[] | select(.kind == "background" and .cwd == $d and .state != "stopped") | .id] | join(" ")'
}
id=""
cleanup() {
    tmux kill-server >/dev/null 2>&1
    # shellcheck disable=SC2046
    [ -z "$id" ] || worker_cleanup_remove "$scripts" "$scratch" "$id" $(live_here)
    command rm -rf "$scratch" "$tmp"
}
worker_cleanup_trap cleanup
mkdir -p "$scratch"

out=$(cd "$scratch" && claude --bg --model "${MP_LIVE_MODEL:-claude-sonnet-5}" --permission-mode auto \
    "Test $token. Use no tools. Reply with only OK." </dev/null 2>&1)
id=$(bg_session_id "$out")
if [ -z "$id" ]; then
    printf 'FAIL launch: claude --bg printed no session id:\n%s\n' "$out"
    exit 1
fi
echo "launched $id"

opened=$(sh "$scripts/view.sh" --id "$id" --dir "$scratch" </dev/null 2>&1)
session=$(printf '%s\n' "$opened" | sed -n "s/^viewer \(mp-supervise-[A-Za-z0-9_-]*\):$id runs claude attach $id\$/\1/p")
check "launch: view.sh opens a viewer in a session named for the folder" yes \
    "$(case $session in mp-supervise--live-watch-$$-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) echo yes ;; *) echo "no: '$session'" ;; esac)"
check "launch: one window" "$id" "$(windows)"
check "launch: the window's command is claude attach" yes \
    "$(tmux list-panes -t "=$session:$id" -F '#{pane_start_command}' 2>/dev/null | grep -q "attach $id" && echo yes || echo no)"

first=$(sh "$scripts/watch.sh" --id "$id" --dir "$scratch" --interval 5 --timeout 300 </dev/null)
check "the first turn ends" done "$(printf '%s\n' "$first" | head -n 1)"

resumed=$(sh "$scripts/resume.sh" --id "$id" --dir "$scratch" \
    --prompt "Test $token. Reply with only AGAIN." </dev/null)
rc=$?
echo "$resumed"
check "resume.sh exits 0" 0 "$rc"
check "resume.sh woke the original, with no copy, with the viewer attached at the stop" "after <epoch>
resumed $id" "$(printf '%s\n' "$resumed" | sed 's/^after [0-9][0-9]*$/after <epoch>/')"
# The follow-up's watch passes the after time, so the turn that ended
# before the stop is not read as the follow-up's end (#122).
after=$(printf '%s\n' "$resumed" | sed -n 's/^after //p')
check "the stop closed the viewer, and nothing re-attached" "" "$(windows)"

reopened=$(sh "$scripts/view.sh" --id "$id" --dir "$scratch" </dev/null 2>&1)
check "resume: view.sh opens the viewer again" "viewer $session:$id runs claude attach $id" \
    "$(printf '%s\n' "$reopened" | head -n 1)"
second=$(sh "$scripts/watch.sh" --id "$id" --dir "$scratch" --after "$after" --interval 5 --timeout 300 </dev/null)
check "the follow-up turn ends" done "$(printf '%s\n' "$second" | head -n 1)"
check "one worker in the folder, not a copy" "$id" "$(live_here)"

claude stop "$id" </dev/null >/dev/null 2>&1
n=0
while [ -n "$(windows)" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
check "stop: the viewer's window closed" "" "$(windows)"
sh "$scripts/view.sh" --close --dir "$scratch" </dev/null >/dev/null 2>&1
check "cleanup: no tmux session left" 1 "$(tmux has-session -t "=$session" 2>/dev/null; echo $?)"

echo "supervise-watch live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
