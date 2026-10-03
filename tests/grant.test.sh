#!/bin/sh
# grant.test.sh -- tests for the supervise skill's grant.sh (#58): whether a
# shared action has a standing grant recorded in docs/agents/supervision.md,
# read only from the default branch as committed on origin.
#
# Builds a scratch repo with a bare remote, since grant.sh reads
# origin/<default>, never the working tree. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/grant.test.sh

set -u

# Run inside a background session, the git wrappers it inherits would refuse
# the scratch pushes below (docs/adr/0006); unset, they pass everything.
unset CLAUDE_CODE_SESSION_ATTENDED

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
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

grant() { sh "$scripts/grant.sh" --dir "$repo" --action "$1" </dev/null; } # <action>

# No supervision.md at all: ungranted, nothing printed.
out=$(grant push); rc=$?
check "no file: exit 1" "1" "$rc"
check "no file: nothing printed" "" "$out"

# A committed grant with no note.
commit_file "$repo" docs/agents/supervision.md \
'# Supervision

## Grants

- push
' "add a push grant"
push_main "$repo"
out=$(grant push); rc=$?
check "bare grant: exit 0" "0" "$rc"
check "bare grant: cites the action" "push" "$out"

out=$(grant pr-create); rc=$?
check "bare grant: an ungranted action still refuses" "1" "$rc"
check "bare grant: an ungranted action prints nothing" "" "$out"

# A grant with a note, alongside another action and a heading that ends the
# section.
commit_file "$repo" docs/agents/supervision.md \
'# Supervision

## Grants

- push: release branches only
- issue-close

## Notes

- push is not a note
' "add grants with a note and a trailing section"
push_main "$repo"
check "noted grant: cites the whole bullet" "push: release branches only" "$(grant push)"
check "noted grant: a second action in the same section" "issue-close" "$(grant issue-close)"

# A decoy bullet after the ## Grants section's closing heading is not read.
commit_file "$repo" docs/agents/supervision.md \
'## Grants

- push

## Notes

- issue-close is not a grant
' "a decoy bullet after the section"
push_main "$repo"
out=$(grant issue-close); rc=$?
check "decoy after the section: exit 1" "1" "$rc"
check "decoy after the section: nothing printed" "" "$out"

commit_file "$repo" docs/agents/supervision.md \
'## Grants

- push: release branches only
- issue-close
' "restore the two-grant file"
push_main "$repo"
out=$(grant pr-merge); rc=$?
check "noted grant: pr-merge not granted" "1" "$rc"
check "noted grant: pr-merge prints nothing" "" "$out"

# pr-merge, granted.
commit_file "$repo" docs/agents/supervision.md \
'## Grants

- pr-merge
' "grant pr-merge"
push_main "$repo"
check "pr-merge: cites the action" "pr-merge" "$(grant pr-merge)"

# issue-comment and issue-create (#110), each granted on its own.
commit_file "$repo" docs/agents/supervision.md \
'## Grants

- issue-comment: findings from a capture
' "grant issue-comment"
push_main "$repo"
check "issue-comment: cites the whole bullet" "issue-comment: findings from a capture" "$(grant issue-comment)"
out=$(grant issue-create); rc=$?
check "issue-comment: issue-create not granted" "1 " "$rc $out"
commit_file "$repo" docs/agents/supervision.md \
'## Grants

- issue-create
- pr-merge
' "grant issue-create"
push_main "$repo"
check "issue-create: cites the action" "issue-create" "$(grant issue-create)"
out=$(grant issue-comment); rc=$?
check "issue-create: issue-comment not granted" "1 " "$rc $out"
commit_file "$repo" docs/agents/supervision.md \
'## Grants

- pr-merge
' "back to pr-merge only"
push_main "$repo"

# A grant on the working tree, not committed to origin/main: ignored, with a
# note on stderr.
printf '## Grants\n\n- push\n' >"$repo/docs/agents/supervision.md"
# origin/main still holds the pr-merge-only commit above.
out=$(grant push 2>&1 >/dev/null); rc=$?
check "working-tree-only grant: still ungranted" "1" "$(grant push >/dev/null 2>&1; echo $?)"
check "working-tree-only grant: noted on stderr" \
    "note: docs/agents/supervision.md grants push on the working tree or current branch, not on the committed origin/main; ignored" "$out"
repo_git "$repo" checkout -q -- docs/agents/supervision.md

# A grant committed locally but never pushed: still ungranted, same note.
commit_file "$repo" docs/agents/supervision.md '## Grants

- push
' "local-only push grant"
out=$(grant push 2>&1 >/dev/null); rc=$?
check "local-only commit: still ungranted" "1" "$(grant push >/dev/null 2>&1; echo $?)"
check "local-only commit: noted on stderr" \
    "note: docs/agents/supervision.md grants push on the working tree or current branch, not on the committed origin/main; ignored" "$out"
repo_git "$repo" reset -q --hard origin/main

# No origin remote at all: ungranted, no crash.
norigin="$work/no-origin"
git init -q -b main "$norigin"
repo_git "$norigin" commit -q --allow-empty -m start
mkdir -p "$norigin/docs/agents"
printf '## Grants\n\n- push\n' >"$norigin/docs/agents/supervision.md"
repo_git "$norigin" add docs/agents/supervision.md
repo_git "$norigin" commit -q -m "add grant, never pushed anywhere"
out=$(sh "$scripts/grant.sh" --dir "$norigin" --action push 2>/dev/null </dev/null); rc=$?
check "no origin remote: exit 1" "1" "$rc"
check "no origin remote: nothing printed" "" "$out"
err=$(sh "$scripts/grant.sh" --dir "$norigin" --action push 2>&1 >/dev/null </dev/null)
check "no origin remote: a local grant is still noted, not an error" \
    "note: docs/agents/supervision.md grants push on the working tree or current branch, not on the committed origin/main; ignored" "$err"

# Usage errors.
for bad in "--dir $repo" "--action push" "--dir $repo --action bogus"; do
    # shellcheck disable=SC2086
    sh "$scripts/grant.sh" $bad </dev/null >/dev/null 2>&1
    check "refuses: $bad" "1" "$?"
done
sh "$scripts/grant.sh" --dir "$work/not-a-repo" --action push </dev/null >/dev/null 2>&1
check "refuses: not a git checkout" "1" "$?"

echo "grant: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
