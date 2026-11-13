#!/bin/sh
# view.sh -- open a tmux window that shows a supervised worker, for
# `/supervise --watch tmux` (#68), or remove the tmux session that holds
# those windows. The session is named for the Project folder,
# `mp-supervise-<folder name>-<4 hex digits of its path's cksum>`, so two
# supervisors in different Projects each have their own, and one run's
# --close leaves the other's viewers open (#95). A session named plain
# `mp-supervise`, from a version before, is left for the maintainer to
# remove. With --iterm, open an iTerm2 split pane beside this session
# instead, for `/supervise --watch iterm` (#102), or close one.
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
# The iTerm2 pane opens through iterm-pane's pane-open.sh, which splits the
# pane on this session's TTY, with a first command that changes into DIR and
# execs the same `claude attach`, so the pane's shell ends with the viewer.
# The pane's login shell does not inherit CLAUDE_CONFIG_DIR, so it is set on
# the command. No pane opens when this session runs inside tmux, outside
# iTerm2, or under the `claude remote-control` server (CLAUDE_CODE_ENTRYPOINT
# sdk-cli), whose TTY is the server's own pane. --close --pane closes the
# pane whatever runs there, so call it only once the worker is stopped.
#
# Usage:
#   view.sh --id ID --dir DIR [--session NAME]
#   view.sh --close (--dir DIR | --session NAME)
#   view.sh --iterm --id ID --dir DIR
#   view.sh --close --pane 'SESSION WINDOW TAB'
#
# NAME defaults to the one named for DIR. MP_VIEW_WAIT: seconds to wait before
# checking the viewer is still running (default 2); one that exits at once,
# as `claude attach` does for an id it cannot open, is reported and its
# window closed.
#
# MP_PANE_DIR: where the iterm-pane scripts are (default: the iterm-pane
# skill beside this one).
#
# Prints `viewer NAME:ID runs claude attach ID` and the command to watch it,
# or for --close `closed NAME` or `no tmux session NAME`. With --iterm:
# `viewer iterm pane SESSION WINDOW TAB runs claude attach ID` and the
# command to close it, or for --close `closed pane SESSION` or `pane SESSION
# already closed`. Exits 0 opened or closed; 1 not.

set -u

ID=""
DIR=""
SESSION=""
CLOSE=""
ITERM=""
PANE=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)      need_value "$@"; ID="$2"; shift 2 ;;
        --dir)     need_value "$@"; DIR="$2"; shift 2 ;;
        --session) need_value "$@"; SESSION="$2"; shift 2 ;;
        --close)   CLOSE=1; shift ;;
        --iterm)   ITERM=1; shift ;;
        --pane)    need_value "$@"; PANE="$2"; shift 2 ;;
        --help)
            printf 'Usage: view.sh --id ID --dir DIR [--session NAME]\n'
            printf '       view.sh --close (--dir DIR | --session NAME)\n'
            printf '       view.sh --iterm --id ID --dir DIR\n'
            printf "       view.sh --close --pane 'SESSION WINDOW TAB'\n"
            printf 'Opens a tmux window (or with --iterm an iTerm2 pane) running claude attach ID, or closes it. Outputs: the viewer and the command to watch or close it\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
# The viewer did not open: say why and how to watch without it.
fail_watch() { fail "$1; watch with claude attach $ID"; }
has_session() { tmux has-session -t "=$SESSION" 2>/dev/null; }
[ -z "$SESSION" ] || [ -z "$ITERM$PANE" ] || fail "--session names a tmux session, not an iTerm2 pane"
[ -z "$PANE" ] || [ -n "$CLOSE" ] || fail "--pane goes with --close"
[ -z "$ITERM" ] || [ -z "$CLOSE" ] || fail "--close takes --pane, not --iterm, for an iTerm2 pane"
[ -z "$CLOSE" ] || [ -n "$DIR$SESSION$PANE" ] || fail "--close needs --dir, --session or --pane"
if [ -n "$DIR" ] && [ -z "$PANE" ]; then
    [ -d "$DIR" ] || fail "not a directory: $DIR"
    DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
fi
# The Project folder's session: its name, with anything but letters, digits,
# - and _ made -, cut to 30 characters, then the low 16 bits of its full
# path's cksum, so two folders with one name get two sessions.
session_for() {
    name=$(basename -- "$1" | LC_ALL=C tr -c 'A-Za-z0-9_\n-' '-' | cut -c 1-30)
    crc=$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)
    printf 'mp-supervise-%s-%04x\n' "$name" $((crc % 65536))
}
[ -n "$SESSION" ] || [ -z "$DIR" ] || SESSION=$(session_for "$DIR")
case $SESSION in
    *[!A-Za-z0-9_-]*) fail "--session takes letters, digits, - and _, not '$SESSION'" ;;
esac

panes=${MP_PANE_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../../iterm-pane/scripts" && pwd)}

# Sets PANE_SESSION, PANE_WINDOW and PANE_TAB from a pane's coordinates,
# `SESSION WINDOW TAB`.
pane_coords() {
    set -f
    set -- $1
    set +f
    [ $# = 3 ] || return 1
    case "$1" in '' | *[!A-Za-z0-9:-]*) return 1 ;; esac
    case "$2" in '' | *[!0-9]*) return 1 ;; esac
    case "$3" in '' | *[!0-9]*) return 1 ;; esac
    PANE_SESSION=$1 PANE_WINDOW=$2 PANE_TAB=$3
}
pane_state() { sh "$panes/pane-classify.sh" --session "$PANE_SESSION" --window "$PANE_WINDOW" --tab "$PANE_TAB" </dev/null 2>/dev/null; }
pane_close() { sh "$panes/pane-close.sh" --session "$PANE_SESSION" --window "$PANE_WINDOW" --tab "$PANE_TAB" --force </dev/null >/dev/null; }

if [ -n "$CLOSE" ] && [ -n "$PANE" ]; then
    pane_coords "$PANE" || fail "--pane needs 'SESSION WINDOW TAB', not '$PANE'"
    [ -f "$panes/pane-close.sh" ] || fail "no iterm-pane scripts in ${panes:-the iterm-pane skill}"
    if [ "$(pane_state)" = gone ]; then
        echo "pane $PANE_SESSION already closed"
    else
        pane_close || fail "iTerm2 could not close pane $PANE_SESSION"
        echo "closed pane $PANE_SESSION"
    fi
    exit 0
fi

if [ -n "$CLOSE" ]; then
    command -v tmux >/dev/null 2>&1 || { echo "no tmux session $SESSION"; exit 0; }
    if has_session; then
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
wait=${MP_VIEW_WAIT:-2}

if [ -n "$ITERM" ]; then
    [ -z "${TMUX:-}" ] || fail_watch "this session runs inside tmux, so no iTerm2 pane can open"
    [ "${CLAUDE_CODE_ENTRYPOINT:-}" != sdk-cli ] ||
        fail_watch "this session was started by claude remote-control, so it has no iTerm2 pane to split"
    [ "${TERM_PROGRAM:-}" = iTerm.app ] || [ "${LC_TERMINAL:-}" = iTerm2 ] ||
        fail_watch "this session is not in iTerm2, so no pane can open"
    claude=$(command -v claude) || fail "claude is not on PATH, so no viewer can open"
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the viewer's profile cannot be pinned"
    # A shell string literal: single quotes, each ' inside closed, escaped and
    # reopened.
    sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    line="cd $(sh_quote "$DIR") && exec env CLAUDE_CONFIG_DIR=$(sh_quote "$CLAUDE_CONFIG_DIR") $(sh_quote "$claude") attach $ID"
    [ -f "$panes/pane-open.sh" ] || fail_watch "no iterm-pane scripts in ${panes:-the iterm-pane skill}, so no pane can open"
    if ! coords=$(sh "$panes/pane-open.sh" --direction vertical --command "$line" </dev/null 2>&1); then
        why=$(printf '%s\n' "$coords" | head -n 1 | sed 's/^Error: //')
        fail_watch "no iTerm2 pane opened (${why:-pane-open.sh failed})"
    fi
    pane_coords "$(printf '%s\n' "$coords" | head -n 1)" ||
        fail_watch "pane-open.sh printed no pane coordinates"
    # claude attach for an id it cannot open exits at once; iTerm2 then
    # closes the pane, or leaves it at a shell or ended.
    sleep "$wait"
    state=$(pane_state)
    if [ "$state" = gone ] || [ "$state" = shell ]; then
        [ "$state" = gone ] || pane_close
        fail_watch "claude attach $ID exited at once, so no viewer is open"
    fi
    echo "viewer iterm pane $PANE_SESSION $PANE_WINDOW $PANE_TAB runs claude attach $ID"
    echo "close: view.sh --close --pane '$PANE_SESSION $PANE_WINDOW $PANE_TAB'"
    exit 0
fi

command -v tmux >/dev/null 2>&1 || fail_watch "tmux is not on PATH, so no viewer can open"
claude=$(command -v claude) || fail "claude is not on PATH, so no viewer can open"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the viewer's profile cannot be pinned"

set -- env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" "$claude" attach "$ID"
if has_session; then
    for w in $(tmux list-windows -t "=$SESSION" -F '#{window_id} #{window_name}' | sed -n "s/^\\(@[0-9]*\\) $ID\$/\\1/p"); do
        tmux kill-window -t "$w"
    done
fi
# The session may have ended with the window just closed.
if has_session; then
    win=$(tmux new-window -d -P -F '#{window_id}' -t "=$SESSION:" -n "$ID" -c "$DIR" "$@") ||
        fail_watch "tmux could not open a window in session $SESSION"
else
    win=$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION" -n "$ID" -c "$DIR" "$@") ||
        fail_watch "tmux could not start session $SESSION"
fi
tmux set-option -w -t "$win" remain-on-exit off 2>/dev/null

sleep "$wait"
dead=$(tmux display-message -p -t "$win" '#{pane_dead}' 2>/dev/null) || dead=1
if [ "$dead" != 0 ]; then
    tmux kill-window -t "$win" 2>/dev/null
    fail_watch "claude attach $ID exited at once, so no viewer is open"
fi
echo "viewer $SESSION:$ID runs claude attach $ID"
echo "watch: tmux attach -t $SESSION (in iTerm2: tmux -CC attach -t $SESSION)"
