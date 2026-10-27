#!/bin/sh
# finish.sh -- end a settled run in one call, and print only what needs the
# maintainer (#192).
#
# In order, it:
#   1. stops the worker and releases its marker, with stop.sh;
#   2. closes the viewer, with view.sh --close (--tmux, or --pane for an
#      iTerm2 pane), when given one;
#   3. reads the worker's shared actions, with actions.sh;
#   4. takes the supervisor's glance, with glance.sh;
#   5. writes the run record to RECORD, with record.sh;
#   6. posts RECORD on the ticket, with `gh issue comment`, run in DIR.
# Each script's full output goes to the detail file, under a `== <step>`
# heading.
#
# It prints one line for each result that needs the maintainer:
#   stop failed: <error>               stop.sh exited non-zero, followed by
#                                      its `marker kept:` or `no marker`
#                                      line and its `finish with:` line when
#                                      it printed them. Nothing after the
#                                      stop runs, since the worker's cost is
#                                      written at the stop. Exits 1.
#   viewer not closed: <error>         view.sh --close failed
#   <actions.sh line>                  each `ungranted` line, each `pushed
#                                      by someone else` line and each `note`
#                                      line, as actions.sh printed it
#   actions not read: <error>          actions.sh exited non-zero
#   record failed: <error>             record.sh exited non-zero; no post
#   post failed: <error>; the record is in RECORD
#   post printed no URL; the record is in RECORD
#                                      gh exited 0 with no https: line
# then `record <url>` when the record was posted, `shared actions: none` or
# `shared actions: N, listed in the record`, and `glance: <reading>`.
# When there is none of those, it prints one line instead:
#   clean <url>; shared actions: ...; glance: <reading>
# The last line is always `detail <path>`.
#
# record.sh's own note lines (a source it could not read) are in the record
# and the detail file, not printed: a supervisor's cost reads unknown while
# it runs, so they come with every run.
#
# Usage:
#   finish.sh --dir DIR --id ID --start SHA --ticket N --record RECORD
#             [--cwd CWD] [--dist-start DIST_SHA]
#             [--session SESSION_ID] [--session-dir SDIR]
#             [--tmux | --pane 'SESSION WINDOW TAB'] [--detail PATH]
#             [--settle S] [--interval S] [--timeout S]
#
# DIR is the Project folder the worker was launched into, which holds its
# marker. CWD is the checkout the worker committed in (watch.sh's cwd line),
# read by actions.sh and record.sh; it defaults to DIR. DIST_SHA is the
# Distribution repo's head when the run started (the snapshot's `dist head`
# line), which record.sh counts the Distribution repo's commits after; it
# names that repo from DIR (#216). SESSION_ID and SDIR
# name the supervisor's session and its own folder, as for glance.sh; they
# default to $CLAUDE_CODE_SESSION_ID and the working directory. PATH defaults
# to finish-ID.txt beside RECORD. --settle, --interval and --timeout go to
# stop.sh.
#
# Exits 0 when it ran every step it reached past the stop; 1 when the stop
# failed or an option is wrong.

set -u

DIR=""
CWD=""
ID=""
START=""
TICKET=""
DIST_START=""
RECORD=""
SESSION="${CLAUDE_CODE_SESSION_ID:-}"
SDIR="$PWD"
TMUX_VIEW=""
PANE=""
DETAIL=""
STOP_OPTS=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)         need_value "$@"; DIR="$2"; shift 2 ;;
        --cwd)         need_value "$@"; CWD="$2"; shift 2 ;;
        --id)          need_value "$@"; ID="$2"; shift 2 ;;
        --start)       need_value "$@"; START="$2"; shift 2 ;;
        --ticket)      need_value "$@"; TICKET="${2#\#}"; shift 2 ;;
        --dist-start)  need_value "$@"; DIST_START="$2"; shift 2 ;;
        --record)      need_value "$@"; RECORD="$2"; shift 2 ;;
        --session)     need_value "$@"; SESSION="$2"; shift 2 ;;
        --session-dir) need_value "$@"; SDIR="$2"; shift 2 ;;
        --tmux)        TMUX_VIEW=1; shift ;;
        --pane)        need_value "$@"; PANE="$2"; shift 2 ;;
        --detail)      need_value "$@"; DETAIL="$2"; shift 2 ;;
        --settle | --interval | --timeout)
            need_value "$@"; STOP_OPTS="$STOP_OPTS $1 $2"; shift 2 ;;
        --help)
            printf 'Usage: finish.sh --dir DIR --id ID --start SHA --ticket N --record RECORD [--cwd CWD] [--dist-start SHA] [--session ID] [--session-dir DIR] [--tmux | --pane S] [--detail PATH]\n'
            printf 'Stops the worker, closes its viewer, reads its shared actions, takes the glance, writes and posts the run record. Outputs: clean <url>; ... or one line per item that needs the maintainer, then detail <path>\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$ID" ] || fail "--id is required"
[ -n "$START" ] || fail "--start is required"
[ -n "$TICKET" ] || fail "--ticket is required"
[ -n "$RECORD" ] || fail "--record is required"
case $TICKET in *[!0-9]*) fail "--ticket needs an issue number, not '$TICKET'" ;; esac
[ -z "$TMUX_VIEW" ] || [ -z "$PANE" ] || fail "--tmux and --pane are exclusive"
[ -d "$DIR" ] || fail "not a directory: $DIR"
[ -n "$CWD" ] || CWD=$DIR
[ -n "$DETAIL" ] || DETAIL="$(dirname -- "$RECORD")/finish-$ID.txt"
# The post runs in DIR, so keep the record and detail paths absolute.
case $RECORD in /*) ;; *) RECORD="$PWD/$RECORD" ;; esac
case $DETAIL in /*) ;; *) DETAIL="$PWD/$DETAIL" ;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

tmp=$(mktemp -d) || fail "mktemp failed"
trap 'command rm -rf "$tmp"' EXIT
: >"$DETAIL" 2>/dev/null || fail "the detail file $DETAIL could not be written"

# run <step> <command...>: run it with its stdout in $tmp/out and its stderr
# in $tmp/err, and add both to the detail file. Returns the command's status.
run() {
    step=$1; shift
    "$@" </dev/null >"$tmp/out" 2>"$tmp/err"
    rc=$?
    { printf '== %s (exit %s)\n' "$step" "$rc"; command cat "$tmp/out" "$tmp/err"; } >>"$DETAIL"
    return "$rc"
}
# why: the first `Error:` line of the last step's stderr, or its first line.
why() {
    w=$(sed -n 's/^Error: //p' "$tmp/err" | head -n 1)
    [ -n "$w" ] || w=$(head -n 1 "$tmp/err")
    [ -n "$w" ] || w=$(head -n 1 "$tmp/out")
    printf '%s' "${w:-no output}"
}
flag() { printf '%s\n' "$1" >>"$tmp/flags"; }
: >"$tmp/flags"

# 1. Stop.
# shellcheck disable=SC2086
if ! run stop.sh sh "$here/stop.sh" --dir "$DIR" --id "$ID" $STOP_OPTS; then
    printf 'stop failed: %s\n' "$(why)"
    grep -E '^(marker kept: |no marker in |finish with: )' "$tmp/err"
    printf 'detail %s\n' "$DETAIL"
    exit 1
fi

# 2. The viewer.
if [ -n "$TMUX_VIEW" ]; then
    run view.sh sh "$here/view.sh" --close || flag "viewer not closed: $(why)"
elif [ -n "$PANE" ]; then
    run view.sh sh "$here/view.sh" --close --pane "$PANE" || flag "viewer not closed: $(why)"
fi

# 3. Shared actions. Those a grant or the maintainer's yes covered are in the
# record, and counted here; the rest are printed.
actions=0
if run actions.sh sh "$here/actions.sh" --id "$ID" --dir "$CWD" --start "$START"; then
    while IFS= read -r line; do
        case $line in
            '' | none) continue ;;
            'note '*) flag "$line"; continue ;;
        esac
        actions=$((actions + 1))
        case ${line%%:*} in
            *' ungranted' | *' pushed by someone else') flag "$line" ;;
        esac
    done <"$tmp/out"
    if [ "$actions" -eq 0 ]; then summary="shared actions: none"
    else summary="shared actions: $actions, listed in the record"; fi
else
    flag "actions not read: $(why)"
    summary="shared actions: not read"
fi

# 4. The glance. glance.sh always exits 0.
run glance sh "$here/../../glance/scripts/glance.sh" "$SDIR" "$SESSION"
glance=$(head -n 1 "$tmp/out")

# 5 and 6. The record, and its post.
url=""
set -- --id "$ID" --dir "$CWD" --project "$DIR" --start "$START" --ticket "$TICKET" --supervisor "$SESSION"
[ -z "$DIST_START" ] || set -- "$@" --dist-start "$DIST_START"
if run record.sh sh "$here/record.sh" "$@"; then
    if command cp "$tmp/out" "$RECORD" 2>"$tmp/err"; then
        if (cd "$DIR" && run post gh issue comment "$TICKET" --body-file "$RECORD"); then
            url=$(sed -n '/^https:/p' "$tmp/out" | tail -n 1)
            [ -n "$url" ] || flag "post printed no URL; the record is in $RECORD"
        else
            flag "post failed: $(why); the record is in $RECORD"
        fi
    else
        flag "record failed: $(why)"
    fi
else
    flag "record failed: $(why)"
fi

if [ ! -s "$tmp/flags" ] && [ -n "$url" ]; then
    printf 'clean %s; %s; glance: %s\n' "$url" "$summary" "$glance"
else
    command cat "$tmp/flags"
    [ -z "$url" ] || printf 'record %s\n' "$url"
    printf '%s\nglance: %s\n' "$summary" "$glance"
fi
printf 'detail %s\n' "$DETAIL"
