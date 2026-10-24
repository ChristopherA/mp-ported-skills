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
# A Project that names a Distribution repo (distribution.sh, #125) has that
# repo checked and pushed too (#141): the same checks over its current
# branch, from DIST_START, the commit the worker started from there (the
# snapshot's `dist head` line). Every check runs in both repos before
# anything is pushed, and a failure in either pushes neither. A repo with
# nothing to push is passed over, as long as the other has something. Each
# line then names its repo after its first word: `push project ...`,
# `commit distribution ...`, `ok project marker: ...`.
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
#   sweep         the --sweep command, run in the repo with `--range
#                 UP..HEAD` appended, exits 0; on a hit its output follows,
#                 indented. CMD is shell code: give one command, since the
#                 range is appended to its last one. A repo with nothing to
#                 push is not swept: `ok sweep: nothing to push`
#   test          the --test command in the Project, or the --dist-test
#                 command in the Distribution repo, run there with sh -c,
#                 exits 0: `ok test: CMD`. On a failure, `fail test: CMD`
#                 and the suite's last 40 lines, indented, after a note of
#                 how many came before. A repo with nothing to push is not
#                 tested: `ok test: nothing to push`. Without the option,
#                 no test line
#   prose         with --checked only: no file the range adds, changes or
#                 removes is prose, a README* or CHANGELOG* file, a file
#                 under a docs/ folder, or a *.md file, at any depth:
#                 `ok prose: no README, CHANGELOG, docs/ or .md file
#                 changed`, or `fail prose: N files: <path>, <path>`. A
#                 repo with nothing to push is not read: `ok prose: nothing
#                 to push`
# Before them it prints `push <branch> to <upstream>: UP..HEAD` and a
# `commit <sha> <subject>` line for each commit in the range.
#
# Without --check, when every check passes, it pushes and prints `pushed
# <upstream> UP..HEAD`, and appends `ID <upstream> UP HEAD <time>` to the
# checkout's `git rev-parse --git-path mp-supervise-pushed`, which
# actions.sh reads to name the push as the supervisor's, not the worker's,
# and record.sh to keep the worker's wait for it off the waits on a human;
# a `note` line follows when that write fails. A Distribution repo's push
# is recorded there too, as `distribution:<upstream>`, so it names no
# branch of DIR's. With two repos to push, both are tried with --dry-run
# before either is pushed, so a remote that cannot be reached, or a ref it
# would refuse as not a fast-forward, pushes neither. A dry run runs no hook
# or branch rule on the remote, and two remotes cannot be pushed as one:
# when the second push is still refused, the first stays pushed, and the
# error says so.
# A push is refused in a background session (CLAUDE_CODE_SESSION_ATTENDED=0):
# there a push goes only on a standing grant.
#
# --checked is the checked push (#188): the supervisor pushes with no
# question to the maintainer, under the Project's `checked-push` grant,
# which grant.sh reads from origin's default branch. It needs that grant,
# --sweep, --test, and --dist-test with a Distribution repo, since the push
# goes unread on the strength of those checks; it adds the prose check, and
# records each push with ` checked-push`, a tab, the grant's citation, a
# tab, and that repo's check lines joined by `; `, after the time.
#
# Usage:
#   push.sh --dir DIR --id ID --start SHA [--dist-start SHA] (--sweep CMD | --no-sweep)
#           [--test CMD] [--dist-test CMD] [--checked] [--check]
#
# --dist-start is required when DIR names a Distribution repo, and refused
# when it names none; --dist-test is refused when it names none.
#
# Exits 0 when every check passed (and, without --check, the push landed);
# 1 on a usage error or in a background session; 2 when a check failed,
# with nothing pushed; 3 when a push itself failed; 4, with --checked, when
# the prose check was the only one that failed, with nothing pushed: the
# push goes on the maintainer's approval instead, without --checked.

set -u
. "$(dirname -- "$0")/marker.sh"

DIR=""
ID=""
START=""
DIST_START=""
SWEEP=""
NO_SWEEP=0
TEST=""
DIST_TEST=""
CHECK=0
CHECKED=0

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)        need_value "$@"; DIR="$2"; shift 2 ;;
        --id)         need_value "$@"; ID="$2"; shift 2 ;;
        --start)      need_value "$@"; START="$2"; shift 2 ;;
        --dist-start) need_value "$@"; DIST_START="$2"; shift 2 ;;
        --sweep)      need_value "$@"; SWEEP="$2"; shift 2 ;;
        --no-sweep)   NO_SWEEP=1; shift ;;
        --test)       need_value "$@"; TEST="$2"; shift 2 ;;
        --dist-test)  need_value "$@"; DIST_TEST="$2"; shift 2 ;;
        --check)      CHECK=1; shift ;;
        --checked)    CHECKED=1; shift ;;
        --help)
            printf 'Usage: push.sh --dir DIR --id ID --start SHA [--dist-start SHA] (--sweep CMD | --no-sweep) [--test CMD] [--dist-test CMD] [--checked] [--check]\n'
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

# The Distribution repo, read from origin as launch.sh read it: the marker
# that also names it is gone by now, since the marker check needs it gone.
DIST=$(sh "$(dirname -- "$0")/distribution.sh" --dir "$DIR" </dev/null) ||
    fail "distribution.sh failed, so the Distribution repo is unknown"
if [ -n "$DIST" ]; then
    [ -n "$DIST_START" ] ||
        fail "--dist-start is required: $DIR names Distribution repo $DIST (give the snapshot's dist head line)"
    [ -d "$DIST" ] || fail "Distribution repo $DIST, named in docs/agents/distribution-repo.md, is missing"
    git -C "$DIST" rev-parse --git-dir >/dev/null 2>&1 || fail "Distribution repo $DIST is not a git checkout"
    DIST_START=$(git -C "$DIST" rev-parse -q --verify "$DIST_START^{commit}") ||
        fail "not a commit in Distribution repo $DIST: $DIST_START"
elif [ -n "$DIST_START" ]; then
    fail "--dist-start given, but $DIR names no Distribution repo"
elif [ -n "$DIST_TEST" ]; then
    fail "--dist-test given, but $DIR names no Distribution repo"
fi

CITATION=""
if [ "$CHECKED" = 1 ]; then
    [ "$NO_SWEEP" = 0 ] || fail "--checked needs --sweep: a checked push is not read by anyone, so its range is swept"
    [ -n "$TEST" ] || fail "--checked needs --test: a checked push counts on the suite passing"
    [ -z "$DIST" ] || [ -n "$DIST_TEST" ] ||
        fail "--checked needs --dist-test: $DIR names Distribution repo $DIST, and a checked push counts on its suite passing"
    errs=$(mktemp) || fail "mktemp failed, so the checked-push grant cannot be read"
    CITATION=$(sh "$(dirname -- "$0")/grant.sh" --dir "$DIR" --action checked-push </dev/null 2>"$errs")
    granted=$?
    command cat "$errs" >&2
    command rm -f "$errs"
    [ "$granted" = 0 ] && [ -n "$CITATION" ] ||
        fail "--checked needs a checked-push grant in docs/agents/supervision.md on origin's default branch, and $DIR has none"
    CITATION=$(printf '%s' "$CITATION" | tr '\t' ' ')
fi

failed=0
prose_failed=0
# The ok lines of the repo being checked, joined by "; ", for the record.
rchecks=""
ok() { printf 'ok %s%s\n' "$label" "$1"; rchecks="${rchecks:+$rchecks; }ok $label$1"; }
bad() { printf 'fail %s%s\n' "$label" "$1"; failed=1; }

# prose_files <repo> <up> <tip>: the paths the range adds, changes or
# removes that are prose, one a line. Returns 1 when git diff fails, so an
# unread range never reads as one with no prose.
prose_files() {
    names=$(git -C "$1" diff --no-renames --name-only "$2" "$3") || return 1
    printf '%s\n' "$names" | while IFS= read -r p; do
        case "/$p" in
            (*/README* | */CHANGELOG* | */docs/* | *.[mM][dD]) printf '%s\n' "$p" ;;
        esac
    done
}

# version_parts <version>: "major minor patch", or empty when not X.Y.Z.
version_parts() {
    printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2 \3/p'
}

# check_repo <repo> <start> <label> <test>: print the repo's push line, commits and
# checks, each named by <label> ("" with one repo). Sets remote, merge, up,
# tip, upname, range and ahead for the push; returns 1, with failed set,
# when the repo cannot be read far enough to check its commits.
check_repo() {
    repo=$1 rstart=$2 label=$3 rtest=$4
    short() { git -C "$repo" rev-parse --short "$1"; }
    ahead=0
    rchecks=""
    branch=$(git -C "$repo" symbolic-ref -q --short HEAD) || { bad "branch: HEAD is detached"; return 1; }
    remote=$(git -C "$repo" config "branch.$branch.remote")
    merge=$(git -C "$repo" config "branch.$branch.merge")
    if [ -z "$remote" ] || [ -z "$merge" ]; then
        bad "branch: $branch has no upstream"
        return 1
    fi
    if ! err=$(git -C "$repo" fetch -q "$remote" 2>&1); then
        bad "fetch: git fetch $remote failed: $(printf '%s\n' "$err" | head -n 1)"
        return 1
    fi
    upname=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) ||
        { bad "branch: $branch's upstream $remote/${merge#refs/heads/} does not exist"; return 1; }
    up=$(git -C "$repo" rev-parse '@{u}')
    tip=$(git -C "$repo" rev-parse HEAD)
    range="$(short "$up")..$(short "$tip")"

    echo "push $label$branch to $upname: $range"
    git -C "$repo" log --format="commit $label%h %s" "$up..$tip"

    marker=$(marker_path "$repo")
    if [ -f "$marker" ]; then
        bad "marker: worker $(head -n 1 "$marker") still holds the checkout; stop it and release its marker first"
    else
        ok "marker: no worker marker in the checkout"
    fi

    if ! status=$(git -C "$repo" status --porcelain 2>&1); then
        bad "tree: git status failed: $(printf '%s\n' "$status" | head -n 1)"
    else
        dirty=$(printf '%s' "$status" | grep -c '^')
        case "$dirty" in
            0) ok "tree: clean" ;;
            1) bad "tree: 1 uncommitted path" ;;
            *) bad "tree: $dirty uncommitted paths" ;;
        esac
    fi

    counts=$(git -C "$repo" rev-list --left-right --count "$up...$tip")
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    if [ "$behind" != 0 ]; then
        bad "fast-forward: $ahead ahead of $upname, $behind behind"
    elif [ "$ahead" = 0 ] && [ -n "$label" ]; then
        # With two repos, one may have nothing to go; below, one of them
        # must have something.
        ok "fast-forward: nothing to push, 0 ahead of $upname"
    elif [ "$ahead" = 0 ]; then
        bad "fast-forward: nothing to push, 0 ahead of $upname"
    else
        ok "fast-forward: $ahead ahead of $upname, 0 behind"
    fi

    if git -C "$repo" merge-base --is-ancestor "$rstart" "$up"; then
        ok "start: $(short "$rstart") is on $upname"
    else
        before=$(git -C "$repo" rev-list --count "$up..$rstart")
        if [ "$before" = 1 ]; then n="1 commit"; else n="$before commits"; fi
        bad "start: $(short "$rstart") is not on $upname; $n before the worker's start would go too"
    fi

    manifests=$(git -C "$repo" diff --name-only "$up" "$tip" -- '*.claude-plugin/plugin.json')
    if [ -z "$manifests" ]; then
        ok "version: no plugin version change"
    fi
    for f in $manifests; do
        new=$(git -C "$repo" show "${tip}:$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
        old=$(git -C "$repo" show "${up}:$f" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
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
        echo "skip ${label}sweep: --no-sweep given, the range was not swept"
    elif [ "$ahead" = 0 ]; then
        # An empty range has nothing to sweep, and a sweep may refuse one.
        ok "sweep: nothing to push"
    else
        swept=$(CDPATH= cd -- "$repo" && sh -c "$SWEEP"' --range "$1"' sh "$up..$tip" </dev/null 2>&1)
        rc=$?
        if [ "$rc" = 0 ]; then
            ok "sweep: clean over $range"
        else
            bad "sweep: exit $rc over $range"
            printf '%s\n' "$swept" | sed 's/^/  /'
        fi
    fi

    if [ -z "$rtest" ]; then
        :
    elif [ "$ahead" = 0 ]; then
        # Nothing goes out from this repo, so its suite gates nothing.
        ok "test: nothing to push"
    else
        tested=$(CDPATH= cd -- "$repo" && sh -c "$rtest" </dev/null 2>&1)
        rc=$?
        if [ "$rc" = 0 ]; then
            ok "test: $rtest"
        else
            bad "test: $rtest"
            # A whole suite's output would fill the supervisor's context;
            # its failures and summary come last.
            if [ -n "$tested" ]; then
                lines=$(printf '%s\n' "$tested" | grep -c '^')
                if [ "$lines" -gt 40 ]; then
                    echo "  ... $((lines - 40)) earlier lines not shown"
                fi
                printf '%s\n' "$tested" | tail -n 40 | sed 's/^/  /'
            fi
        fi
    fi

    if [ "$CHECKED" = 0 ]; then
        :
    elif [ "$ahead" = 0 ]; then
        ok "prose: nothing to push"
    else
        if ! prose=$(prose_files "$repo" "$up" "$tip"); then
            bad "prose: git diff failed, so the changed files are unknown"
        elif [ -z "$prose" ]; then
            ok "prose: no README, CHANGELOG, docs/ or .md file changed"
        else
            k=$(printf '%s\n' "$prose" | grep -c '^')
            if [ "$k" = 1 ]; then n="1 file"; else n="$k files"; fi
            # Its own failure: the push still goes, on the maintainer's yes.
            printf 'fail %sprose: %s: %s\n' "$label" "$n" "$(printf '%s\n' "$prose" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
            prose_failed=1
        fi
    fi
}

# Each repo's push: <remote> <merge> <up> <tip> <upname> <range> <repo>,
# one line each, for the repos with something to push.
pushes=""
if [ -z "$DIST" ]; then
    check_repo "$DIR" "$START" "" "$TEST" || exit 2
    pushes="$remote $merge $up $tip $upname $range $DIR"
    project_checks=$rchecks
else
    if check_repo "$DIR" "$START" "project " "$TEST" && [ "$ahead" != 0 ]; then
        pushes="$remote $merge $up $tip $upname $range $DIR"
    fi
    project_checks=$rchecks
    if check_repo "$DIST" "$DIST_START" "distribution " "$DIST_TEST" && [ "$ahead" != 0 ]; then
        pushes="${pushes:+$pushes
}$remote $merge $up $tip $upname $range $DIST"
    fi
    dist_checks=$rchecks
    label=""
    [ "$failed" = 1 ] || [ -n "$pushes" ] || bad "fast-forward: nothing to push in the Project or its Distribution repo"
fi

[ "$failed" = 0 ] || exit 2
[ "$prose_failed" = 0 ] || exit 4
[ "$CHECK" = 0 ] || exit 0

# repo_name <repo>: how a pushed line names it.
repo_name() { if [ "$1" = "$DIR" ]; then echo "$2"; else echo "distribution:$2"; fi; }

if [ -n "$DIST" ]; then
    printf '%s\n' "$pushes" | while read -r remote merge up tip upname range repo; do
        if ! err=$(git -C "$repo" push -q --dry-run "$remote" "$tip:$merge" 2>&1); then
            printf '%s\n' "$err" >&2
            printf 'Error: git push --dry-run %s %s:%s failed in %s, so neither repo was pushed\n' "$remote" "$range" "$merge" "$repo" >&2
            exit 3
        fi
    done || exit 3
fi

record=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-pushed)
landed=""
printf '%s\n' "$pushes" | {
    while read -r remote merge up tip upname range repo; do
        if ! err=$(git -C "$repo" push -q "$remote" "$tip:$merge" 2>&1); then
            printf '%s\n' "$err" >&2
            printf 'Error: git push %s %s:%s failed in %s\n' "$remote" "$(git -C "$repo" rev-parse --short "$tip")" "$merge" "$repo" >&2
            [ -z "$landed" ] || printf 'Error: %s was already pushed\n' "$landed" >&2
            exit 3
        fi
        name=$(repo_name "$repo" "$upname")
        echo "pushed $name $range"
        landed="${landed:+$landed, }$name"
        mark=""
        if [ "$CHECKED" = 1 ]; then
            if [ "$repo" = "$DIR" ]; then c=$project_checks; else c=$dist_checks; fi
            mark=$(printf ' checked-push\t%s\t%s' "$CITATION" "$(printf '%s' "$c" | tr '\t' ' ')")
        fi
        printf '%s %s %s %s %s%s\n' "$ID" "$name" "$up" "$tip" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mark" >>"$record" ||
            echo "note the push was not recorded in $record, so actions.sh will read $name as the worker's ungranted push"
    done
} || exit 3
