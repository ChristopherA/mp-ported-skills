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
# no tmux session. Removes the session, the folder and the tmux server. It
# needs `claude`, tmux and two model calls; without either command it prints
# SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not). Default claude-sonnet-5.
#
# Usage: sh tests/live/supervise-watch.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
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

unset TMUX TMUX_PANE MP_VIEW_WAIT
tmp=$(mktemp -d)
export TMUX_TMPDIR="$tmp"
scratch="$root/.live-watch-$$"
mkdir -p "$scratch"
token="watch-live-$$-$(date +%s)"

windows() { tmux list-windows -t =mp-supervise -F '#{window_name}' 2>/dev/null; }
live_here() { # background sessions in the scratch folder that are not stopped
    claude agents --json --all </dev/null 2>/dev/null |
        jq -r --arg d "$scratch" '[.[] | select(.kind == "background" and .cwd == $d and .state != "stopped") | .id] | join(" ")'
}

out=$(cd "$scratch" && claude --bg --model "${MP_LIVE_MODEL:-claude-sonnet-5}" --permission-mode auto \
    "Test $token. Use no tools. Reply with only OK." </dev/null 2>&1)
id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)$/\1/p' | head -n 1)
if [ -z "$id" ]; then
    printf 'FAIL launch: claude --bg printed no session id:\n%s\n' "$out"
    command rm -rf "$scratch" "$tmp"
    exit 1
fi
echo "launched $id"
cleanup() {
    tmux kill-server >/dev/null 2>&1
    for s in $id $(live_here); do
        claude stop "$s" </dev/null >/dev/null 2>&1
        claude rm "$s" </dev/null >/dev/null 2>&1
    done
    # resume.sh writes the worker's marker in the repo holding the scratch
    # folder, which is this checkout; release it so this checkout is not
    # left read-only.
    sh "$scripts/release.sh" --dir "$scratch" --id "$id" </dev/null >/dev/null 2>&1
    command rm -rf "$scratch" "$tmp"
}

opened=$(sh "$scripts/view.sh" --id "$id" --dir "$scratch" </dev/null 2>&1)
check "launch: view.sh opens a viewer" "viewer mp-supervise:$id runs claude attach $id" \
    "$(printf '%s\n' "$opened" | head -n 1)"
check "launch: one window" "$id" "$(windows)"
check "launch: the window's command is claude attach" yes \
    "$(tmux list-panes -t "=mp-supervise:$id" -F '#{pane_start_command}' 2>/dev/null | grep -q "attach $id" && echo yes || echo no)"

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
check "resume: view.sh opens the viewer again" "viewer mp-supervise:$id runs claude attach $id" \
    "$(printf '%s\n' "$reopened" | head -n 1)"
second=$(sh "$scripts/watch.sh" --id "$id" --dir "$scratch" --after "$after" --interval 5 --timeout 300 </dev/null)
check "the follow-up turn ends" done "$(printf '%s\n' "$second" | head -n 1)"
check "one worker in the folder, not a copy" "$id" "$(live_here)"

claude stop "$id" </dev/null >/dev/null 2>&1
n=0
while [ -n "$(windows)" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
check "stop: the viewer's window closed" "" "$(windows)"
sh "$scripts/view.sh" --close </dev/null >/dev/null 2>&1
check "cleanup: no tmux session left" 1 "$(tmux has-session -t =mp-supervise 2>/dev/null; echo $?)"

cleanup
echo "supervise-watch live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
