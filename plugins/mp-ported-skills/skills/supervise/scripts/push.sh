#!/bin/sh
# push.sh -- push a stopped worker's commits for the maintainer, after
# checking them (#100).
#
# A worker with no standing grant ends its turn on `Waiting on: git push
# ...`, and the #66 hook and the git wrappers refuse its own push. The
# maintainer approves the push in the supervisor's attended session, and the
# supervisor runs this: one named, checked action, rather than an ad hoc
# `git push` (docs/adr/0007). It pushes only DIR's current branch, to its
# upstream, and only the commit it checked.
#
# Checks, each printed as `ok <check>: ...` or `fail <check>: ...`:
#   marker        no worker marker in the checkout (the worker was stopped
#                 and release.sh run)
#   tree          no uncommitted or untracked paths
#   fast-forward  after a fetch, HEAD is ahead of the upstream and not behind
#   start         START is on the upstream, so nothing from before the
#                 worker's start goes out with its commits
#   version       every .claude-plugin/plugin.json the range changes moves
#                 by a patch bump at most
#   sweep         the --sweep command, run in DIR with `--range UP..HEAD`
#                 appended, exits 0; on a hit its output follows, indented.
#                 CMD is shell code: give one command, since the range is
#                 appended to its last one
# Before them it prints `push <branch> to <upstream>: UP..HEAD` and a
# `commit <sha> <subject>` line for each commit in the range.
#
# Without --check, when every check passes, it pushes and prints `pushed
# <upstream> UP..HEAD`, and appends `ID <upstream> UP HEAD <time>` to the
# checkout's `git rev-parse --git-path mp-supervise-pushed`, which
# actions.sh reads to name the push as the supervisor's, not the worker's,
# and record.sh to keep the worker's wait for it off the waits on a human;
# a `note` line follows when that write fails.
# A push is refused in a background session (CLAUDE_CODE_SESSION_ATTENDED=0):
# there a push goes only on a standing grant.
#
# Usage:
#   push.sh --dir DIR --id ID --start SHA (--sweep CMD | --no-sweep) [--check]
#
# Exits 0 when every check passed (and, without --check, the push landed);
# 1 on a usage error or in a background session; 2 when a check failed,
# with nothing pushed; 3 when the push itself failed.

set -u

DIR=""
ID=""
START=""
SWEEP=""
NO_SWEEP=0
CHECK=0

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --start)    need_value "$@"; START="$2"; shift 2 ;;
        --sweep)    need_value "$@"; SWEEP="$2"; shift 2 ;;
        --no-sweep) NO_SWEEP=1; shift ;;
        --check)    CHECK=1; shift ;;
        --help)
            printf 'Usage: push.sh --dir DIR --id ID --start SHA (--sweep CMD | --no-sweep) [--check]\n'
            printf 'Checks a stopped worker'\''s commits and, without --check, pushes them to the branch'\''s upstream.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$ID" ] || fail "--id is required"
[ -n "$START" ] || fail "--start is required"
if [ -n "$SWEEP" ] && [ "$NO_SWEEP" = 1 ]; then
    fail "give --sweep or --no-sweep, not both"
fi
[ -n "$SWEEP" ] || [ "$NO_SWEEP" = 1 ] ||
    fail "--sweep CMD is required, or --no-sweep to push with the range unswept"
[ -d "$DIR" ] || fail "not a directory: $DIR"
if [ "$CHECK" = 0 ] && [ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ]; then
    fail "push.sh pushes for the maintainer's attended session; a background session pushes only on a standing grant"
fi
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $DIR"
START=$(git -C "$DIR" rev-parse -q --verify "$START^{commit}") || fail "not a commit in $DIR: $START"

failed=0
ok() { printf 'ok %s\n' "$1"; }
bad() { printf 'fail %s\n' "$1"; failed=1; }
short() { git -C "$DIR" rev-parse --short "$1"; }

branch=$(git -C "$DIR" symbolic-ref -q --short HEAD) || { bad "branch: HEAD is detached"; exit 2; }
remote=$(git -C "$DIR" config "branch.$branch.remote")
merge=$(git -C "$DIR" config "branch.$branch.merge")
if [ -z "$remote" ] || [ -z "$merge" ]; then
    bad "branch: $branch has no upstream"
    exit 2
fi
if ! err=$(git -C "$DIR" fetch -q "$remote" 2>&1); then
    bad "fetch: git fetch $remote failed: $(printf '%s\n' "$err" | head -n 1)"
    exit 2
fi
upname=$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) ||
    { bad "branch: $branch's upstream $remote/${merge#refs/heads/} does not exist"; exit 2; }
up=$(git -C "$DIR" rev-parse '@{u}')
tip=$(git -C "$DIR" rev-parse HEAD)
range="$(short "$up")..$(short "$tip")"

echo "push $branch to $upname: $range"
git -C "$DIR" log --format='commit %h %s' "$up..$tip"

marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker)
if [ -f "$marker" ]; then
    bad "marker: worker $(head -n 1 "$marker") still holds the checkout; stop it and release its marker first"
else
    ok "marker: no worker marker in the checkout"
fi

if ! status=$(git -C "$DIR" status --porcelain 2>&1); then
    bad "tree: git status failed: $(printf '%s\n' "$status" | head -n 1)"
else
    dirty=$(printf '%s' "$status" | grep -c '^')
    case "$dirty" in
        0) ok "tree: clean" ;;
        1) bad "tree: 1 uncommitted path" ;;
        *) bad "tree: $dirty uncommitted paths" ;;
    esac
fi

counts=$(git -C "$DIR" rev-list --left-right --count "$up...$tip")
behind=${counts%%[[:space:]]*}
ahead=${counts##*[[:space:]]}
if [ "$behind" != 0 ]; then
    bad "fast-forward: $ahead ahead of $upname, $behind behind"
elif [ "$ahead" = 0 ]; then
    bad "fast-forward: nothing to push, 0 ahead of $upname"
else
    ok "fast-forward: $ahead ahead of $upname, 0 behind"
fi

if git -C "$DIR" merge-base --is-ancestor "$START" "$up"; then
    ok "start: $(short "$START") is on $upname"
else
    before=$(git -C "$DIR" rev-list --count "$up..$START")
    if [ "$before" = 1 ]; then n="1 commit"; else n="$before commits"; fi
    bad "start: $(short "$START") is not on $upname; $n before the worker's start would go too"
fi

# version_parts <version>: "major minor patch", or empty when not X.Y.Z.
version_parts() {
    printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2 \3/p'
}
manifests=$(git -C "$DIR" diff --name-only "$up" "$tip" -- '*.claude-plugin/plugin.json')
if [ -z "$manifests" ]; then
    ok "version: no plugin version change"
fi
for f in $manifests; do
    new=$(git -C "$DIR" show "${tip}:$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    old=$(git -C "$DIR" show "${up}:$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [ -z "$old" ]; then
        ok "version: $f new at ${new:-no version}"
        continue
    elif [ -z "$new" ]; then
        ok "version: $f removed, was $old"
        continue
    elif [ "$old" = "$new" ]; then
        ok "version: $f $old (no bump)"
        continue
    fi
    o=$(version_parts "$old")
    v=$(version_parts "$new")
    if [ -n "$o" ] && [ -n "$v" ] && [ "${o% *}" = "${v% *}" ] && [ "${v##* }" -gt "${o##* }" ]; then
        ok "version: $f $old -> $new (patch)"
    else
        bad "version: $f $old -> ${new:-none} is past a patch bump"
    fi
done

if [ "$NO_SWEEP" = 1 ]; then
    echo "skip sweep: --no-sweep given, the range was not swept"
else
    swept=$(cd "$DIR" && sh -c "$SWEEP"' --range "$1"' sh "$up..$tip" </dev/null 2>&1)
    rc=$?
    if [ "$rc" = 0 ]; then
        ok "sweep: clean over $range"
    else
        bad "sweep: exit $rc over $range"
        printf '%s\n' "$swept" | sed 's/^/  /'
    fi
fi

[ "$failed" = 0 ] || exit 2
[ "$CHECK" = 0 ] || exit 0

if ! err=$(git -C "$DIR" push -q "$remote" "$tip:$merge" 2>&1); then
    printf '%s\n' "$err" >&2
    printf 'Error: git push %s %s:%s failed\n' "$remote" "$(short "$tip")" "$merge" >&2
    exit 3
fi
echo "pushed $upname $range"
record=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-pushed)
printf '%s %s %s %s %s\n' "$ID" "$upname" "$up" "$tip" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$record" ||
    echo "note the push was not recorded in $record, so actions.sh will read $upname as the worker's ungranted push"
