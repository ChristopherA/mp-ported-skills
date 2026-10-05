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
#   nothing-left  state.sh's next step is case 7, nothing in motion
#   other-step    any other step than /implement of a ready-for-agent
#                 ticket, as step.sh reads it
#   repeat        the step is /implement of a ticket this loop already ran
#                 (--ran), which state.sh still recommends when its work
#                 carries no `Closes #N` on the default branch
# Otherwise prints `next implement #N`. The one-session-per-checkout check
# is launch.sh's, which the loop runs next. Writes nothing but the fetch.
#
# Usage:
#   next.sh --dir DIR [--ran "N M ..."] [--from FILE]
#
# --from reads a saved state.sh report instead of running state.sh (tests).
# Exits 0 for next, 2 for stop, 1 on an error.

set -u

DIR=""
RAN=""
FROM=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)  need_value "$@"; DIR="$2"; shift 2 ;;
        --ran)  need_value "$@"; RAN="$2"; shift 2 ;;
        --from) need_value "$@"; FROM="$2"; shift 2 ;;
        --help)
            printf 'Usage: next.sh --dir DIR [--ran "N M ..."] [--from FILE]\n'
            printf 'Prints "next implement #N", or "stop <kind>: <detail>".\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
halt() { printf 'stop %s\n' "$1"; exit 2; }
plural() { [ "$1" = 1 ] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$FROM" ]; then
    step=$(sh "$SCRIPT_DIR/step.sh" --from "$FROM" </dev/null) || fail "step.sh failed on $FROM"
else
    step=$(sh "$SCRIPT_DIR/step.sh" "$DIR" </dev/null) || fail "step.sh failed in $DIR"
fi
case $step in
    "implement #"*)
        n=${step#implement #}
        for r in $(printf '%s\n' "$RAN" | tr -c '0-9\n' ' '); do
            [ "$r" = "$n" ] &&
                halt "repeat: #$n ran earlier in this loop and state.sh still recommends it; was its work committed with Closes #$n?"
        done
        echo "next $step" ;;
    "stop: next: 7 "*) halt "nothing-left: ${step#stop: }" ;;
    *) halt "other-step: ${step#stop: }" ;;
esac
