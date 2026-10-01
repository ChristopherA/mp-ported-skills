#!/bin/sh
# deny-worker-grant-edits.test.sh -- tests for the PreToolUse hook that
# refuses a background worker's own edit to docs/agents/supervision.md or
# the profile directory (#58).
#
# Runs the command string from hooks.json, as Claude Code does, with a
# PreToolUse payload on stdin and CLAUDE_CODE_SESSION_ATTENDED set the way
# Claude Code sets it in a background session's own process. Touches
# nothing outside its own mktemp directories.
#
# Usage: sh tests/deny-worker-grant-edits.test.sh

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

entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("deny-worker-grant-edits"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

run() { # <attended> <mode> <tool> <path> <cwd> [<config dir>]
    payload=$(jq -cn --arg mode "$2" --arg tool "$3" --arg path "$4" --arg cwd "$5" \
        '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:$mode,tool_name:$tool,
          tool_input:(if $tool == "NotebookEdit" then {notebook_path:$path} else {file_path:$path} end),
          cwd:$cwd}')
    printf '%s' "$payload" | CLAUDE_CODE_SESSION_ATTENDED="$1" CLAUDE_CONFIG_DIR="${6:-}" sh -c "$hook_cmd"
}
decision() { run "$1" "$2" "$3" "$4" "$5" "${6:-}" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
reason() { run "$1" "$2" "$3" "$4" "$5" "${6:-}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

repo=$(mktemp -d)
repo=$(CDPATH= cd -- "$repo" && pwd -P)
git init -q -b main "$repo"
git -C "$repo" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
mkdir -p "$repo/docs/agents" "$repo/sub"

cfg=$(mktemp -d)

# The grant file, whether it exists yet or not, in an unattended auto-mode
# session: refused.
check "Write to a new supervision.md: deny" "deny" \
    "$(decision 0 auto Write "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
touch "$repo/docs/agents/supervision.md"
check "Edit of an existing supervision.md: deny" "deny" \
    "$(decision 0 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "NotebookEdit targeting supervision.md: deny" "deny" \
    "$(decision 0 auto NotebookEdit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "a relative path resolved against cwd: deny" "deny" \
    "$(decision 0 auto Edit docs/agents/supervision.md "$repo" "$cfg")"
check "the same file via a session run inside a subfolder: deny" "deny" \
    "$(decision 0 auto Edit "$repo/docs/agents/supervision.md" "$repo/sub" "$cfg")"

check "refusal names #58 and the maintainer's own session" \
    "A background session in auto mode cannot edit docs/agents/supervision.md on its own (#58): a worker that could grant itself a standing grant would make the grant meaningless. Leave this to the maintainer's own interactive session." \
    "$(reason 0 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# A different file in the same folder, or a similarly named file elsewhere,
# is not the grant file.
check "a sibling file in docs/agents is not refused" "" \
    "$(decision 0 auto Edit "$repo/docs/agents/domain.md" "$repo" "$cfg")"
check "supervision.md outside docs/agents is not refused" "" \
    "$(decision 0 auto Edit "$repo/supervision.md" "$repo" "$cfg")"
check "a file outside any checkout is not refused" "" \
    "$(decision 0 auto Edit "$(mktemp -d)/x.md" "$(mktemp -d)" "$cfg")"

# The profile directory: refused, nested or not.
check "a write under the profile directory: deny" "deny" \
    "$(decision 0 auto Write "$cfg/rules/x.md" "$repo" "$cfg")"
check "a write to the profile's settings.json: deny" "deny" \
    "$(decision 0 auto Edit "$cfg/settings.json" "$repo" "$cfg")"
check "refusal names the profile directory" \
    "A background session in auto mode cannot edit its own profile directory ($cfg) on its own (#58): that is where this session's rules, settings and hooks live, and a worker that could change them could change what gates it. Leave this to the maintainer's own interactive session." \
    "$(reason 0 auto Write "$cfg/rules/x.md" "$repo" "$cfg")"
check "a folder that only shares the profile dir's prefix is not refused" "" \
    "$(decision 0 auto Write "${cfg}-other/x.md" "$repo" "$cfg")"
check "no CLAUDE_CONFIG_DIR set: the profile check is skipped, not an error" "" \
    "$(decision 0 auto Write "$repo/elsewhere.md" "$repo" "")"

# The maintainer's own interactive session: attended, whatever the
# permission mode.
check "attended, auto mode: edit allowed" "" \
    "$(decision 1 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "attended, default mode: edit allowed" "" \
    "$(decision 1 default Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# Unattended outside auto mode: out of the way, as deny-shared-actions.sh
# treats it.
check "unattended, default mode: edit allowed" "" \
    "$(decision 0 default Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# A non-Edit/Write/NotebookEdit tool is never inspected.
check "Bash is not inspected (known gap)" "" \
    "$(decision 0 auto Bash "sed -i '' -e s/x/y/ $repo/docs/agents/supervision.md" "$repo" "$cfg")"

check "matcher: Edit, Write, NotebookEdit only" "Edit|Write|NotebookEdit" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

command rm -rf "$repo" "$cfg"

echo "deny-worker-grant-edits: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
