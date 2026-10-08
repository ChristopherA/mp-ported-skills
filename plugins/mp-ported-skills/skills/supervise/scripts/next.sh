#!/bin/sh
# next.sh -- between tickets of a /supervise --loop run, whether the loop
# goes on, and when it stops, which condition stopped it (#59).
#
# Runs after a ticket's worker was captured, its work landed, and it was
# stopped and released. Checks, in order, and prints the first that stops
# the loop as `stop <kind>: <detail>`:
#   held          the checkout's worker marker is still there, so a stop
#                 did not finish and the checkout is still read-only
#   not-landed    the tree has uncommitted paths, HEAD is detached, the
#                 branch has no upstream, or it has commits its upstream lacks after a
#                 fetch: the next ticket starts from the default branch as
#                 pushed, so the loop waits rather than stacking work
#   behind        the upstream has commits the branch lacks, so the next
#                 worker would start from an old commit
#   count-reached --max N was given and N tickets of --ran ran: the count
#                 --loop N asked for (#149). Checked after the landing
#                 checks above, so a ticket that did not land still says so
#   zone          --session was given and that supervisor session's zone
#                 reading is at or past ZONE_STOP (#78), so the loop wraps
#                 up while the session is still in its zone
#   nothing-left  state.sh's next step is case 7, nothing in motion
#   other-step    any other step than /implement of a ready-for-agent
#                 ticket, as step.sh reads it
#   repeat        the step is /implement of a ticket this loop already ran
#                 (--ran), which state.sh still recommends when its work
#                 carries no `Closes #N` on the default branch
# Otherwise prints `next implement #N`. The one-session-per-checkout check
# is launch.sh's, which the loop runs next. Writes nothing but the fetch.
#
# Run from the plugin cache (<plugin>/<version>/skills/supervise/scripts),
# it first prints `scripts <version> <dir>`, the newest installed version's
# scripts, which it also reads the next step with (#169). A worker's push
# and plugin update can install a newer version mid-loop, while the
# supervisor's skill text still names the folder it loaded; when the newest
# is newer than this one, the line ends `(newer than the loaded <version>;
# use it for the rest of the loop)`. Outside a cache it prints no such line.
#
# Usage:
#   next.sh --dir DIR [--ran "N M ..."] [--max N]
#           [--session ID [--session-dir DIR]] [--from FILE]
#   next.sh --max N     only check the count, before the loop's first launch:
#                       prints `count N`, or refuses one that is not a
#                       positive integer
#
# --session ID names the supervisor's own session, and --session-dir the
# folder it started in (default: the working directory), for its zone
# reading, read as glance.sh reads it, through this plugin's status-line.sh.
# An empty ID falls back to CLAUDE_CODE_SESSION_ID. With no reading, a
# `note:` line on stderr says so and the loop goes on. A ZONE_STOP at or
# above the session's auto-compact point (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE,
# default 80, a share of the window), read in zone units from the same
# record, is an error: the session would compact before the stop was read.
#
# --from reads a saved state.sh report instead of running state.sh (tests).
# Exits 0 for next (or a checked count), 2 for stop, 1 on an error.

set -u

# The supervisor's zone reading, in % of zone, at which the loop starts no
# more tickets. Below 100 so the wrap-up (loop summary, capture) runs inside
# the zone: in the #141 to #143 loop each ticket added 6 to 10 points. It
# must stay below the auto-compact point of the smallest window, 106% of
# zone for 200k tokens at 80% (tests/supervise-next.test.sh).
ZONE_STOP=90

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=""
SESSION=""
HAS_SESSION=""
SESSION_DIR=""
RAN=""
MAX=""
HAS_MAX=""
FROM=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)  need_value "$@"; DIR="$2"; shift 2 ;;
        --ran)  need_value "$@"; RAN="$2"; shift 2 ;;
        --max)  need_value "$@"; MAX="$2"; HAS_MAX=1; shift 2 ;;
        --from) need_value "$@"; FROM="$2"; shift 2 ;;
        --session) need_value "$@"; SESSION="$2"; HAS_SESSION=1; shift 2 ;;
        --session-dir) need_value "$@"; SESSION_DIR="$2"; shift 2 ;;
        --help)
            printf 'Usage: next.sh --dir DIR [--ran "N M ..."] [--max N]\n'
            printf '               [--session ID [--session-dir DIR]] [--from FILE]\n'
            printf '       next.sh --max N   (only checks the count)\n'
            printf 'Prints "next implement #N", or "stop <kind>: <detail>".\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
halt() { printf 'stop %s\n' "$1"; exit 2; }
ran_list() { printf '%s\n' "$RAN" | tr -c '0-9' '\n' | grep -v '^$'; } # one ticket number a line
plural() { [ "$1" = 1 ] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }
if [ -n "$HAS_MAX" ]; then
    case $MAX in
        '' | *[!0-9]*) fail "--max needs a positive integer, not '$MAX'" ;;
    esac
    n=$(printf '%s' "$MAX" | sed 's/^0*//')
    [ -n "$n" ] || fail "--max needs a positive integer, not '$MAX'"
    MAX=$n
    [ -n "$DIR" ] || { echo "count $MAX"; exit 0; }
fi
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "$DIR is not a git checkout"

marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker)
if [ -f "$marker" ]; then
    halt "held: the checkout's marker still names worker $(head -n 1 "$marker"), so it is read-only; finish its stop first"
fi

status=$(git -C "$DIR" status --porcelain) || fail "git status failed in $DIR"
dirty=$(printf '%s' "$status" | grep -c '^')
[ "$dirty" -eq 0 ] || halt "not-landed: $(plural "$dirty" "uncommitted path") in $DIR"

# The upstream as push.sh reads it: the branch's remote is fetched first,
# then @{u} is resolved, so a missing upstream and a failed fetch differ.
branch=$(git -C "$DIR" symbolic-ref --short -q HEAD) || halt "not-landed: HEAD is detached in $DIR"
remote=$(git -C "$DIR" config "branch.$branch.remote")
merge=$(git -C "$DIR" config "branch.$branch.merge")
[ -n "$remote" ] && [ -n "$merge" ] || halt "not-landed: $branch has no upstream, so its work is on no remote"
err=$(git -C "$DIR" fetch -q "$remote" </dev/null 2>&1) ||
    fail "git fetch $remote failed in $DIR, so whether $branch landed is unknown: $(printf '%s\n' "$err" | head -n 1)"
up=$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) ||
    halt "not-landed: $branch's upstream $remote/${merge#refs/heads/} does not exist"
counts=$(git -C "$DIR" rev-list --left-right --count "$up...HEAD") || fail "could not compare $branch with $up"
behind=${counts%%[!0-9]*}
ahead=${counts##*[!0-9]}
[ "$ahead" -eq 0 ] || halt "not-landed: $(plural "$ahead" commit) on $branch not on $up"
[ "$behind" -eq 0 ] ||
    halt "behind: $branch is $(plural "$behind" commit) behind $up; the next ticket would start from an old commit"

if [ -n "$HAS_MAX" ]; then
    ran=$(ran_list | sort -u | grep -c '^')
    [ "$ran" -lt "$MAX" ] || halt "count-reached: $(plural "$ran" ticket) ran, the most --loop $MAX allows"
fi

if [ -n "$HAS_SESSION" ]; then
    sid=${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}
    sdir=${SESSION_DIR:-$PWD}
    # "context: 138k tokens, 92% of a 150k smart zone, 86% of window remaining"
    context=""
    [ -z "$sid" ] || context=$(sh "$HERE/../../../scripts/status-line.sh" --context "$sdir" "$sid" </dev/null 2>/dev/null)
    pct=$(printf '%s\n' "$context" | sed -n 's/.* \([0-9][0-9]*\)% of a .*/\1/p')
    left=$(printf '%s\n' "$context" | sed -n 's/.* \([0-9][0-9]*\)% of window remaining.*/\1/p')
    if [ -z "$sid" ]; then
        printf 'note: no session id, so the loop goes on without its zone stop\n' >&2
    elif [ -z "$pct" ] || [ -z "$left" ]; then
        printf 'note: no zone reading for session %s in %s, so the loop goes on without its zone stop\n' "$sid" "$sdir" >&2
    else
        compact=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-80}
        case $compact in '' | *[!0-9]*) compact=80 ;; esac
        # Both shares are whole numbers rounded down, so the window is known
        # only to a range; refuse only when the stop is at or above the
        # highest auto-compact point the reading allows. Early in a session
        # the range is too wide to refuse on.
        if [ "$left" -lt 99 ] &&
            [ $((ZONE_STOP * (99 - left))) -ge $(((pct + 1) * compact)) ]; then
            fail "the loop's zone stop, $ZONE_STOP% of zone, is at or above this session's auto-compact point, about $((pct * compact / (100 - left)))% of zone ($compact% of its window), so it would compact before the loop stopped"
        fi
        [ "$pct" -lt "$ZONE_STOP" ] ||
            halt "zone: the supervisor's reading is $pct% of zone, at or past the $ZONE_STOP% the loop stops at, so it starts no more tickets"
    fi
fi

SCRIPT_DIR=$HERE
# The newest installed version beside this one, by number, when this script
# runs from a version folder of the plugin cache. A folder the cache marked
# .orphaned_at is no longer installed, so it counts only when it is this one.
is_version() { printf '%s\n' "$1" | grep -qE '^[0-9]+[.][0-9]+[.][0-9]+$'; }
scripts_line=""
plugin_root=$(cd "$SCRIPT_DIR/../../.." && pwd)
loaded=$(basename "$plugin_root")
if is_version "$loaded"; then
    newest=$({
        printf '%s\n' "$loaded"
        for d in "$plugin_root"/../*/skills/supervise/scripts/step.sh; do
            [ -f "$d" ] || continue
            version_dir=$(cd "$(dirname "$d")/../../.." && pwd)
            [ ! -e "$version_dir/.orphaned_at" ] || continue
            version=$(basename "$version_dir")
            is_version "$version" && printf '%s\n' "$version"
        done
    } | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    SCRIPT_DIR=$(cd "$plugin_root/../$newest/skills/supervise/scripts" && pwd) ||
        fail "could not read the scripts of version $newest beside $plugin_root"
    scripts_line="scripts $newest $SCRIPT_DIR"
    [ "$newest" = "$loaded" ] ||
        scripts_line="$scripts_line (newer than the loaded $loaded; use it for the rest of the loop)"
fi
if [ -n "$FROM" ]; then
    step=$(sh "$SCRIPT_DIR/step.sh" --from "$FROM" </dev/null) || fail "step.sh failed on $FROM"
else
    step=$(sh "$SCRIPT_DIR/step.sh" "$DIR" </dev/null) || fail "step.sh failed in $DIR"
fi
case $step in
    "implement #"*)
        n=${step#implement #}
        for r in $(ran_list); do
            [ "$r" = "$n" ] &&
                halt "repeat: #$n ran earlier in this loop and state.sh still recommends it; was its work committed with Closes #$n?"
        done
        [ -z "$scripts_line" ] || printf '%s\n' "$scripts_line"
        echo "next $step" ;;
    "stop: next: 7 "*) halt "nothing-left: ${step#stop: }" ;;
    *) halt "other-step: ${step#stop: }" ;;
esac
