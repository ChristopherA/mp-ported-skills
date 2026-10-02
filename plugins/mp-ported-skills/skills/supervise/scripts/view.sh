#!/bin/sh
# view.sh -- open a tmux window that shows a supervised worker, for
# `/supervise --watch tmux` (#68), or remove the tmux session that holds
# those windows.
#
# The window's own command is `claude attach <id>`, run with the profile's
# CLAUDE_CONFIG_DIR and claude's full path (a tmux server started earlier
# keeps its own environment), not a shell with the command typed into it. So
# when the supervisor stops the worker, the viewer exits and the window
# closes by itself, and when the last window closes, the tmux session ends.
# remain-on-exit is turned off on the window, so a tmux.conf that keeps dead
# panes does not keep it.
#
# It opens one window per call and never re-attaches. Attaching wakes a
# stopped session, so a viewer that re-attached between a stop and a resume
# would make the resume start a copy and split the worker (#55). The
# supervisor calls this once after launch.sh and once after each resume.sh
# that printed `resumed <id>`. A window already open for the same id is
# closed first, so a worker has one viewer at most.
#
# The viewer is live: what the maintainer types there reaches the worker as
# a prompt, and a permission prompt can be answered there.
#
# Usage:
#   view.sh --id ID --dir DIR [--session NAME]
#   view.sh --close [--session NAME]
#
# NAME defaults to mp-supervise. MP_VIEW_WAIT: seconds to wait before
# checking the viewer is still running (default 2); one that exits at once,
# as `claude attach` does for an id it cannot open, is reported and its
# window closed.
#
# Prints `viewer NAME:ID runs claude attach ID` and the command to watch it,
# or for --close `closed NAME` or `no tmux session NAME`. Exits 0 opened or
# closed; 1 not.

set -u

ID=""
DIR=""
SESSION="mp-supervise"
CLOSE=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)      need_value "$@"; ID="$2"; shift 2 ;;
        --dir)     need_value "$@"; DIR="$2"; shift 2 ;;
        --session) need_value "$@"; SESSION="$2"; shift 2 ;;
        --close)   CLOSE=1; shift ;;
        --help)
            printf 'Usage: view.sh --id ID --dir DIR [--session NAME]\n'
            printf '       view.sh --close [--session NAME]\n'
            printf 'Opens a tmux window running claude attach ID, or removes the tmux session. Outputs: the window and the watch command\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
case $SESSION in
    '' | *[!A-Za-z0-9_-]*) fail "--session takes letters, digits, - and _, not '$SESSION'" ;;
esac

if [ -n "$CLOSE" ]; then
    command -v tmux >/dev/null 2>&1 || { echo "no tmux session $SESSION"; exit 0; }
    if tmux has-session -t "=$SESSION" 2>/dev/null; then
        tmux kill-session -t "=$SESSION" || fail "tmux could not remove session $SESSION"
        echo "closed $SESSION"
    else
        echo "no tmux session $SESSION"
    fi
    exit 0
fi

case $ID in
    '' | *[!0-9a-f]*) fail "--id needs a session id, not '$ID'" ;;
esac
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
command -v tmux >/dev/null 2>&1 || fail "tmux is not on PATH, so no viewer can open; watch with claude attach $ID"
claude=$(command -v claude) || fail "claude is not on PATH, so no viewer can open"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the viewer's profile cannot be pinned"
wait=${MP_VIEW_WAIT:-2}

set -- env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" "$claude" attach "$ID"
if tmux has-session -t "=$SESSION" 2>/dev/null; then
    for w in $(tmux list-windows -t "=$SESSION" -F '#{window_id} #{window_name}' | sed -n "s/^\\(@[0-9]*\\) $ID\$/\\1/p"); do
        tmux kill-window -t "$w"
    done
fi
# The session may have ended with the window just closed.
if tmux has-session -t "=$SESSION" 2>/dev/null; then
    win=$(tmux new-window -d -P -F '#{window_id}' -t "=$SESSION:" -n "$ID" -c "$DIR" "$@") ||
        fail "tmux could not open a window in session $SESSION; watch with claude attach $ID"
else
    win=$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION" -n "$ID" -c "$DIR" "$@") ||
        fail "tmux could not start session $SESSION; watch with claude attach $ID"
fi
tmux set-option -w -t "$win" remain-on-exit off 2>/dev/null

sleep "$wait"
dead=$(tmux display-message -p -t "$win" '#{pane_dead}' 2>/dev/null) || dead=1
if [ "$dead" != 0 ]; then
    tmux kill-window -t "$win" 2>/dev/null
    fail "claude attach $ID exited at once, so no viewer is open; watch with claude attach $ID"
fi
echo "viewer $SESSION:$ID runs claude attach $ID"
echo "watch: tmux attach -t $SESSION (in iTerm2: tmux -CC attach -t $SESSION)"
