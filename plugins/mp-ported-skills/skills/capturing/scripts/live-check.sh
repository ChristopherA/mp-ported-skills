#!/bin/sh
# live-check.sh -- relabel a ticket ready-for-human to wait for a live
# check, and move it after its parent's last open ready-for-agent child
# (#194).
#
# A ticket whose build landed but whose last criterion waits on a check
# only the maintainer can run is relabelled ready-for-human and left open.
# Left where it was in its parent's sub-issue order, it can head the order,
# and then resuming's state.sh names it as the parent's next child and
# /supervise's step.sh stops on it as "by hand", with ready-for-agent
# children waiting behind it (#131 and #118 under #40). Moving it after the
# parent's last open ready-for-agent child, in the same step, lets the next
# run build those first.
#
# Usage:
#   live-check.sh [--apply] [--dir DIR] N
#
# Without --apply it reads and prints what it would do, and writes nothing:
#   relabel: <gh issue edit command>   or  relabel: none, #N is already <human>
#   parent: #P                         or  parent: none
#   reorder: <gh api PATCH command>    or  reorder: none, <why>
#   after: #M, the last open <agent> child of #P   (only with a reorder)
# With --apply it then runs the relabel and the reorder, in that order, and
# ends on `applied: <what ran>` (`applied: nothing` when neither was needed).
#
# The label strings come from DIR's docs/agents/triage-labels.md, as in
# resuming's state.sh. The parent's sub-issues are read over every page:
# the first page can hold only closed children. The ids in the reorder are
# database ids, not # numbers.
#
# Exits 0 on success. Exits 1 on a usage error, a read that fails (nothing
# is written then), or a write that fails (the error names what had already
# run).

set -u

APPLY=0
DIR=.
N=
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --dir) [ $# -ge 2 ] || fail "--dir needs a value"; DIR=$2; shift 2 ;;
        --help)
            printf 'Usage: live-check.sh [--apply] [--dir DIR] N\n'
            printf 'Relabels #N ready-for-human and moves it after its parent'"'"'s last open ready-for-agent child.\n'
            exit 0 ;;
        -*) fail "unknown option: $1" ;;
        *) [ -z "$N" ] || fail "one ticket number only"; N=$1; shift ;;
    esac
done
[ -n "$N" ] || fail "a ticket number is required"
case $N in *[!0-9]*) fail "not a ticket number: $N" ;; esac
cd "$DIR" 2>/dev/null || fail "not a directory: $DIR"

# Label string for a triage role, as state.sh reads it.
label_for() {
    l=
    if [ -f docs/agents/triage-labels.md ]; then
        l=$(awk -F'|' -v role="$1" '
            { r = $2; s = $3; gsub(/[ `]/, "", r); gsub(/[ `]/, "", s) }
            r == role && s != "" { print s; exit }' docs/agents/triage-labels.md)
    fi
    printf '%s' "${l:-$1}"
}
agent=$(label_for ready-for-agent)
human=$(label_for ready-for-human)

errs=$(mktemp) || fail "mktemp failed"
trap 'command rm -f "$errs"' EXIT
gh_err() { head -n 1 "$errs"; }

ticket=$(gh api "repos/{owner}/{repo}/issues/$N" 2>"$errs") &&
    printf '%s' "$ticket" | jq -e '.id' >/dev/null 2>&1 ||
    fail "could not read #$N: $(gh_err)"
id=$(printf '%s' "$ticket" | jq -r '.id')
labels=$(printf '%s' "$ticket" | jq -c '[.labels[].name]')

has_label() { printf '%s' "$labels" | jq -e --arg l "$1" 'index($l)' >/dev/null; }

# The gh arguments stay in variables; the printed commands are for display
# only, so a label string read from the docs is never run as shell.
remove= add= relabel=
has_label "$agent" && remove=$agent
has_label "$human" || add=$human
if [ -n "$remove$add" ]; then
    relabel="gh issue edit $N${remove:+ --remove-label $remove}${add:+ --add-label $add}"
fi

# The parent: a 404 means none; any other failure stops before any write.
parent=
if p=$(gh api "repos/{owner}/{repo}/issues/$N/parent" 2>"$errs"); then
    parent=$(printf '%s' "$p" | jq -r '.number // empty' 2>/dev/null)
    [ -n "$parent" ] || fail "could not read #$N's parent: no number in the reply"
elif ! grep -q -e 'HTTP 404' -e 'No parent issue found' "$errs"; then
    fail "could not read #$N's parent: $(gh_err)"
fi

reorder= after= after_id= why=
if [ -z "$parent" ]; then
    why="#$N has no parent"
else
    subs=$(gh api --paginate "repos/{owner}/{repo}/issues/$parent/sub_issues?per_page=100" 2>"$errs") &&
        subs=$(printf '%s' "$subs" | jq -cs 'add // []' 2>/dev/null) &&
        printf '%s' "$subs" | jq -e 'type == "array"' >/dev/null 2>&1 ||
        fail "could not read #$parent's sub-issues: $(gh_err)"
    # The last open ready-for-agent child, if it comes after #N.
    last=$(printf '%s' "$subs" | jq -c --argjson n "$N" --arg a "$agent" '
        [.[] | select(.state == "open")] as $open
        | ($open | map(.number) | index($n)) as $at
        | [$open | to_entries[]
           | select(.value.number != $n and (.value.labels | map(.name) | index($a)))]
        | last // empty
        | select($at == null or .key > $at)
        | .value | {number, id}')
    if [ -n "$last" ]; then
        after=$(printf '%s' "$last" | jq -r .number)
        after_id=$(printf '%s' "$last" | jq -r .id)
        reorder="gh api --method PATCH 'repos/{owner}/{repo}/issues/$parent/sub_issues/priority' -F sub_issue_id=$id -F after_id=$after_id"
    else
        why="no open $agent child of #$parent follows #$N"
    fi
fi

if [ -n "$relabel" ]; then echo "relabel: $relabel"; else echo "relabel: none, #$N is already $human"; fi
if [ -n "$parent" ]; then echo "parent: #$parent"; else echo "parent: none"; fi
if [ -n "$reorder" ]; then
    echo "reorder: $reorder"
    echo "after: #$after, the last open $agent child of #$parent"
else
    echo "reorder: none, $why"
fi
[ "$APPLY" = 1 ] || exit 0

applied=
if [ -n "$relabel" ]; then
    set -- "$N"
    [ -n "$remove" ] && set -- "$@" --remove-label "$remove"
    [ -n "$add" ] && set -- "$@" --add-label "$add"
    gh issue edit "$@" >/dev/null 2>"$errs" ||
        fail "the relabel failed, so nothing was moved: $(gh_err)"
    applied=relabel
fi
if [ -n "$reorder" ]; then
    gh api --method PATCH "repos/{owner}/{repo}/issues/$parent/sub_issues/priority" \
        -F "sub_issue_id=$id" -F "after_id=$after_id" >/dev/null 2>"$errs" ||
        fail "the reorder failed${applied:+ after the relabel ran}: $(gh_err)"
    applied="${applied:+$applied, }reorder"
fi
echo "applied: ${applied:-nothing}"
