#!/bin/sh
# deny-shared-actions.test.sh -- tests for the PreToolUse hook that refuses
# a shared action reached by an unattended, auto-mode background session
# (#66).
#
# Runs the command string from hooks.json, as Claude Code does, with a
# PreToolUse payload on stdin, CLAUDE_CODE_SESSION_ATTENDED set the way
# Claude Code sets it in a background session's own process, and
# CLAUDE_PLUGIN_ROOT pointed at this checkout. Touches nothing outside its
# own environment.
#
# Usage: sh tests/deny-shared-actions.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Every variable the hook reads, set or unset here. The hook runs
# `git config` to resolve aliases, so git reads no global or system config
# and no repo but the scratch one below, and the checks run from a folder
# outside any repo. MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS unset: left set in
# the calling session, it would skip the grant lookup below without a
# single test here asking for that -- the exact silent-skip the variable
# is designed to never cause from the hook's own default.
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS CLAUDE_CODE_SESSION_ATTENDED
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
outside=$(mktemp -d)
cd "$outside" || exit 1

entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("deny-shared-actions"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

run() { # <attended> <mode> <tool> <command> [<cwd>]: the hook's full JSON output
    payload=$(jq -cn --arg mode "$2" --arg tool "$3" --arg cmd "$4" --arg cwd "${5:-}" \
        '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:$mode,tool_name:$tool,tool_input:{command:$cmd}} + (if $cwd == "" then {} else {cwd: $cwd} end)')
    printf '%s' "$payload" | CLAUDE_CODE_SESSION_ATTENDED="$1" sh -c "$hook_cmd"
}

decision() { run "$1" "$2" Bash "$3" "${4:-}" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
reason() { run "$1" "$2" Bash "$3" "${4:-}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

# Each refused form, in a background session (unattended, auto mode).
check "git push" "deny" "$(decision 0 auto 'git push')"
check "git -C <dir> push" "deny" "$(decision 0 auto 'git -C some/dir push origin main')"
check "git push in a compound command" "deny" "$(decision 0 auto 'echo hi && git push')"
check "git push in a subshell" "deny" "$(decision 0 auto '(cd dir && git push) || echo failed')"
check "gh pr create" "deny" "$(decision 0 auto 'gh pr create --title x --body y')"
check "gh pr merge" "deny" "$(decision 0 auto 'gh pr merge 5 --squash')"
check "gh issue close" "deny" "$(decision 0 auto 'gh issue close 42 --comment done')"
check "git push with flags before push" "deny" "$(decision 0 auto 'git -c user.name=x -C repo push')"
check "env-prefixed git push" "deny" "$(decision 0 auto 'env FOO=bar git push')"
check "leading VAR=value before git push" "deny" "$(decision 0 auto 'FOO=bar git push')"
check "leading VAR=value before gh pr create" "deny" "$(decision 0 auto 'FOO=bar gh pr create --title x')"

# Forms that reach the same program another way: a path, a transparent
# wrapper, a nested shell, a substitution, or a git alias.
check "command git push" "deny" "$(decision 0 auto 'command git push')"
check "absolute path to git" "deny" "$(decision 0 auto '/usr/bin/git push')"
check "backslash-escaped git" "deny" "$(decision 0 auto '\git push')"
check "quoted program name" "deny" "$(decision 0 auto '"git" push')"
check "backtick substitution" "deny" "$(decision 0 auto 'x=`git push`')"
check "\$() substitution" "deny" "$(decision 0 auto 'echo $(git push 2>&1)')"
check "bash -c" "deny" "$(decision 0 auto 'bash -c "git push"')"
check "sh -c" "deny" "$(decision 0 auto "sh -c 'git push origin HEAD'")"
check "bash -lc with a compound command" "deny" "$(decision 0 auto 'bash -lc "cd repo && git push"')"
check "eval" "deny" "$(decision 0 auto 'eval "git push"')"
check "time" "deny" "$(decision 0 auto 'time git push')"
check "nohup" "deny" "$(decision 0 auto 'nohup git push &')"
check "xargs" "deny" "$(decision 0 auto 'echo origin | xargs git push')"
check "xargs with flags" "deny" "$(decision 0 auto 'echo origin | xargs -n 1 -I {} git push {}')"
check "exec" "deny" "$(decision 0 auto 'exec git push')"
check "builtin command chain" "deny" "$(decision 0 auto 'builtin command env git push')"
check "env -u NAME" "deny" "$(decision 0 auto 'env -u GIT_DIR git push')"
check "brace group" "deny" "$(decision 0 auto '{ git push; }')"
check "if/then" "deny" "$(decision 0 auto 'if true; then git push; fi')"
check "negated" "deny" "$(decision 0 auto '! git push')"
check "git push HEAD:main" "deny" "$(decision 0 auto 'git push origin HEAD:main')"
check "git push -u" "deny" "$(decision 0 auto 'git push -u origin some-branch')"
check "git push --dry-run" "deny" "$(decision 0 auto 'git push --dry-run')"
check "git -c alias defined inline" "deny" "$(decision 0 auto 'git -c alias.p=push p')"
check "command gh pr create" "deny" "$(decision 0 auto 'command gh pr create --fill')"
check "gh api merge (PUT)" "deny" "$(decision 0 auto 'gh api -X PUT repos/o/r/pulls/5/merge')"
check "gh api --method=PATCH issue" "deny" "$(decision 0 auto 'gh api --method=PATCH repos/o/r/issues/5 -f state=closed')"
check "gh api implicit POST to pulls" "deny" "$(decision 0 auto 'gh api repos/o/r/pulls -f title=x -f head=b -f base=main')"
check "gh api ref update" "deny" "$(decision 0 auto 'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc')"
check "gh api graphql mutation" "deny" \
    "$(decision 0 auto "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"

check "gh api contents PUT (a commit)" "deny" "$(decision 0 auto 'gh api -X PUT repos/o/r/contents/f.txt -f message=m -f content=Zg==')"
check "gh api git trees POST" "deny" "$(decision 0 auto 'gh api repos/o/r/git/trees -f base_tree=abc')"
check "git subtree push" "deny" "$(decision 0 auto 'git subtree push --prefix=dist origin gh-pages')"
check "git send-pack" "deny" "$(decision 0 auto 'git send-pack origin main')"
check "git-push by path" "deny" "$(decision 0 auto '/usr/libexec/git-core/git-push origin')"
check "piped into sh" "deny" "$(decision 0 auto 'echo git push | sh')"
check "here-string into bash" "deny" "$(decision 0 auto 'bash <<< "git push"')"
check "gh pr create piped into bash" "deny" "$(decision 0 auto 'printf "gh pr create --fill" | bash')"
check "gh -R before pr create" "deny" "$(decision 0 auto 'gh -R o/r pr create --fill')"
check "gh pr new, gh's alias for pr create" "deny" "$(decision 0 auto 'gh pr new --title x --body y')"
check "gh --repo=o/r before issue close" "deny" "$(decision 0 auto 'gh --repo=o/r issue close 3')"
check "gh issue comment" "deny" "$(decision 0 auto 'gh issue comment 104 --body-file note.md')"
check "gh issue create" "deny" "$(decision 0 auto 'gh issue create --title x --body y --label ready-for-agent')"
check "gh -R before issue comment" "deny" "$(decision 0 auto 'gh -R o/r issue comment 3 --body y')"
check "gh api implicit POST of an issue comment" "deny" "$(decision 0 auto 'gh api repos/o/r/issues/104/comments -f body=x')"
check "gh api implicit POST of a new issue" "deny" "$(decision 0 auto 'gh api repos/o/r/issues -f title=x')"
check "gh api POST of a sub-issue link" "deny" "$(decision 0 auto 'gh api --method POST repos/o/r/issues/40/sub_issues -F sub_issue_id=9')"
check "gh api PATCH of a sub-issue reorder" "deny" "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/40/sub_issues/priority -F sub_issue_id=9 -F after_id=8')"
check "gh issue comment piped into bash" "deny" "$(decision 0 auto 'printf "gh issue comment 3 --body y" | bash')"
check "gh issue create piped into sh" "deny" "$(decision 0 auto 'echo gh issue create --fill | sh')"
# A label edit (#184) is refused without a label grant; a gh issue edit
# with no label flag is handled as before, and goes through.
check "gh issue edit --add-label" "deny" "$(decision 0 auto 'gh issue edit 5 --add-label in-motion')"
check "gh issue edit --remove-label=x" "deny" "$(decision 0 auto 'gh issue edit 5 --remove-label=ready-for-agent')"
check "gh issue edit --add-label piped into sh" "deny" "$(decision 0 auto 'echo gh issue edit 5 --add-label x | sh')"
# Every other gh issue edit field is named too (#202): a link, an unlink,
# or another field.
check "gh issue edit --title is refused" "deny" "$(decision 0 auto 'gh issue edit 5 --title x')"
check "gh issue edit --title names other fields" "yes" \
    "$(reason 0 auto 'gh issue edit 5 --title x' | grep -q "'gh issue edit (other fields)'" && echo yes)"
check "gh issue edit --parent is refused" "deny" "$(decision 0 auto 'gh issue edit 23 --parent 40')"
check "gh issue edit --parent names a sub-issue link" "yes" \
    "$(reason 0 auto 'gh issue edit 23 --parent 40' | grep -q "'gh issue edit (sub-issue link)'" && echo yes)"
check "gh issue edit --add-sub-issue is refused" "deny" "$(decision 0 auto 'gh issue edit 40 --add-sub-issue 23')"
check "gh issue edit --remove-parent names a sub-issue unlink" "yes" \
    "$(reason 0 auto 'gh issue edit 23 --remove-parent' | grep -q "'gh issue edit (sub-issue unlink)'" && echo yes)"
check "gh issue edit --parent piped into sh" "deny" "$(decision 0 auto "echo 'gh issue edit 5 --parent 40' | sh")"
check "gh issue edit --title piped into sh" "deny" "$(decision 0 auto "echo 'gh issue edit 5 --title t' | sh")"
check "gh issue edit --help is not refused" "" "$(decision 0 auto 'gh issue edit --help')"
check "gh issue edit -h is not refused" "" "$(decision 0 auto 'gh issue edit -h')"
check "gh -R o/r issue edit --help is not refused" "" "$(decision 0 auto 'gh -R o/r issue edit --help')"
check "gh issue edit with no flag is not refused" "" "$(decision 0 auto 'gh issue edit 5')"
check "gh issue edit attended is not the hook's" "" "$(decision 1 auto 'gh issue edit 5 --add-label in-motion')"
# Eight more gh issue writes are named (#218), and no grant covers them.
for form in 'delete 23 --yes' 'transfer 23 o/r' 'reopen 23' 'reopen 23 -c x' 'pin 23' 'unpin 23' 'lock 23' 'unlock 23' 'develop 23'; do
    sub=${form%% *}
    check "gh issue $form is refused" "deny" "$(decision 0 auto "gh issue $form")"
    check "gh issue $form names gh issue $sub" "yes" \
        "$(reason 0 auto "gh issue $form" | grep -q "'gh issue $sub'" && echo yes)"
    check "gh issue $form piped into sh is refused" "deny" "$(decision 0 auto "echo 'gh issue $form' | sh")"
    check "gh issue $sub --help is not refused" "" "$(decision 0 auto "gh issue $sub --help")"
    check "gh issue $sub -h is not refused" "" "$(decision 0 auto "gh issue $sub -h")"
done
check "gh -R o/r issue delete 23 --yes is refused" "deny" "$(decision 0 auto 'gh -R o/r issue delete 23 --yes')"
check "gh issue develop 23 --list is not refused" "" "$(decision 0 auto 'gh issue develop 23 --list')"
check "gh issue develop -l 23 is not refused" "" "$(decision 0 auto 'gh issue develop -l 23')"
check "gh issue develop 23 --name b is refused" "deny" "$(decision 0 auto 'gh issue develop 23 --name b')"
check "gh issue reopen 23 -c --help is refused" "deny" "$(decision 0 auto 'gh issue reopen 23 -c --help')"
# gh issue create's link flags are named apart (#218): --parent as a
# sub-issue link, --blocked-by and --blocking as a blocked-by link.
for form in '--title t --parent 40' '--title t --parent=40' '-t "a;b" --parent 40'; do
    check "gh issue create $form names a sub-issue link" "yes" \
        "$(reason 0 auto "gh issue create $form" | grep -q "'gh issue create (sub-issue link)'" && echo yes)"
done
check "gh issue new --parent names a sub-issue link" "yes" \
    "$(reason 0 auto 'gh issue new --title t --parent 40' | grep -q "'gh issue create (sub-issue link)'" && echo yes)"
for form in '--title t --blocked-by 5' '--title t --blocked-by=5' '--title t --blocking 5' '--title t --blocking=5' '--title t --parent 40 --blocked-by 5' '--title "a;b" --blocked-by 5' '--parent 40 --title "a|b" --blocking 5'; do
    check "gh issue create $form names a blocked-by link" "yes" \
        "$(reason 0 auto "gh issue create $form" | grep -q "'gh issue create (blocked-by link)'" && echo yes)"
done
check "a plain gh issue create names gh issue create" "yes" \
    "$(reason 0 auto 'gh issue create --title t --label bug --milestone m' | grep -q "'gh issue create'" && echo yes)"

# A repo flag is read wherever gh takes one: before the subcommand,
# between it and its action, or after the action (#119), in each spelling.
for form in 'issue close 3' 'issue comment 3 --body y' 'issue create --title x' 'issue new --title x' \
    'pr create --fill' 'pr new --fill' 'pr merge 5'; do
    sub=${form%% *} rest=${form#* }
    for repo in '-R o/r' '-R=o/r' '--repo o/r' '--repo=o/r'; do
        check "gh $repo $form" "deny" "$(decision 0 auto "gh $repo $form")"
        check "gh $sub $repo $rest" "deny" "$(decision 0 auto "gh $sub $repo $rest")"
        check "gh $form $repo" "deny" "$(decision 0 auto "gh $form $repo")"
    done
done
check "gh issue -R o/r view is a read" "" "$(decision 0 auto 'gh issue -R o/r view 3')"
check "gh pr --repo o/r list is a read" "" "$(decision 0 auto 'gh pr --repo o/r list')"
check "gh -R o/r api write is still read past the flag" "deny" "$(decision 0 auto 'gh -R o/r api -X PUT repos/o/r/pulls/5/merge')"
check "gh --repo o/r api read is still a read" "" "$(decision 0 auto 'gh --repo o/r api repos/o/r/pulls/5')"

# A git alias in the repo's own config is resolved, since the hook runs
# in the session's working directory.
scratch=$(mktemp -d)
git -C "$scratch" init -q
git -C "$scratch" config alias.ship 'push origin HEAD'
check "git alias from repo config" "deny" "$(cd "$scratch" && decision 0 auto 'git ship')"
check "git alias that does not push" "" \
    "$(git -C "$scratch" config alias.st status; cd "$scratch" && decision 0 auto 'git st')"
command rm -rf "$scratch"

# The refusal names the grant file and the supervisor.
check "refusal names the grant file and the supervisor" \
    "A background session in auto mode cannot run 'git push' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    "$(reason 0 auto 'git push')"

# A standing grant on the committed default branch lets the matching form
# through; an ungranted action, or a grant read from the working tree only,
# still refuses (#58).
granted=$(mktemp -d)
remote="$granted.git"
git init -q --bare "$remote"
git init -q -b main "$granted"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
git -C "$granted" remote add origin "$remote"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
git -C "$granted" remote set-head origin main
mkdir -p "$granted/docs/agents"
printf '## Grants\n\n- push\n- issue-close: routine\n- issue-comment\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" add docs/agents/supervision.md
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -m grants
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null

check "a granted push goes through" "" "$(decision 0 auto 'git push' "$granted")"
check "a granted push in a compound command goes through" "" \
    "$(decision 0 auto 'echo hi && git push' "$granted")"
check "a granted issue close goes through, note cited or not" "" \
    "$(decision 0 auto 'gh issue close 42 --comment done' "$granted")"
check "an ungranted action in the same checkout still refuses" "deny" \
    "$(decision 0 auto 'gh pr create --title x --body y' "$granted")"
check "an ungranted gh pr new in the same checkout refuses" "deny" \
    "$(decision 0 auto 'gh pr new --title x --body y' "$granted")"
check "gh api is never granted, even alongside a push grant" "deny" \
    "$(decision 0 auto 'gh api -X PUT repos/o/r/pulls/5/merge' "$granted")"
# A comment or new ticket (#110), granted on its own, by gh issue or the
# gh api write that does the same.
check "a granted issue comment goes through" "" \
    "$(decision 0 auto 'gh issue comment 104 --body-file note.md' "$granted")"
check "an issue comment through gh api goes through on the same grant" "" \
    "$(decision 0 auto 'gh api repos/o/r/issues/104/comments -f body=x' "$granted")"
check "an ungranted issue create beside an issue-comment grant refuses" "deny" \
    "$(decision 0 auto 'gh issue create --title x --body y' "$granted")"
check "a new issue through gh api refuses without an issue-create grant" "deny" \
    "$(decision 0 auto 'gh api repos/o/r/issues -f title=x' "$granted")"
check "a merge with an issue-comment path in a header value still refuses" "deny" \
    "$(decision 0 auto 'gh api -X POST repos/o/r/pulls/5/merge -H x/issues/1/comments' "$granted")"
check "a merge whose path only ends like an issue comment still refuses" "deny" \
    "$(decision 0 auto 'gh api -X POST repos/o/r/pulls/5/merge/issues/1/comments' "$granted")"
check "two endpoints, one an issue comment, still refuse" "deny" \
    "$(decision 0 auto 'gh api repos/o/r/issues/1/comments repos/o/r/pulls -f body=x' "$granted")"
check "an issue comment PATCH is not the comment grant" "deny" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/1/comments -f body=x' "$granted")"
check "an issue comment piped into a shell is never granted" "deny" \
    "$(decision 0 auto 'echo gh issue comment 3 --body y | sh' "$granted")"
# The comment grant posts a new comment only (#113): editing or deleting
# one, by gh issue comment or gh api, and the GraphQL addComment mutation,
# stay refused.
check "an issue comment --edit-last is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 104 --edit-last --body y' "$granted")"
check "an issue comment --edit-last --create-if-none is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 104 --body y --edit-last --create-if-none' "$granted")"
check "an issue comment --delete-last is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 104 --delete-last --yes' "$granted")"
check "an --edit-last after a body holding parens is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 3 --body "fix (see log)" --edit-last' "$granted")"
check "a --delete-last after a body holding a semicolon is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 3 --body "a; b" --delete-last --yes' "$granted")"
check "a body holding parens still posts on the comment grant" "" \
    "$(decision 0 auto 'gh issue comment 3 --body "fix (see log)"' "$granted")"
check "a REST PATCH of an issue comment is not the comment grant" "deny" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/comments/99 -f body=y' "$granted")"
check "a REST DELETE of an issue comment is not the comment grant" "deny" \
    "$(decision 0 auto 'gh api --method DELETE repos/o/r/issues/comments/99' "$granted")"
check "a GraphQL addComment is not the comment grant" "deny" \
    "$(decision 0 auto "gh api graphql -f query='mutation { addComment(input: {subjectId: \"I_1\", body: \"y\"}) { clientMutationId } }'" "$granted")"
# A repo flag after the subcommand changes neither the grant nor its limit
# (#119).
check "gh issue -R o/r comment goes through on the comment grant" "" \
    "$(decision 0 auto 'gh issue -R o/r comment 3 --body x' "$granted")"
check "gh issue -R o/r comment --edit-last is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue -R o/r comment 3 --edit-last' "$granted")"
check "gh issue comment --delete-last --repo=o/r is not the comment grant" "deny" \
    "$(decision 0 auto 'gh issue comment 3 --delete-last --repo=o/r --yes' "$granted")"
check "git -C into a granted repo goes through from elsewhere" "" \
    "$(decision 0 auto "git -C $granted push" "$outside")"
check "git -C into an ungranted repo is refused from a granted one" "deny" \
    "$(decision 0 auto "git -C $outside push" "$granted")"
check "a push piped into a shell is never granted, even alongside a push grant" "deny" \
    "$(decision 0 auto 'echo git push | sh' "$granted")"
# A cd before the git moves the repo the grant is read from (#141).
check "cd into an ungranted repo, then push, is refused from a granted one" "deny" \
    "$(decision 0 auto "cd $outside && git push" "$granted")"
check "cd into a granted repo, then push, goes through from elsewhere" "" \
    "$(decision 0 auto "cd $granted && git push" "$outside")"
# A cd inside sh -c moves only that shell (#104): a push after it runs where
# the outer command stands, and a push inside it where its own cd went.
check "a cd inside sh -c does not move a later push" "" \
    "$(decision 0 auto "sh -c 'cd $outside'; git push" "$granted")"
check "a push inside sh -c follows its own cd" "deny" \
    "$(decision 0 auto "sh -c 'cd $outside && git push'" "$granted")"
check "a heredoc naming a cd does not move a later push" "" \
    "$(decision 0 auto "$(printf 'cat > notes.txt <<EOF\ncd %s\nEOF\ngit push' "$outside")" "$granted")"

# A Project's Distribution repo (#141): a push there needs the Project's
# distribution-push grant, never push, and never the Distribution repo's
# own supervision.md.
dgit_in() { d=$1; shift; git -C "$d" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
pushed_repo() { # <dir> <grants>: a repo with <grants> in supervision.md on origin/main
    git init -q --bare "$1.git"
    git init -q -b main "$1"
    mkdir -p "$1/docs/agents"
    printf '## Grants\n\n%s\n' "$2" >"$1/docs/agents/supervision.md"
    dgit_in "$1" add docs
    dgit_in "$1" commit -q -m grants
    dgit_in "$1" remote add origin "$1.git"
    dgit_in "$1" push -q origin main 2>/dev/null
    dgit_in "$1" remote set-head origin main
}
hproj="$outside/hproj"
hdist="$outside/hdist"
pushed_repo "$hdist" '- push'
pushed_repo "$hproj" '- push'
printf '../hdist\n' >"$hproj/docs/agents/distribution-repo.md"
dgit_in "$hproj" add docs
dgit_in "$hproj" commit -q -m dist
dgit_in "$hproj" push -q origin main 2>/dev/null
hdist_real=$(cd "$hdist" && pwd -P)
check "push grant alone: a push into the Distribution repo is refused" "deny" \
    "$(decision 0 auto "git -C $hdist push origin main" "$hproj")"
check "push grant alone: the refusal names the Distribution repo" \
    "A background session in auto mode cannot run 'git push in Distribution repo $hdist_real' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    "$(reason 0 auto "git -C $hdist push origin main" "$hproj")"
check "push grant alone: a cd into the Distribution repo, then push, is refused" "deny" \
    "$(decision 0 auto "cd ../hdist && git push" "$hproj")"
check "push grant alone: a cd -P into the Distribution repo, then push, is refused" "deny" \
    "$(decision 0 auto "cd -P ../hdist; git push" "$hproj")"
# A cd in a subshell, a pipe or a background job leaves the folder as it
# was, so it is not followed.
printf 'c2a368ee\nproject %s\n' "$hproj" >"$(git -C "$hdist" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
check "a cd in a subshell is not followed into the Project" "deny" \
    "$(decision 0 auto "(cd ../hproj); git push origin main" "$hdist")"
check "a cd in a pipe is not followed into the Project" "deny" \
    "$(decision 0 auto "cd ../hproj | true; git push origin main" "$hdist")"
check "a cd in a background job is not followed into the Project" "deny" \
    "$(decision 0 auto "cd ../hproj & git push origin main" "$hdist")"
command rm -f "$(git -C "$hdist" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
check "push grant alone: the Project's own push goes through" "" \
    "$(decision 0 auto "git push origin main" "$hproj")"
check "push grant alone: with no marker, a session in the Distribution repo reads its own grants" "" \
    "$(decision 0 auto "git push origin main" "$hdist")"
printf 'c2a368ee\nproject %s\n' "$hproj" >"$(git -C "$hdist" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
check "push grant alone: with the worker's marker, a session in the Distribution repo is refused" "deny" \
    "$(decision 0 auto "git push origin main" "$hdist")"
printf '## Grants\n\n- distribution-push\n' >"$hproj/docs/agents/supervision.md"
dgit_in "$hproj" commit -q -am 'distribution-push only'
dgit_in "$hproj" push -q origin main 2>/dev/null
check "distribution-push grant: a push into the Distribution repo goes through" "" \
    "$(decision 0 auto "git -C $hdist push origin main" "$hproj")"
check "distribution-push grant: and from a session in it, by its marker" "" \
    "$(decision 0 auto "git push origin main" "$hdist")"
check "distribution-push grant alone: the Project's own push is refused" "deny" \
    "$(decision 0 auto "git push origin main" "$hproj")"
# checked-push is read only by the supervisor's Push on approval (#188): a
# worker's push under it alone, in either repo, is refused as with no grant.
printf '## Grants\n\n- checked-push: code-only pushes\n' >"$hproj/docs/agents/supervision.md"
dgit_in "$hproj" commit -q -am 'checked-push only'
dgit_in "$hproj" push -q origin main 2>/dev/null
check "checked-push grant alone: the Project's own push is refused" "deny" \
    "$(decision 0 auto "git push origin main" "$hproj")"
check "checked-push grant alone: a push into the Distribution repo is refused" "deny" \
    "$(decision 0 auto "git -C $hdist push origin main" "$hproj")"
check "checked-push grant alone: a session in the Distribution repo is refused" "deny" \
    "$(decision 0 auto "git push origin main" "$hdist")"
# The issue-close grant covers the worker's ticket after its work is pushed
# (#186): while the Distribution repo holds commits its upstream lacks, the
# close is refused and waits for Push on approval.
printf '## Grants\n\n- issue-close\n' >"$hproj/docs/agents/supervision.md"
dgit_in "$hproj" commit -q -am 'issue-close only'
dgit_in "$hproj" push -q origin main 2>/dev/null
dgit_in "$hdist" branch -q -u origin/main main
check "issue-close grant, Distribution repo pushed: the close goes through" "" \
    "$(decision 0 auto 'gh issue close 186 --comment done' "$hproj")"
dgit_in "$hdist" commit -q --allow-empty -m 'the ticket code'
check "issue-close grant, Distribution commit unpushed: the close is refused" "deny" \
    "$(decision 0 auto 'gh issue close 186 --comment done' "$hproj")"
check "issue-close grant, Distribution commit unpushed: the reason names the repo and the wait" \
    "A background session in auto mode cannot run 'gh issue close' yet (#186): Distribution repo $hdist_real holds 1 commit its upstream lacks, and the issue-close grant covers the ticket only after its work is pushed. When the ticket's work is done, list the close with the push, as \`Waiting on: git -C $hdist_real push origin <branch>; gh issue close <N>\`, and /supervise closes the ticket after the push lands; when work is left on it, list the push alone (#217)." \
    "$(reason 0 auto 'gh issue close 186' "$hproj")"
check "issue-close grant, Distribution commit unpushed: refused from a session in the Distribution repo too" "deny" \
    "$(decision 0 auto 'gh issue close 186' "$hdist")"
check "issue-close grant, Distribution commit unpushed: a comment is not held" "deny" \
    "$(decision 0 auto 'gh issue comment 186 --body x' "$hproj")"
dgit_in "$hdist" push -q origin main 2>/dev/null
check "issue-close grant, Distribution commit pushed: the close goes through again" "" \
    "$(decision 0 auto 'gh issue close 186' "$hproj")"
dgit_in "$hdist" checkout -q -b local-only
check "issue-close grant, Distribution branch with no upstream: the close is refused" "deny" \
    "$(decision 0 auto 'gh issue close 186' "$hproj")"
dgit_in "$hdist" checkout -q main
# A Distribution path that is a plain folder inside the Project's repo is no
# repo of its own, so the Project's own unpushed commit does not hold it.
mkdir -p "$hproj/plain"
printf 'plain\n' >"$hproj/docs/agents/distribution-repo.md"
dgit_in "$hproj" commit -q -am 'dist is a plain folder'
dgit_in "$hproj" push -q origin main 2>/dev/null
dgit_in "$hproj" commit -q --allow-empty -m 'unpushed Project commit'
check "issue-close grant, a plain-folder Distribution path: the close goes through" "" \
    "$(decision 0 auto 'gh issue close 186' "$hproj")"

ungranted=$(mktemp -d)
git init -q -b main "$ungranted"
git -C "$ungranted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
mkdir -p "$ungranted/docs/agents"
printf '## Grants\n\n- push\n' >"$ungranted/docs/agents/supervision.md"
check "a grant only in the working tree, not pushed, still refuses" "deny" \
    "$(decision 0 auto 'git push' "$ungranted")"
printf '## Grants\n\n- issue-create\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "issue-create only"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
check "a granted issue create goes through" "" \
    "$(decision 0 auto 'gh issue create --title x --body y --label ready-for-agent' "$granted")"
check "a new issue through gh api goes through on the same grant" "" \
    "$(decision 0 auto 'gh api repos/o/r/issues -f title=x' "$granted")"
check "an ungranted issue comment beside an issue-create grant refuses" "deny" \
    "$(decision 0 auto 'gh issue comment 104 --body y' "$granted")"
check "a GraphQL createIssue is not the issue-create grant" "deny" \
    "$(decision 0 auto "gh api graphql -f query='mutation { createIssue(input: {repositoryId: \"R_1\", title: \"x\"}) { issue { number } } }'" "$granted")"
check "a sub-issue link is not the issue-create grant" "deny" \
    "$(decision 0 auto 'gh api --method POST repos/o/r/issues/40/sub_issues -F sub_issue_id=9' "$granted")"
# The sub-issue grant (#162) covers linking a child and reordering a
# parent's sub-issues, and no other gh api write to an issue.
printf '## Grants\n\n- sub-issue\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "sub-issue only"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
check "a granted sub-issue link goes through" "" \
    "$(decision 0 auto 'gh api --method POST repos/{owner}/{repo}/issues/40/sub_issues -F sub_issue_id=9' "$granted")"
check "a granted sub-issue link with an implicit POST goes through" "" \
    "$(decision 0 auto 'gh api repos/o/r/issues/40/sub_issues -F sub_issue_id=9' "$granted")"
check "a granted sub-issue reorder goes through" "" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/40/sub_issues/priority -F sub_issue_id=9 -F after_id=8' "$granted")"
check "a sub-issue grant does not cover a PATCH of the issue" "deny" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/40 -f state=closed' "$granted")"
check "a sub-issue grant does not cover removing a sub-issue" "deny" \
    "$(decision 0 auto 'gh api -X DELETE repos/o/r/issues/40/sub_issue -F sub_issue_id=9' "$granted")"
check "a sub-issue grant does not cover a POST to the priority path" "deny" \
    "$(decision 0 auto 'gh api -X POST repos/o/r/issues/40/sub_issues/priority -F sub_issue_id=9' "$granted")"
check "a sub-issue grant does not cover a PATCH of the sub_issues list" "deny" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/r/issues/40/sub_issues -F sub_issue_id=9' "$granted")"
check "a sub-issue grant does not cover a second path" "deny" \
    "$(decision 0 auto 'gh api repos/o/r/issues/40/sub_issues repos/o/r/pulls -F sub_issue_id=9' "$granted")"
check "a sub-issue grant does not cover an issue create" "deny" \
    "$(decision 0 auto 'gh issue create --title x --body y' "$granted")"
check "a GraphQL addSubIssue is not the sub-issue grant" "deny" \
    "$(decision 0 auto "gh api graphql -f query='mutation { addSubIssue(input: {issueId: \"I_1\", subIssueId: \"I_2\"}) { issue { number } } }'" "$granted")"
# A ? or # in the owner or repo would send the call to the repo itself, and
# a .. segment could step out of the granted path.
check "a sub-issue grant does not cover a query hiding a repo PATCH" "deny" \
    "$(decision 0 auto "gh api -X PATCH 'repos/o/r?x=/issues/1/sub_issues/priority' -f private=false" "$granted")"
check "a sub-issue grant does not cover a fragment hiding the path" "deny" \
    "$(decision 0 auto "gh api 'repos/o/r#/issues/1/sub_issues' -F sub_issue_id=9" "$granted")"
check "a sub-issue grant does not cover a .. segment" "deny" \
    "$(decision 0 auto 'gh api -X PATCH repos/o/../issues/1/sub_issues/priority -F sub_issue_id=9' "$granted")"
check "a granted sub-issue link to a dotted repo name goes through" "" \
    "$(decision 0 auto 'gh api repos/o/.github/issues/40/sub_issues -F sub_issue_id=9' "$granted")"
check "a sub-issue grant does not cover a label edit" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label in-motion' "$granted")"
# gh issue edit's link flags are the same link (#202); its unlink flags,
# like the DELETE, are not the grant's.
check "a granted --parent link goes through" "" \
    "$(decision 0 auto 'gh issue edit 23 --parent 40' "$granted")"
check "a granted --parent= link goes through" "" \
    "$(decision 0 auto 'gh issue edit 23 --parent=40' "$granted")"
check "a granted --add-sub-issue link goes through" "" \
    "$(decision 0 auto 'gh issue edit 40 --add-sub-issue 23' "$granted")"
check "a granted link of two children goes through" "" \
    "$(decision 0 auto 'gh -R o/r issue edit 40 --add-sub-issue 23 --add-sub-issue 24' "$granted")"
check "a granted link with a quoted semicolon goes through" "" \
    "$(decision 0 auto 'gh issue edit 40 --add-sub-issue "5;6"' "$granted")"
check "a granted link beside a git commit -m goes through" "" \
    "$(decision 0 auto 'gh issue edit 23 --parent 40 && git commit -S -s -m msg -- f' "$granted")"
check "a sub-issue grant does not cover --remove-parent" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --remove-parent' "$granted")"
check "a sub-issue grant does not cover --remove-sub-issue" "deny" \
    "$(decision 0 auto 'gh issue edit 40 --remove-sub-issue 23' "$granted")"
check "a sub-issue grant does not cover a link beside an unlink" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --parent 40 --remove-sub-issue 5' "$granted")"
check "a sub-issue grant does not cover a link beside a label" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --add-label bug --parent 40' "$granted")"
check "a sub-issue grant does not cover a link beside a title" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --parent 40 --title t' "$granted")"
check "a title after a quoted semicolon is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 40 --add-sub-issue "5;6" --title t' "$granted")"
check "a title after a quoted semicolon names other fields" "yes" \
    "$(reason 0 auto 'gh issue edit 40 --add-sub-issue "5;6" --title t' "$granted" | grep -q "'gh issue edit (other fields)'" && echo yes)"
check "an unlink in a second gh issue edit is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --parent 40; gh issue edit 24 --remove-parent' "$granted")"
# Two gh issue edits with different granted names are a label edit beside a
# link, which no one grant covers, in either order.
check "a label edit before a link is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x; gh issue edit 6 --parent 40' "$granted")"
check "a label edit beside a link names label and other fields" "yes" \
    "$(reason 0 auto 'gh issue edit 5 --add-label x; gh issue edit 6 --parent 40' "$granted" | grep -q "'gh issue edit (label and other fields)'" && echo yes)"
check "a link before a label edit is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 6 --parent 40; gh issue edit 5 --add-label x' "$granted")"
check "a title after a label edit and a link is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x; gh issue edit 6 --parent 40; gh issue edit 7 --title t' "$granted")"
check "a title edit is not the sub-issue grant" "deny" \
    "$(decision 0 auto 'gh issue edit 23 --title t' "$granted")"
check "a link piped into a shell is never granted" "deny" \
    "$(decision 0 auto "echo 'gh issue edit 5 --parent 40' | sh" "$granted")"
check "gh issue edit --help under the sub-issue grant is not refused" "" \
    "$(decision 0 auto 'gh issue edit --help' "$granted")"
# The label grant (#184) covers a gh issue edit that only adds or removes
# labels. One that changes another field, and any label write through gh
# api, stay refused.
printf '## Grants\n\n- label: relabels\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "label only"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
check "a granted label edit goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label in-motion' "$granted")"
check "a granted relabel of two labels goes through" "" \
    "$(decision 0 auto 'gh issue edit 118 --remove-label ready-for-agent --add-label ready-for-human' "$granted")"
check "a granted label edit with a quoted label goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "needs triage"' "$granted")"
for repo in '-R o/r' '-R=o/r' '--repo o/r' '--repo=o/r' '-Ro/r'; do
    check "a granted label edit with gh $repo first goes through" "" \
        "$(decision 0 auto "gh $repo issue edit 5 --add-label x" "$granted")"
    check "a granted label edit with gh issue $repo edit goes through" "" \
        "$(decision 0 auto "gh issue $repo edit 5 --add-label x" "$granted")"
    check "a granted label edit with $repo last goes through" "" \
        "$(decision 0 auto "gh issue edit 5 --add-label x $repo" "$granted")"
done
check "a label edit with --body is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x --body y' "$granted")"
check "a label edit with --title is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --title y --remove-label x' "$granted")"
check "a label edit with -t is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label=x -t y' "$granted")"
check "a label edit with --add-assignee is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x --add-assignee me' "$granted")"
check "a title after a quoted semicolon is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "a;b" --title t' "$granted")"
check "a body after a quoted pipe is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "a|b" --body t' "$granted")"
check "a joined -tT after a quoted semicolon is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "a;b" -tT' "$granted")"
check "a joined -bX after a quoted semicolon is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "a;b" -bX' "$granted")"
check "a granted label edit with a quoted semicolon goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label "a;b" -R o/r' "$granted")"
check "a link before a label edit is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 6 --parent 40; gh issue edit 5 --add-label x' "$granted")"
check "a label edit before a link is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x; gh issue edit 6 --parent 40' "$granted")"
# Only the gh issue edit's own words are read for another field: a flag on
# another command beside it is that command's.
check "a granted label edit beside a git commit -m goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label in-motion && git commit -S -s -m msg -- f' "$granted")"
check "a granted label edit after a git commit -m goes through" "" \
    "$(decision 0 auto 'git commit -m msg -- f; gh issue edit 5 --add-label in-motion' "$granted")"
check "a granted label edit piped to tail goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label in-motion 2>&1 | tail -1' "$granted")"
check "a title in a second gh issue edit is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label x; gh issue edit 6 --add-label y --title t' "$granted")"
check "a title after an escaped semicolon is not the label grant" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label a\;b --title t' "$granted")"
check "a title after an unclosed quote is not the label grant" "deny" \
    "$(decision 0 auto "gh issue edit 5 --add-label 'a; --title t" "$granted")"
check "a title after a newline in single quotes is not the label grant" "deny" \
    "$(decision 0 auto "$(printf "gh issue edit 5 --add-label 'a\nb' --title t")" "$granted")"
check "a title after a newline in double quotes is not the label grant" "deny" \
    "$(decision 0 auto "$(printf 'gh issue edit 5 --add-label "a\nb" --title t')" "$granted")"
check "a title after a continued line is not the label grant" "deny" \
    "$(decision 0 auto "$(printf 'gh issue edit 5 --add-label x \\\n  --title t')" "$granted")"
check "a granted label edit on its own line goes through" "" \
    "$(decision 0 auto "$(printf 'git commit -m msg -- f\ngh issue edit 5 --add-label in-motion')" "$granted")"
for field in '--title x' '--body y' '--add-assignee me' '--milestone m' '--add-blocked-by 7' '--parent 40' '--remove-parent'; do
    check "a label grant does not cover gh issue edit $field" "deny" \
        "$(decision 0 auto "gh issue edit 5 $field" "$granted")"
done
check "a label grant does not cover a label beside a link" "deny" \
    "$(decision 0 auto 'gh issue edit 5 --add-label bug --parent 40' "$granted")"
check "a label edit piped into a shell is never granted" "deny" \
    "$(decision 0 auto 'echo gh issue edit 5 --add-label x | sh' "$granted")"
check "a label grant does not cover an issue comment" "deny" \
    "$(decision 0 auto 'gh issue comment 5 --body y' "$granted")"
check "a label grant does not cover a REST label POST" "deny" \
    "$(decision 0 auto 'gh api repos/o/r/issues/5/labels -f "labels[]=x"' "$granted")"
check "a label grant does not cover a REST label DELETE" "deny" \
    "$(decision 0 auto 'gh api -X DELETE repos/o/r/issues/5/labels/x' "$granted")"
check "a label grant does not cover a REST label PUT" "deny" \
    "$(decision 0 auto 'gh api -X PUT repos/o/r/issues/5/labels -f "labels[]=x"' "$granted")"
check "a label grant does not cover a query hiding a REST label write" "deny" \
    "$(decision 0 auto "gh api 'repos/o/r?x=/issues/5/labels' -f 'labels[]=x'" "$granted")"
check "a label grant does not cover a fragment hiding a REST label write" "deny" \
    "$(decision 0 auto "gh api 'repos/o/r#/issues/5/labels' -f 'labels[]=x'" "$granted")"
check "a label grant does not cover a .. segment in a REST label write" "deny" \
    "$(decision 0 auto 'gh api repos/o/../issues/5/labels -f "labels[]=x"' "$granted")"
check "a GraphQL addLabelsToLabelable is not the label grant" "deny" \
    "$(decision 0 auto "gh api graphql -f query='mutation { addLabelsToLabelable(input: {labelableId: \"I_1\", labelIds: [\"L_1\"]}) { clientMutationId } }'" "$granted")"
printf '## Grants\n\n- label: relabels\n- issue-comment: findings\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "label and comment"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
check "a granted label edit beside a granted comment -F goes through" "" \
    "$(decision 0 auto 'gh issue edit 5 --add-label in-motion; gh issue comment 5 -F /tmp/x.md' "$granted")"
# gh pr new is gh's alias for gh pr create (#120): the same grant covers it.
printf '## Grants\n\n- pr-create\n' >"$granted/docs/agents/supervision.md"
git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "pr-create only"
git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
check "a granted pr create goes through" "" \
    "$(decision 0 auto 'gh pr create --fill' "$granted")"
check "a granted gh pr new goes through" "" \
    "$(decision 0 auto 'gh pr new --fill' "$granted")"
check "a granted gh pr -R o/r new goes through" "" \
    "$(decision 0 auto 'gh pr -R o/r new --fill' "$granted")"
# A gh issue create with --parent needs both issue-create and sub-issue
# (#218); one alone refuses it.
parent_forms='--title t --parent 40|--title t --parent=40|-t "a;b" --parent 40'
grant_with() { # <grant>...: commit and push a supervision.md granting them
    { printf '## Grants\n\n'; for g in "$@"; do printf -- '- %s\n' "$g"; done; } >"$granted/docs/agents/supervision.md"
    git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -am "grants: $*"
    git -C "$granted" -c commit.gpgsign=false push -q origin main 2>/dev/null
}
for grants in issue-create sub-issue 'issue-create sub-issue'; do
    # shellcheck disable=SC2086
    grant_with $grants
    expect=deny
    [ "$grants" != 'issue-create sub-issue' ] || expect=""
    oldIFS=$IFS IFS='|'
    for form in $parent_forms; do
        IFS=$oldIFS
        check "gh issue create $form under $grants" "$expect" "$(decision 0 auto "gh issue create $form" "$granted")"
    done
    IFS=$oldIFS
    check "gh issue new --parent under $grants" "$expect" "$(decision 0 auto 'gh issue new --title t --parent 40' "$granted")"
done
check "a plain create beside a quoted create --parent is the link" "deny" \
    "$(grant_with issue-create; decision 0 auto 'gh issue create --title x; gh issue create -t "a;b" --parent 40' "$granted")"
check "a plain create under issue-create goes through as before" "" \
    "$(decision 0 auto 'gh issue create --title t --label bug --milestone m' "$granted")"
check "a piped create --parent stays refused under issue-create" "deny" \
    "$(decision 0 auto "echo 'gh issue create --title t --parent 40' | sh" "$granted")"
grant_with push issue-close issue-comment issue-create pr-create pr-merge sub-issue label
for form in '--title t --blocked-by 5' '--title t --blocked-by=5' '--title t --blocking 5' '--title t --parent 40 --blocked-by 5' '--title "a;b" --blocked-by 5'; do
    check "gh issue create $form is refused under every grant" "deny" \
        "$(decision 0 auto "gh issue create $form" "$granted")"
done
for form in 'delete 23 --yes' 'transfer 23 o/r' 'reopen 23' 'reopen 23 -c x' 'pin 23' 'unpin 23' 'lock 23' 'unlock 23' 'develop 23'; do
    check "gh issue $form is refused under every grant" "deny" "$(decision 0 auto "gh issue $form" "$granted")"
done
check "a piped create --parent stays refused under every grant" "deny" \
    "$(decision 0 auto "echo 'gh issue create --title t --parent 40' | sh" "$granted")"
check "a create --parent goes through under every grant" "" \
    "$(decision 0 auto 'gh issue create --title t --parent 40' "$granted")"
command rm -rf "$granted" "$remote" "$ungranted"

# A command that is not a shared action goes through.
check "gh pr view (not a shared action)" "" "$(decision 0 auto 'gh pr view 5')"
check "gh api read (GET)" "" "$(decision 0 auto 'gh api repos/o/r/pulls/5')"
check "gh api read with -X GET and a field" "" "$(decision 0 auto 'gh api -X GET repos/o/r/issues -f state=open')"
check "gh api graphql query" "" "$(decision 0 auto "gh api graphql -f query='{ viewer { login } }'")"
check "bash -c without a shared action" "" "$(decision 0 auto 'bash -c "git status && echo push"')"
check "command -v git" "" "$(decision 0 auto 'command -v git')"
check "sh running a script file" "" "$(decision 0 auto 'sh tests/some.test.sh')"
check "piped into sh without a shared action" "" "$(decision 0 auto 'echo git status | sh')"
check "gh api contents read" "" "$(decision 0 auto 'gh api repos/o/r/contents/README.md')"

# The hook sees only the command text, never what a named script goes on to
# run, so a script that pushes gets past it whatever its content; the
# wrappers in tests/worker-bin.test.sh catch it there (docs/adr/0006).
check "a script that runs git push is not inspected" "" \
    "$(decision 0 auto 'sh scripts/granted-push.sh')"

# Commands that only resemble a refused form.
check "git commit whose message says push" "" \
    "$(decision 0 auto 'git commit -m "remember to push later"')"
check "git status" "" "$(decision 0 auto 'git status')"
check "a git-named command that is not git" "" "$(decision 0 auto 'mygit push')"
check "gh issue list is not gh issue close" "" "$(decision 0 auto 'gh issue list')"
check "gh api read of an issue's comments" "" "$(decision 0 auto 'gh api repos/o/r/issues/104/comments')"
check "env with no git/gh is unaffected" "" "$(decision 0 auto 'env NODE_ENV=test npm test')"

# Text that only names a refused form (#104): quoted text and a heredoc's
# body are data for the command, not commands, so they run.
check "quoted text holding a separated git push runs" "" \
    "$(decision 0 auto 'git commit -m "wip; git push later"')"
check "a quoted heredoc naming git push runs" "" \
    "$(decision 0 auto "$(printf "cat > edit.py <<'EOF'\nsubprocess.run('git push origin main')\nEOF\npython3 edit.py")")"
check "an unquoted heredoc naming git push runs" "" \
    "$(decision 0 auto "$(printf 'python3 - <<EOF\ngit push origin main\nEOF')")"
check "a <<- heredoc naming git push runs" "" \
    "$(decision 0 auto "$(printf "cat > f <<-'EOF'\n\tgit push\n\tEOF\necho done")")"
check "a heredoc naming a piped push runs" "" \
    "$(decision 0 auto "$(printf "cat > t.sh <<'EOF'\necho git push origin main | sh\nEOF")")"
check "a heredoc naming gh pr create runs" "" \
    "$(decision 0 auto "$(printf "python3 - <<'EOF'\ngh pr create --fill\nEOF")")"
check "a heredoc naming gh issue close runs" "" \
    "$(decision 0 auto "$(printf "python3 - <<'EOF'\ngh issue close 5\nEOF")")"
check "a heredoc naming gh issue comment runs" "" \
    "$(decision 0 auto "$(printf "cat > c.md <<'EOF'\ngh issue comment 104 --body x\nEOF")")"
check "a heredoc naming gh issue create runs" "" \
    "$(decision 0 auto "$(printf "cat > c.md <<'EOF'\ngh issue create --title x\nEOF")")"
check "a heredoc naming a gh api PATCH runs" "" \
    "$(decision 0 auto "$(printf "cat > r.sh <<'EOF'\ngh api --method PATCH repos/o/r/issues/40/sub_issues/priority -F sub_issue_id=1\nEOF")")"
check "a quoted search for gh forms runs" "" \
    "$(decision 0 auto 'rg -n "gh issue create|gh pr create" plugins </dev/null')"
check "a quoted argument naming gh issue close runs" "" \
    "$(decision 0 auto "printf '%s\n' 'a; gh issue close 3' > note.txt")"
check "a trailing comment naming git push runs" "" \
    "$(decision 0 auto 'git status # then; git push')"
check "a perl edit naming git push runs" "" \
    "$(decision 0 auto "perl -pi -e 's/a/b/; git push origin main' docs/adr/0004.md")"

# Commands that still run a refused form beside such text.
check "a push after a heredoc is refused" "deny" \
    "$(decision 0 auto "$(printf "cat > f <<'EOF'\nnotes\nEOF\ngit push")")"
check "a push after cd && is refused" "deny" "$(decision 0 auto 'cd sub && git push')"
check "a push inside a subshell is refused" "deny" "$(decision 0 auto '(git push)')"
check "sh reading a heredoc that pushes is refused" "deny" \
    "$(decision 0 auto "$(printf "sh <<'EOF'\ngit push\nEOF")")"
check "a heredoc piped into sh is refused" "deny" \
    "$(decision 0 auto "$(printf "cat <<'EOF' | sh\ngit push\nEOF")")"
check "bash -s reading a heredoc is refused" "deny" \
    "$(decision 0 auto "$(printf 'bash -s <<EOF\ngit push\nEOF')")"
check "sh -c of a heredoc's substitution is refused" "deny" \
    "$(decision 0 auto "$(printf "sh -c \"\$(cat <<'EOF'\ngit push\nEOF\n)\"")")"
check "a push in a double-quoted substitution is refused" "deny" \
    "$(decision 0 auto 'x="$(git push)"')"
check "a push in backticks inside quotes is refused" "deny" \
    "$(decision 0 auto 'echo "now `git push` done"')"
check "a push in an unquoted heredoc's substitution is refused" "deny" \
    "$(decision 0 auto "$(printf 'cat <<EOF\n$(git push)\nEOF')")"
check "a push after arithmetic holding << is refused" "deny" \
    "$(decision 0 auto "$(printf 'echo $((1<<2))\ngit push')")"
check "a push after an unclosed quote is refused" "deny" \
    "$(decision 0 auto 'echo "abc; git push')"
check "a push after a word holding # is refused" "deny" "$(decision 0 auto 'a#b; git push')"
check "a push in a process substitution is refused" "deny" "$(decision 0 auto 'tee >(git push) < f')"
check "a push in eval's quoted words is refused" "deny" "$(decision 0 auto "eval 'git push'")"
check "eval of a substitution is refused" "deny" "$(decision 0 auto 'eval "$(printf %s "git push")"')"
check "a here-string into sh is refused" "deny" "$(decision 0 auto "sh <<< 'gh issue close 3'")"

# The maintainer's own interactive session: attended, whatever the
# permission mode.
check "attended, auto mode: push allowed" "" "$(decision 1 auto 'git push')"
check "attended, default mode: push allowed" "" "$(decision 1 default 'git push')"
check "attended, unset (older Claude Code): push allowed" "" \
    "$(payload=$(jq -cn '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:"auto",tool_name:"Bash",tool_input:{command:"git push"}}'); \
       printf '%s' "$payload" | env -u CLAUDE_CODE_SESSION_ATTENDED sh -c "$hook_cmd" | jq -r '.hookSpecificOutput.permissionDecision // empty')"

# Unattended outside auto mode: this hook stays out of the way; a manual
# session with nobody to answer blocks on the ordinary permission prompt
# instead.
check "unattended, default mode: push allowed" "" "$(decision 0 default 'git push')"
check "unattended, acceptEdits mode: push allowed" "" "$(decision 0 acceptEdits 'git push')"

# A non-Bash tool call is never inspected.
check "non-Bash tool" "" "$(run 0 auto Write 'git push' | jq -r '.hookSpecificOutput.permissionDecision // empty')"

# The matcher and timeout Claude Code applies before the script's own check.
check "matcher: Bash only" "Bash" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

cd / && command rm -rf "$outside"

echo "deny-shared-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
