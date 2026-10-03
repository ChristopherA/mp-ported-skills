#!/bin/sh
# supervise-last-message.test.sh -- tests for the supervise skill's
# last-message.sh.
#
# Installs recorded transcripts from tests/fixtures/transcripts/ under a
# scratch config dir, in a worktree's project folder as the recorded worker's
# was filed, with each text block filled in with a marker naming its row
# (the fixtures keep only the rows' shape). A fake `claude` on PATH prints a
# `claude agents --json --all` fixture naming the worker's sessionId. Touches
# nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-last-message.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/supervise/scripts/last-message.sh"
transcripts="$root/tests/fixtures/transcripts"
agents="$root/tests/fixtures/agents-json"
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

# Every variable the script reads, set or unset here, so the result does not
# depend on the session running the test.
unset FAKE_AGENTS CLAUDE_CODE_SESSION_ATTENDED
cfg="$work/config"
mkdir -p "$cfg/projects"
export CLAUDE_CONFIG_DIR="$cfg"

# --- fake claude -----------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/claude" <<'EOF'
#!/bin/sh
[ "$*" = "agents --json --all" ] || { echo "fake claude: unexpected $*" >&2; exit 1; }
[ -n "${FAKE_AGENTS:-}" ] || { echo "claude agents: not reachable" >&2; exit 1; }
command cat "$FAKE_AGENTS"
EOF
chmod +x "$work/bin/claude"
if [ "$(PATH="$work/bin:$PATH" command -v claude)" != "$work/bin/claude" ]; then
    echo "FAIL fake claude is not first on PATH; not running the rest" >&2
    exit 1
fi

sid=9121ff49-5e25-43f0-bf48-307db0776c36
worktree_folder="$cfg/projects/-work-project--claude-worktrees-issue-66"

# transcript <fixture> [jq filter] -- install the fixture as the worker's
# transcript in the worktree's folder, each assistant text block reading
# `message <row>` and each user one `prompt <row>`, then the filter.
transcript() {
    command rm -rf "$cfg/projects"
    mkdir -p "$worktree_folder"
    jq -c '
        . as $row | input_line_number as $line
        | if (.message.content | type) == "array" then
            .message.content |= map(if .type == "text"
                then .text = (if $row.type == "assistant" then "message " else "prompt " end) + ($line | tostring)
                else . end)
          else . end' "$transcripts/$1.jsonl" |
        jq -c "${2:-.}" >"$worktree_folder/$sid.jsonl"
}

# run [args...] -- last-message.sh with the fake claude and done.json, which
# names worker 9121ff49 with session $sid; stdout and stderr kept apart.
run() {
    (
        PATH="$work/bin:$PATH"
        FAKE_AGENTS=${agents_file:-$agents/done.json}
        export FAKE_AGENTS
        sh "$script" "$@" >"$work/out" 2>"$work/err" </dev/null
        echo $? >"$work/rc"
    )
}
out() { command cat "$work/out"; }
err() { command cat "$work/err"; }
rc() { command cat "$work/rc"; }

# --- the last message ------------------------------------------------------
# turn-ended.jsonl ends with the worker's final summary (row 23) and a
# turn_duration row with no agents pending.
transcript turn-ended
run --id 9121ff49
check "ended: prints the last assistant text" "message 23" "$(out)"
check "ended: exit 0" "0" "$(rc)"
check "ended: no note" "" "$(err)"

# The transcript is filed under the worktree's folder, not the cwd's.
check "worktree: transcript is under the worktree folder" "yes" \
    "$([ -f "$worktree_folder/$sid.jsonl" ] && [ ! -d "$cfg/projects/-work-project" ] && echo yes)"

run --id 9121ff49 --count 2
check "count 2: the last two, oldest first" "message 15

message 23" "$(out)"

run --id 9121ff49 --count 5
check "count past the messages: all of them" "message 15

message 23" "$(out)"

# A text block that spans lines comes out whole.
transcript turn-ended 'if .type == "assistant" and .message.content[0].text == "message 23"
    then .message.content[0].text = "Done.\n\nWaiting on: git push origin main" else . end'
run --id 9121ff49
check "multi-line text prints whole" "Done.

Waiting on: git push origin main" "$(out)"

# A sidechain row is a subagent's, not the worker's.
transcript turn-ended
printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent text"}]}}' \
    >>"$worktree_folder/$sid.jsonl"
run --id 9121ff49
check "sidechain text is skipped" "message 23" "$(out)"

# --- a turn that is not over ----------------------------------------------
# waiting-on-agents.jsonl ends with a turn_duration row with 2 agents
# pending: its last text is an interim note, not the final summary.
transcript waiting-on-agents
run --id 9121ff49
check "agents pending: prints the interim text" "message 23" "$(out)"
check "agents pending: exit 0" "0" "$(rc)"
check "agents pending: notes it may be interim" \
    "note: the worker's turn ended with 2 background agents pending; this may be an interim message, not its final summary" "$(err)"

# Cut before its turn_duration row, the turn has not ended.
transcript turn-ended 'select(input_line_number < 24)'
run --id 9121ff49
check "mid-turn: prints the latest text" "message 23" "$(out)"
check "mid-turn: notes the turn has not ended" \
    "note: the worker's turn has not ended; this is its latest message so far" "$(err)"

# --- nothing to print ------------------------------------------------------
transcript just-launched
run --id 9121ff49
check "no text yet: exit 1" "1" "$(rc)"
check "no text yet: nothing on stdout" "" "$(out)"
check "no text yet: says so" \
    "Error: the transcript of worker 9121ff49 holds no message from it yet" "$(err)"

command rm -rf "$cfg/projects"
mkdir -p "$cfg/projects"
run --id 9121ff49
check "no transcript: exit 1" "1" "$(rc)"
check "no transcript: nothing on stdout" "" "$(out)"
check "no transcript: says so" \
    "Error: no transcript for worker 9121ff49 (session $sid) under $cfg/projects" "$(err)"

transcript turn-ended
run --id 0badc0de
check "unknown worker: exit 1" "1" "$(rc)"
check "unknown worker: nothing on stdout" "" "$(out)"
check "unknown worker: says so" \
    "Error: claude agents lists no background session 0badc0de" "$(err)"

agents_file=/nonexistent
run --id 9121ff49
check "agents unreadable: exit 1" "1" "$(rc)"
check "agents unreadable: nothing on stdout" "" "$(out)"
check "agents unreadable: says so" \
    "Error: claude agents --json --all could not be read" "$(err)"
unset agents_file

run
check "no id: exit 1" "1" "$(rc)"
check "no id: says so" "Error: --id is required" "$(err)"

run --id 9121ff49 --count 0
check "bad count: exit 1" "1" "$(rc)"
check "bad count: says so" "Error: --count must be a whole number of 1 or more" "$(err)"

printf 'supervise-last-message: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
