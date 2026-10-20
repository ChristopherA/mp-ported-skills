#!/bin/sh
# close.sh -- settle a stopped worker's ticket once the maintainer has
# answered its Distribution push (#186).
#
# In a Project with a Distribution repo, a worker may not close its ticket
# while that repo holds commits its upstream lacks: the issue-close grant
# covers the ticket only after its work is pushed, and the hook and the
# wrappers hold the close (classify_close_held). The worker ends on
# `Waiting on: git -C <dist> push origin <branch>; gh issue close <N>`, and
# Push on approval runs this after the maintainer's answer:
#
#   --pushed    the push landed: close the ticket, with a comment naming
#               the pushed commit, under the Project's issue-close grant or
#               the maintainer's own approval of the close (--approved)
#   --declined  the push was declined: the ticket stays open (reopened if
#               it was closed), is relabelled ready-for-human, and gets a
#               comment naming the unpushed commits, so /supervise's next
#               step does not build it again
#
# The commands are built from the options, never from the worker's text.
# Label strings come from DIR's docs/agents/triage-labels.md, as capturing's
# live-check.sh reads them.
#
# Checks, each printed as `ok <check>: ...` or `fail <check>: ...`:
#   marker        no worker marker in the checkout
#   distribution  DIR names a Distribution repo (distribution.sh)
#   upstream      --pushed: the Distribution repo is even with its upstream;
#                 --declined: it holds commits its upstream lacks
#   grant         --pushed: the Project grants issue-close, or --approved
#                 was given (then printed as `skip grant: ...`)
#
# Without --check, when every check passes, it runs the commands, each
# printed as `ran: gh ...`. --pushed on a ticket already closed prints
# `closed already: #N` and records nothing, since the close was not the
# supervisor's. Otherwise --pushed prints `closed <url>` and appends
# `ID <time> issue-close <url>` to the checkout's
# `git rev-parse --git-path mp-supervise-posted`, which actions.sh reads to
# name the close as the supervisor's, after the push, and record.sh to keep
# the worker's wait off the waits on a human. --declined records nothing:
# the ticket now waits on the maintainer. Both are refused in a background
# session (CLAUDE_CODE_SESSION_ATTENDED=0), as push.sh and post.sh are,
# though --check still runs there.
#
# Usage:
#   close.sh --dir DIR --id ID --ticket N (--pushed [--approved] | --declined)
#            [--check]
#
# Exits 0 when every check passed (and, without --check, the commands ran);
# 1 on a usage error or in a background session; 2 when a check failed,
# with nothing run; 3 when gh itself failed.

set -u
here=$(dirname -- "$0")
. "$here/marker.sh"

DIR=""
ID=""
TICKET=""
OUTCOME=""
APPROVED=0
CHECK=0

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
set_outcome() {
    [ -z "$OUTCOME" ] || [ "$OUTCOME" = "$1" ] || fail "give --pushed or --declined, not both"
    OUTCOME=$1
}
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --ticket)   need_value "$@"; TICKET="${2#\#}"; shift 2 ;;
        --pushed)   set_outcome pushed; shift ;;
        --declined) set_outcome declined; shift ;;
        --approved) APPROVED=1; shift ;;
        --check)    CHECK=1; shift ;;
        --help)
            printf 'Usage: close.sh --dir DIR --id ID --ticket N (--pushed [--approved] | --declined) [--check]\n'
            printf 'Closes a worker'\''s ticket after its Distribution push landed, or keeps it open for the maintainer after a declined one.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$ID" ] || fail "--id is required"
[ -n "$TICKET" ] || fail "--ticket is required"
case $TICKET in *[!0-9]*) fail "--ticket needs an issue number, not '$TICKET'" ;; esac
[ -n "$OUTCOME" ] || fail "--pushed or --declined is required"
[ "$APPROVED" = 0 ] || [ "$OUTCOME" = pushed ] || fail "--approved goes with --pushed"
[ -d "$DIR" ] || fail "not a directory: $DIR"
if [ "$CHECK" = 0 ] && [ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ]; then
    fail "close.sh settles a ticket for the maintainer's attended session; a background session closes only on a standing grant"
fi
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $DIR"

failed=0
ok() { printf 'ok %s\n' "$1"; }
bad() { printf 'fail %s\n' "$1"; failed=1; }

echo "close $OUTCOME: #$TICKET"

marker=$(marker_path "$DIR")
if [ -f "$marker" ]; then
    bad "marker: worker $(head -n 1 "$marker") still holds the checkout; stop it and release its marker first"
else
    ok "marker: no worker marker in the checkout"
fi

DIST=""
if ! DIST=$(sh "$here/distribution.sh" --dir "$DIR" </dev/null 2>/dev/null); then
    bad "distribution: distribution.sh failed in $DIR"
elif [ -z "$DIST" ]; then
    bad "distribution: $DIR names no Distribution repo; close the ticket as any other"
elif ! real=$(CDPATH= cd -- "$DIST" 2>/dev/null && pwd -P) ||
    [ "$(git -C "$real" rev-parse --show-toplevel 2>/dev/null)" != "$real" ]; then
    bad "distribution: $DIST is not a git checkout of its own"
    DIST=""
else
    DIST=$real
    ok "distribution: $DIST"
fi

head_line=""
unpushed=""
if [ -n "$DIST" ]; then
    if ! n=$(git -C "$DIST" rev-list --count '@{upstream}..HEAD' 2>/dev/null); then
        bad "upstream: $DIST has no upstream to compare with"
    elif [ "$OUTCOME" = pushed ]; then
        if [ "$n" = 0 ]; then
            head_line=$(git -C "$DIST" log -1 --format='%h %s')
            ok "upstream: $DIST is even with its upstream at $head_line"
        else
            bad "upstream: $DIST still holds $n commit(s) its upstream lacks; push first"
        fi
    elif [ "$n" = 0 ]; then
        bad "upstream: $DIST is even with its upstream, so nothing is unpushed; was the push made?"
    else
        unpushed=$(git -C "$DIST" log '@{upstream}..HEAD' --format='%h %s')
        ok "upstream: $DIST holds $n commit(s) its upstream lacks"
        printf '%s\n' "$unpushed" | sed 's/^/  /'
    fi
fi

if [ "$OUTCOME" = pushed ]; then
    if [ "$APPROVED" = 1 ]; then
        echo "skip grant: --approved given, the maintainer approved the close"
    elif cited=$(sh "$here/grant.sh" --dir "$DIR" --action issue-close </dev/null 2>/dev/null); then
        ok "grant: $cited"
    else
        bad "grant: the Project grants no issue-close; ask the maintainer, then run with --approved"
    fi
fi

[ "$failed" = 0 ] || exit 2
[ "$CHECK" = 0 ] || exit 0

err=$(mktemp) || fail "mktemp failed"
body=$(mktemp) || fail "mktemp failed"
trap 'command rm -f "$err" "$body"' EXIT
# run <gh args...>: gh in DIR, printed first; exits 3 when it fails.
run() {
    echo "ran: gh $*"
    if ! out=$(cd "$DIR" && gh "$@" </dev/null 2>"$err"); then
        command cat "$err" >&2
        printf 'Error: gh %s failed\n' "$*" >&2
        exit 3
    fi
}

# Label string for a triage role, as live-check.sh reads it.
label_for() {
    l=""
    if [ -f "$DIR/docs/agents/triage-labels.md" ]; then
        l=$(awk -F'|' -v role="$1" '
            { r = $2; s = $3; gsub(/[ `]/, "", r); gsub(/[ `]/, "", s) }
            r == role && s != "" { print s; exit }' "$DIR/docs/agents/triage-labels.md")
    fi
    printf '%s' "${l:-$1}"
}

run issue view "$TICKET" --json state,labels,url
view=$out
url=$(printf '%s' "$view" | jq -r '.url // empty')
[ -n "$url" ] || url=no-url

if [ "$OUTCOME" = pushed ]; then
    printf 'Closed after the Distribution push landed: %s is even with its upstream at %s.\n' "$DIST" "$head_line" >"$body"
    if [ "$(printf '%s' "$view" | jq -r '.state')" = CLOSED ]; then
        # Someone else closed it, so the close is not the supervisor's.
        echo "closed already: #$TICKET"
        exit 0
    fi
    run issue close "$TICKET" --comment "$(command cat "$body")"
    echo "closed $url"
    record=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-posted)
    printf '%s %s %s %s\n' "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" issue-close "$url" >>"$record" ||
        echo "note the close was not recorded in $record, so record.sh will count the worker's wait for it as a human's"
    exit 0
fi

agent=$(label_for ready-for-agent)
human=$(label_for ready-for-human)
[ "$(printf '%s' "$view" | jq -r '.state')" != CLOSED ] || run issue reopen "$TICKET"
{
    printf 'The Distribution push was declined, so this ticket stays open and waits on the maintainer (%s). %s holds these commits its upstream lacks:\n\n' "$human" "$DIST"
    printf '%s\n' "$unpushed" | sed 's/^/- /'
} >"$body"
run issue comment "$TICKET" --body-file "$body"
set --
printf '%s' "$view" | jq -e --arg l "$agent" '[.labels[].name] | index($l)' >/dev/null && set -- "$@" --remove-label "$agent"
printf '%s' "$view" | jq -e --arg l "$human" '[.labels[].name] | index($l)' >/dev/null || set -- "$@" --add-label "$human"
[ $# = 0 ] || run issue edit "$TICKET" "$@"
echo "kept open $url"
