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
check "backslash-escaped git" "deny" "$(decision 0 auto '\\git push')"
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
check "gh --repo=o/r before issue close" "deny" "$(decision 0 auto 'gh --repo=o/r issue close 3')"
check "gh issue comment" "deny" "$(decision 0 auto 'gh issue comment 104 --body-file note.md')"
check "gh issue create" "deny" "$(decision 0 auto 'gh issue create --title x --body y --label ready-for-agent')"
check "gh -R before issue comment" "deny" "$(decision 0 auto 'gh -R o/r issue comment 3 --body y')"
check "gh api implicit POST of an issue comment" "deny" "$(decision 0 auto 'gh api repos/o/r/issues/104/comments -f body=x')"
check "gh api implicit POST of a new issue" "deny" "$(decision 0 auto 'gh api repos/o/r/issues -f title=x')"
check "gh issue comment piped into bash" "deny" "$(decision 0 auto 'printf "gh issue comment 3 --body y" | bash')"
check "gh issue create piped into sh" "deny" "$(decision 0 auto 'echo gh issue create --fill | sh')"

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
check "an issue comment piped into a shell is never granted" "deny" \
    "$(decision 0 auto 'echo gh issue comment 3 --body y | sh' "$granted")"
check "git -C into a granted repo goes through from elsewhere" "" \
    "$(decision 0 auto "git -C $granted push" "$outside")"
check "git -C into an ungranted repo is refused from a granted one" "deny" \
    "$(decision 0 auto "git -C $outside push" "$granted")"
check "a push piped into a shell is never granted, even alongside a push grant" "deny" \
    "$(decision 0 auto 'echo git push | sh' "$granted")"

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

# Accepted over-refusal: the splitter does not parse quoting, so a
# separator inside a quoted string starts a new segment (docs/adr/0004).
# In an unattended session a false refusal costs a detour through the
# supervisor; a miss publishes.
check "quoted text holding a separated git push is refused" "deny" \
    "$(decision 0 auto 'git commit -m "wip; git push later"')"

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
