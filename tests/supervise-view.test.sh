#!/bin/sh
# supervise-view.test.sh -- tests for the supervise skill's view.sh, which
# opens a tmux window running `claude attach <id>` for `--watch tmux` (#68).
#
# Runs real tmux on a private server: TMUX_TMPDIR points into the mktemp
# directory, so the test never touches the maintainer's tmux sessions. A fake
# `claude` stands in for `claude attach`: it records its arguments, working
# directory and CLAUDE_CONFIG_DIR, writes its pid, and sleeps until killed,
# as a viewer does until its worker is stopped. Killing it is the stop.
# Without tmux it prints SKIP and exits 0. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/supervise-view.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"

if ! command -v tmux >/dev/null 2>&1; then
    echo "supervise-view: SKIP (tmux is not on PATH)"
    exit 0
fi

work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Every variable the script reads, set or unset here. TMUX is unset so a run
# from inside the maintainer's tmux does not reach their server.
unset TMUX TMUX_PANE MP_VIEW_WAIT
export TMUX_TMPDIR="$work/tmux"
mkdir -p "$TMUX_TMPDIR"
export CLAUDE_CONFIG_DIR="$work/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
trap 'tmux kill-server >/dev/null 2>&1; command rm -rf "$work"' EXIT

fake="$work/fake"
mkdir -p "$work/bin" "$fake"
cat >"$work/bin/claude" <<EOF
#!/bin/sh
[ "\${1:-}" = attach ] || { echo "fake claude: unexpected \$*" >&2; exit 2; }
[ -f "$fake/attach-fails" ] && exit 1
echo "\$* | \$(pwd -P) | \${CLAUDE_CONFIG_DIR:-unset}" >>"$fake/calls"
echo \$\$ >"$fake/pid-\$2"
exec sleep 600
EOF
chmod +x "$work/bin/claude"
PATH="$work/bin:$PATH"
export PATH
[ "$(command -v claude)" = "$work/bin/claude" ] || { echo "FAIL the fake claude is not first on PATH"; exit 1; }

project="$work/project"
mkdir -p "$project"
view() { sh "$scripts/view.sh" "$@" </dev/null 2>&1; }
windows() { tmux list-windows -t "=${1:-$S}" -F '#{window_name}' 2>/dev/null; }
alive() { tmux has-session -t "=$1" 2>/dev/null; echo $?; }
stop_worker() { # <id>: the fake viewer exits, as claude attach does when its worker is stopped
    kill "$(command cat "$fake/pid-$1")" 2>/dev/null
    n=0
    while [ -n "$(windows | grep -x "$1")" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
export MP_VIEW_WAIT=1
# session_of <id> <view.sh output>: the session its viewer line names.
session_of() { printf '%s\n' "$2" | sed -n "s/^viewer \\(.*\\):$1 runs claude attach $1\$/\\1/p"; }
# folder_named <session>: yes when it is named for a folder `project`.
folder_named() {
    case $1 in
        mp-supervise-project-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) echo yes ;;
        *) echo "no: '$1'" ;;
    esac
}

# --- open ------------------------------------------------------------------
out=$(view --id c2a368ee --dir "$project")
rc=$?
check "open: exit 0" 0 "$rc"
# The session is named for the Project folder: its name, then a short hash
# of its full path, so two Projects never share one.
S=$(session_of c2a368ee "$out")
check "open: the session is named for the Project folder" yes "$(folder_named "$S")"
check "open: names the window and the watch command" "viewer $S:c2a368ee runs claude attach c2a368ee
watch: tmux attach -t $S (in iTerm2: tmux -CC attach -t $S)" "$out"
check "open: one window, named for the worker" c2a368ee "$(windows)"
check "open: the window's own command is claude attach, in the folder, under this profile" \
    "attach c2a368ee | $project | $CLAUDE_CONFIG_DIR" "$(command cat "$fake/calls")"

# A user's tmux.conf may keep dead panes; the viewer's window closes anyway.
tmux set-option -g remain-on-exit on
stop_worker c2a368ee
check "stop: the window closes by itself" "" "$(windows)"
check "stop: the last window closing ends the tmux session" 1 "$(alive "$S")"
sleep 1
check "stop: nothing re-attaches" 1 "$(grep -c '' "$fake/calls")"

# A resume opens a viewer again: one window, the same worker.
view --id c2a368ee --dir "$project" >/dev/null
check "resume: a new window for the same worker" c2a368ee "$(windows)"
check "resume: one attach per open" 2 "$(grep -c '' "$fake/calls")"

# Opening again while a window for the worker is open replaces it.
view --id c2a368ee --dir "$project" >/dev/null
check "reopen: still one window" c2a368ee "$(windows)"

# A second worker gets its own window in the same session.
view --id 5b8e1f04 --dir "$project" >/dev/null
check "second worker: its own window" "c2a368ee
5b8e1f04" "$(windows)"

# --- two Projects ----------------------------------------------------------
# Another supervisor's Project, with the same folder name: its viewer goes in
# a session of its own, and each run's cleanup leaves the other's open.
other="$work/other/project"
mkdir -p "$other"
out=$(view --id 9d0c7a31 --dir "$other")
O=$(session_of 9d0c7a31 "$out")
check "two Projects: the other is named for its folder too" yes "$(folder_named "$O")"
check "two Projects: a session each" yes "$([ "$O" != "$S" ] && echo yes || echo no)"
check "two Projects: the other's window is in its own session" 9d0c7a31 "$(windows "$O")"
check "two Projects: this one's windows are untouched" "c2a368ee
5b8e1f04" "$(windows)"

# --- close -----------------------------------------------------------------
check "close: removes this Project's session" "closed $S" "$(view --close --dir "$project")"
check "close: no tmux session left for it" 1 "$(alive "$S")"
check "close: the other Project's viewer stays open" 9d0c7a31 "$(windows "$O")"
check "close: none to remove" "no tmux session $S" "$(view --close --dir "$project")"
check "close: the other closes by its folder" "closed $O" "$(view --close --dir "$other")"
check "close: none left for the other" 1 "$(alive "$O")"
out=$(view --close); rc=$?
check "close: with no folder, exit 1" 1 "$rc"
check "close: with no folder, says so" "Error: --close needs --dir, --session or --pane" "$out"

out=$(view --id c2a368ee --dir "$project" --session watch-x)
check "session: a chosen name" "viewer watch-x:c2a368ee runs claude attach c2a368ee
watch: tmux attach -t watch-x (in iTerm2: tmux -CC attach -t watch-x)" "$out"
check "session: close by name" "closed watch-x" "$(view --close --session watch-x)"

# --- failures --------------------------------------------------------------
touch "$fake/attach-fails"
out=$(view --id c2a368ee --dir "$project")
rc=$?
check "attach fails: exit 1" 1 "$rc"
check "attach fails: says so" "Error: claude attach c2a368ee exited at once, so no viewer is open; watch with claude attach c2a368ee" "$out"
check "attach fails: no session left" 1 "$(alive "$S")"
command rm -f "$fake/attach-fails"

out=$(view --id 'c2a368ee;x' --dir "$project"); rc=$?
check "bad id: exit 1" 1 "$rc"
check "bad id: says so" "Error: --id needs a session id, not 'c2a368ee;x'" "$out"
out=$(view --id c2a368ee --dir "$project" --session 'a:b'); rc=$?
check "bad session name: exit 1" 1 "$rc"
check "bad session name: says so" "Error: --session takes letters, digits, - and _, not 'a:b'" "$out"
out=$(view --id c2a368ee); rc=$?
check "no dir: exit 1" 1 "$rc"
out=$( (PATH=/usr/bin:/bin; export PATH; sh "$scripts/view.sh" --id c2a368ee --dir "$project" </dev/null 2>&1) )
rc=$?
check "no tmux: exit 1" 1 "$rc"
check "no tmux: says so" "Error: tmux is not on PATH, so no viewer can open; watch with claude attach c2a368ee" "$out"

# --- the --watch argument --------------------------------------------------
# SKILL.md, not a script, reads /supervise's arguments: it refuses any
# --watch value but the two it handles, naming both (#95).
skill="$root/plugins/mp-ported-skills/skills/supervise/SKILL.md"
check "--watch: SKILL.md refuses another value, naming tmux and iterm" 1 \
    "$(grep -cF "reply with one line, \`Error: --watch takes tmux or iterm, not '<value>'\`" "$skill")"
check "--watch: the refusal launches nothing" 1 \
    "$(grep -c '^`--watch` takes `tmux` or `iterm` and nothing else\. Given any other value, or none, stop before any step, launch nothing' "$skill")"

echo "supervise-view: $pass passed, $fail failed"
[ "$fail" = 0 ]
