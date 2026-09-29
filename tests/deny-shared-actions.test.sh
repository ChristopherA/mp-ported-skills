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

entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("deny-shared-actions"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

run() { # <attended> <mode> <tool> <command>: the hook's full JSON output
    payload=$(jq -cn --arg mode "$2" --arg tool "$3" --arg cmd "$4" \
        '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:$mode,tool_name:$tool,tool_input:{command:$cmd}}')
    printf '%s' "$payload" | CLAUDE_CODE_SESSION_ATTENDED="$1" sh -c "$hook_cmd"
}

decision() { run "$1" "$2" Bash "$3" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
reason() { run "$1" "$2" Bash "$3" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

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

# The refusal names the grant file and the supervisor.
check "refusal names the grant file and the supervisor" \
    "A background session in auto mode cannot run 'git push' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    "$(reason 0 auto 'git push')"

# The granted route: a shared action the ticket does not name goes through,
# so #58's grant check, when built, is the only thing that can still stop
# it here.
check "gh pr view (not a shared action)" "" "$(decision 0 auto 'gh pr view 5')"
check "a script that itself runs git push is not inspected" "" \
    "$(decision 0 auto 'sh scripts/granted-push.sh')"

# Commands that only resemble a refused form.
check "git commit whose message says push" "" \
    "$(decision 0 auto 'git commit -m "remember to push later"')"
check "git status" "" "$(decision 0 auto 'git status')"
check "a git-named command that is not git" "" "$(decision 0 auto 'mygit push')"
check "gh issue list is not gh issue close" "" "$(decision 0 auto 'gh issue list')"
check "env with no git/gh is unaffected" "" "$(decision 0 auto 'env NODE_ENV=test npm test')"

# Known, documented gap: sh -c/eval indirection is not recognized, since
# this splitter does not parse shell quoting (docs/adr/0004). This case
# pins that boundary so it reads as a deliberate limit, not a regression.
check "sh -c indirection is a known gap, not covered" "" "$(decision 0 auto 'sh -c "git push"')"

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

echo "deny-shared-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
