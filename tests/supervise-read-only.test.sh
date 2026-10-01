#!/bin/sh
# supervise-read-only.test.sh -- tests for the PreToolUse hook that keeps an
# attended session read-only in a checkout a supervised worker holds (#76).
#
# Runs the command string from hooks.json, as Claude Code does, with a
# PreToolUse payload on stdin, CLAUDE_CODE_SESSION_ATTENDED set as Claude
# Code sets it, and CLAUDE_PLUGIN_ROOT pointed at this checkout. The worker's
# marker is the file launch.sh writes at `git rev-parse --git-path
# mp-supervise-worker`. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-read-only.test.sh

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

# Every variable the hook reads, set or unset here; git reads no global or
# system config.
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT CLAUDE_CODE_SESSION_ATTENDED
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'command rm -rf "$work"' EXIT
cd "$work" || exit 1

entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("supervise-read-only"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

# A Project checkout a worker holds, a second checkout nobody holds, and a
# linked worktree of the first, which is a checkout of its own.
project="$work/project"
other="$work/other"
for d in "$project" "$other"; do
    git init -q -b main "$d"
    git -C "$d" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
done
mkdir -p "$project/sub"
git -C "$project" worktree add -q "$work/linked" -b linked
echo c2a368ee >"$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-worker)"

run() { # <attended> <cwd> <tool> <tool_input json>: the hook's full output
    payload=$(jq -cn --arg cwd "$2" --arg tool "$3" --argjson input "$4" \
        '{hook_event_name:"PreToolUse",session_id:"s1",cwd:$cwd,permission_mode:"default",tool_name:$tool,tool_input:$input}')
    if [ "$1" = unset ]; then
        printf '%s' "$payload" | (unset CLAUDE_CODE_SESSION_ATTENDED; sh -c "$hook_cmd")
    else
        printf '%s' "$payload" | (CLAUDE_CODE_SESSION_ATTENDED="$1"; export CLAUDE_CODE_SESSION_ATTENDED; sh -c "$hook_cmd")
    fi
}
decide() { run "$@" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
bash_in() { # <cwd> <command>: the decision on an attended Bash call
    decide 1 "$1" Bash "$(jq -cn --arg c "$2" '{command:$c}')"
}
edit() { # <tool> <cwd> <path>: the decision on an attended file edit
    case $1 in
        NotebookEdit) decide 1 "$2" "$1" "$(jq -cn --arg p "$3" '{notebook_path:$p,new_source:"x"}')" ;;
        *) decide 1 "$2" "$1" "$(jq -cn --arg p "$3" '{file_path:$p,content:"x"}')" ;;
    esac
}

# File edits in the held checkout are refused, whatever the session's folder.
check "Edit in the checkout" "deny" "$(edit Edit "$project" "$project/README")"
check "Write in the checkout" "deny" "$(edit Write "$project" "$project/new.txt")"
check "NotebookEdit in the checkout" "deny" "$(edit NotebookEdit "$project" "$project/n.ipynb")"
check "Write to a new folder in the checkout" "deny" "$(edit Write "$project" "$project/a/b/new.txt")"
check "Edit by a relative path" "deny" "$(edit Edit "$project/sub" "../README")"
check "Edit from a parent folder" "deny" "$(edit Edit "$work" "$project/README")"
check "Edit elsewhere" "" "$(edit Edit "$project" "$other/README")"
check "Write outside any repo" "" "$(edit Write "$project" "$work/scratch.txt")"
check "Edit in a linked worktree of the repo" "" "$(edit Edit "$project" "$work/linked/README")"

# State-changing git commands in the held checkout are refused.
for sub in commit merge rebase checkout switch reset stash; do
    check "git $sub in the checkout" "deny" "$(bash_in "$project" "git $sub x")"
done
check "git stash push" "deny" "$(bash_in "$project" 'git stash push -m wip')"
check "git with options before the subcommand" "deny" "$(bash_in "$project" 'git -c user.name=x commit -m m')"
check "git -C into the checkout" "deny" "$(bash_in "$work" "git -C $project commit -m m")"
check "git -C relative into the checkout" "deny" "$(bash_in "$work" 'git -C project commit -m m')"
check "cd into the checkout first" "deny" "$(bash_in "$work" "cd $project && git commit -m m")"
check "from a subfolder" "deny" "$(bash_in "$project/sub" 'git commit -am m')"
check "in a compound command" "deny" "$(bash_in "$project" 'git status; git reset --hard')"
check "env-prefixed" "deny" "$(bash_in "$project" 'GIT_EDITOR=true git rebase --continue')"
check "command git" "deny" "$(bash_in "$project" 'command git switch main')"
check "absolute path to git" "deny" "$(bash_in "$project" '/usr/bin/git merge x')"
check "sh -c" "deny" "$(bash_in "$project" "sh -c 'git commit -m m'")"
check "if/then" "deny" "$(bash_in "$project" 'if true; then git commit -m m; fi')"
check "a loop body" "deny" "$(bash_in "$project" 'for f in a; do git reset --hard; done')"
check "brace group" "deny" "$(bash_in "$project" '{ git stash; }')"
check "bare git stash" "deny" "$(bash_in "$project" 'git stash')"
check "nice" "deny" "$(bash_in "$project" 'nice -n 5 git commit -m m')"
check "timeout" "deny" "$(bash_in "$project" 'timeout 30 git rebase main')"
check "xargs" "deny" "$(bash_in "$project" 'echo main | xargs git checkout')"

# Reads, gh and the supervise scripts still run.
check "git status" "" "$(bash_in "$project" 'git status')"
check "git log" "" "$(bash_in "$project" 'git log --oneline -5')"
check "git diff" "" "$(bash_in "$project" 'git diff HEAD~1')"
check "git stash list" "" "$(bash_in "$project" 'git stash list')"
check "git stash show" "" "$(bash_in "$project" 'git stash show -p')"
check "git worktree list" "" "$(bash_in "$project" 'git worktree list')"
check "gh issue view" "" "$(bash_in "$project" 'gh issue view 76 --json title,body,comments')"
check "gh issue comment" "" "$(bash_in "$project" 'gh issue comment 76 --body-file r.md')"
check "a supervise script" "" "$(bash_in "$project" "sh $CLAUDE_PLUGIN_ROOT/skills/supervise/scripts/watch.sh --id c2a368ee --dir $project")"
check "claude stop" "" "$(bash_in "$project" 'claude stop c2a368ee')"
check "a commit message naming a refused command" "" "$(bash_in "$project" 'git log --grep "git commit"')"
check "git -C another checkout" "" "$(bash_in "$project" "git -C $other commit -m m")"
check "cd to another checkout first" "" "$(bash_in "$project" "cd $other && git commit -m m")"
check "git commit in another checkout" "" "$(bash_in "$other" 'git commit -m m')"
check "git commit in a linked worktree" "" "$(bash_in "$work/linked" 'git commit -m m')"

# The refusal names the worker, claude attach, and how to clear a stale
# marker.
reason=$(run 1 "$project" Bash '{"command":"git commit -m m"}' | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
check "refusal names the worker and how to clear its marker" \
    "Background worker c2a368ee holds the checkout $project, so this session stays read-only there until it stops (#76): no file edits and no git commit, merge, rebase, checkout, switch, reset or stash. Open the worker with \`claude attach c2a368ee\`. If it has stopped, clear its marker: sh '$CLAUDE_PLUGIN_ROOT/skills/supervise/scripts/release.sh' --dir '$project' --id c2a368ee" \
    "$reason"

# Worker sessions (unattended) are unaffected; a session that does not say
# is attended.
check "unattended: Edit allowed" "" "$(decide 0 "$project" Edit "$(jq -cn --arg p "$project/README" '{file_path:$p}')")"
check "unattended: git commit allowed" "" "$(decide 0 "$project" Bash '{"command":"git commit -m m"}')"
check "attended unset: git commit refused" "deny" "$(decide unset "$project" Bash '{"command":"git commit -m m"}')"

# Without a marker, nothing is refused.
command rm -f "$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
check "no marker: Edit allowed" "" "$(edit Edit "$project" "$project/README")"
check "no marker: git commit allowed" "" "$(bash_in "$project" 'git commit -m m')"

# The matcher names the four tools the hook reads.
check "matcher" "Edit|Write|NotebookEdit|Bash" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

echo "supervise-read-only: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
