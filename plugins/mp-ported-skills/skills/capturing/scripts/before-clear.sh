#!/bin/sh
# before-clear.sh -- whether capturing's before-clear question can be asked,
# and whether one job in it may run unasked (#89). Capturing's sweep also
# calls it with --action other to learn whether its findings can be
# confirmed with the user (#105), then once per finding, with issue-comment
# for a comment on an open ticket or issue-create for a new ticket, to
# learn whether that finding may be posted unasked or only listed in the
# report (#110), and with sub-issue to learn whether a new ticket may be
# linked under its parent and placed in the order (#162), and with label
# to learn whether a ticket it leaves open may be relabelled (#184).
#
# A supervised worker resumed with `/mp-ported-skills:capturing` has nobody
# to answer the before-clear question, and blocked on it the way a worker
# did on resuming's SessionStart question (#69). Detection is the same
# CLAUDE_CODE_SESSION_ATTENDED a background session carries in its own
# process environment (ADR 0004): unset or other than 0 means someone can
# answer, so capturing asks as before.
#
# When nobody can answer, a job still runs if supervise's grant.sh finds it
# standing-granted: the same docs/agents/supervision.md, read only from the
# default branch as committed on origin, that already lets a worker's
# /implement take the action without asking (#58, #88). A job that maps to
# no shared action -- a plugin update, say -- is always ungranted: there is
# nothing in supervision.md for it to match. checked-push (#188) is not an
# action here: it covers only /supervise's own push after the worker's
# turn, so a capture's push job maps to push or distribution-push.
#
# Usage:
#   before-clear.sh --action <push|distribution-push|pr-create|pr-merge|issue-close|issue-comment|issue-create|sub-issue|label|other> [--dir DIR]
#
# DIR defaults to the working directory, and is read only for the
# shared actions; `other` needs no git checkout.
#
# Prints:
#   attended            someone can answer; ask the question
#   granted: <citation> unattended; this job's action is standing-granted
#   ungranted           unattended; this job's action has no standing grant,
#                       or an issue-close grant waits on a Distribution
#                       repo ahead of its upstream (#186; a note on stderr
#                       names it)
#
# Exits 0 for all three. Exits 1 on a usage error, or when grant.sh itself
# fails (its stderr starts with Error, distinct from the "note: ... ignored"
# it also prints on stderr for a grant that exists but is not committed on
# origin); that stderr is passed through either way.

set -u

ACTION=""
DIR="."

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --action) need_value "$@"; ACTION="$2"; shift 2 ;;
        --dir)    need_value "$@"; DIR="$2"; shift 2 ;;
        --help)
            printf 'Usage: before-clear.sh --action <push|distribution-push|pr-create|pr-merge|issue-close|issue-comment|issue-create|sub-issue|label|other> [--dir DIR]\n'
            printf 'Prints attended, "granted: <citation>", or ungranted.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
case "$ACTION" in
    push | distribution-push | pr-create | pr-merge | issue-close | issue-comment | issue-create | sub-issue | label | other) ;;
    '') fail "--action is required" ;;
    *) fail "--action must be push, distribution-push, pr-create, pr-merge, issue-close, issue-comment, issue-create, sub-issue, label or other, not '$ACTION'" ;;
esac

if [ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" != 0 ]; then
    echo attended
    exit 0
fi

if [ "$ACTION" = other ]; then
    echo ungranted
    exit 0
fi

[ -d "$DIR" ] || fail "not a directory: $DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
grant_sh="$SCRIPT_DIR/../../supervise/scripts/grant.sh"
errs=$(mktemp) || fail "mktemp failed, so the grant cannot be read"
if cited=$(sh "$grant_sh" --dir "$DIR" --action "$ACTION" 2>"$errs"); then
    command cat "$errs" >&2
    command rm -f "$errs"
    # A granted close waits while the Project's Distribution repo is ahead
    # of its upstream (#186): the hook and the wrappers refuse it, so the
    # capture lists it with the push rather than trying it.
    if [ "$ACTION" = issue-close ]; then
        . "$SCRIPT_DIR/../../../scripts/shared-action-classify.sh"
        classify_distribution_sh="$SCRIPT_DIR/../../supervise/scripts/distribution.sh"
        classify_close_held "$DIR"
        if [ -n "$classify_held" ]; then
            printf 'note: the issue-close grant waits: %s; list the close with the push\n' "$classify_held" >&2
            echo ungranted
            exit 0
        fi
    fi
    echo "granted: $cited"
    exit 0
fi
if grep -q '^Error' "$errs"; then
    command cat "$errs" >&2
    command rm -f "$errs"
    exit 1
fi
command cat "$errs" >&2
command rm -f "$errs"
echo ungranted
exit 0
