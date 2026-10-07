#!/bin/sh
# before-clear.test.sh -- tests for the capturing skill's before-clear.sh
# (#89): whether its closing question can be asked, and whether one job in
# it may run unasked.
#
# Builds a scratch repo with a bare remote, the same shape grant.test.sh
# uses, since an unattended "push" or "issue-close" check reads
# origin/<default> through supervise's grant.sh. Touches nothing outside
# its own mktemp directory.
#
# Usage: sh tests/before-clear.test.sh

set -u

# Run inside a background session, the git wrappers it inherits would
# refuse the scratch pushes below (docs/adr/0006); unset, they pass
# everything. Each check below sets CLAUDE_CODE_SESSION_ATTENDED back to
# what it wants the script itself to see.
unset CLAUDE_CODE_SESSION_ATTENDED

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/capturing/scripts/before-clear.sh"
work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'command rm -rf "$work"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}
commit_file() { # <folder> <path> <content> <message> -- write, add and commit
    mkdir -p "$(dirname "$1/$2")"
    printf '%s' "$3" >"$1/$2"
    repo_git "$1" add "$2"
    repo_git "$1" commit -q -m "$4"
}
push_main() { repo_git "$1" push -q origin main 2>/dev/null; }

remote="$work/remote.git"
repo="$work/repo"
git init -q --bare "$remote"
git init -q -b main "$repo"
repo_git "$repo" commit -q --allow-empty -m start
repo_git "$repo" remote add origin "$remote"
push_main "$repo"
git -C "$repo" remote set-head origin main
commit_file "$repo" docs/agents/supervision.md '## Grants

- push
' "add a push grant"
push_main "$repo"

bc() { CLAUDE_CODE_SESSION_ATTENDED="$1" sh "$script" --action "$2" --dir "${3:-$repo}" </dev/null; } # <attended> <action> [dir]

# Someone can answer: attended, whatever the action or dir, no grant read.
for attended in '' 1 2; do
    out=$(bc "$attended" push "$work/not-a-repo"); rc=$?
    check "attended ($attended): exit 0" "0" "$rc"
    check "attended ($attended): prints attended" "attended" "$out"
done

# Nobody can answer, and the job maps to no shared action: always ungranted,
# no git checkout needed.
out=$(bc 0 other "$work/not-a-repo"); rc=$?
check "unattended, other: exit 0" "0" "$rc"
check "unattended, other: ungranted" "ungranted" "$out"

# Unattended, the action is standing-granted on the committed default branch.
out=$(bc 0 push); rc=$?
check "unattended, granted: exit 0" "0" "$rc"
check "unattended, granted: cites the action" "granted: push" "$out"

# A push in a Distribution repo (#141) is its own action: the push grant
# does not cover it.
out=$(bc 0 distribution-push); rc=$?
check "unattended, distribution-push beside a push grant: ungranted" "0 ungranted" "$rc $out"

# Unattended, the action has no matching grant.
out=$(bc 0 issue-close); rc=$?
check "unattended, ungranted: exit 0" "0" "$rc"
check "unattended, ungranted: prints ungranted" "ungranted" "$out"

# A capture's findings (#110): a comment on an open ticket maps to
# issue-comment and a new ticket to issue-create, each granted or not on
# its own, the same as a push. Attended, both still ask.
for action in issue-comment issue-create; do
    out=$(bc 0 "$action"); rc=$?
    check "unattended, no $action grant: exit 0" "0" "$rc"
    check "unattended, no $action grant: ungranted" "ungranted" "$out"
    check "attended, $action: still asks" "attended" "$(bc 1 "$action")"
done
commit_file "$repo" docs/agents/supervision.md '## Grants

- push
- issue-comment: findings for open tickets
- issue-create
' "grant the capture's findings"
push_main "$repo"
out=$(bc 0 issue-comment); rc=$?
check "unattended, issue-comment granted: exit 0" "0" "$rc"
check "unattended, issue-comment granted: cites the grant" "granted: issue-comment: findings for open tickets" "$out"
check "unattended, issue-create granted: cites the grant" "granted: issue-create" "$(bc 0 issue-create)"
check "attended, issue-comment granted: still asks" "attended" "$(bc 1 issue-comment)"

# Unattended, a pushed grant exists but on another ref: a working-tree-only
# grant is ignored the way grant.sh ignores it, with the same note, and the
# job still reads ungranted, not granted.
printf '## Grants\n\n- issue-close\n' >"$repo/docs/agents/supervision.md"
out=$(bc 0 issue-close 2>&1); rc=$?
check "unattended, working-tree-only grant: still ungranted" "0" "$rc"
check "unattended, working-tree-only grant: noted, then ungranted" \
"note: docs/agents/supervision.md grants issue-close on the working tree or current branch, not on the committed origin/main; ignored
ungranted" "$out"
repo_git "$repo" checkout -q -- docs/agents/supervision.md

# Unattended, DIR exists but is not a git checkout: grant.sh's own Error,
# not a silent ungranted.
plain="$work/plain-dir"
mkdir -p "$plain"
out=$(bc 0 push "$plain" 2>&1); rc=$?
check "unattended, not a checkout: exit 1" "1" "$rc"
check "unattended, not a checkout: Error, not ungranted" \
    "Error: not a git checkout: $plain" "$out"

# DIR defaults to the working directory.
out=$(cd "$repo" && CLAUDE_CODE_SESSION_ATTENDED=0 sh "$script" --action push </dev/null); rc=$?
check "default dir: exit 0" "0" "$rc"
check "default dir: cites the action" "granted: push" "$out"

# Usage errors.
sh "$script" --action push --dir "$repo" --dir </dev/null >/dev/null 2>&1
check "refuses: --dir with no value" "1" "$?"
sh "$script" --dir "$repo" </dev/null >/dev/null 2>&1
check "refuses: no --action" "1" "$?"
sh "$script" --action bogus --dir "$repo" </dev/null >/dev/null 2>&1
check "refuses: bad --action" "1" "$?"

echo "before-clear: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
