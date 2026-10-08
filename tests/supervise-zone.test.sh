#!/bin/sh
# supervise-zone.test.sh -- tests for the supervise skill's zone.sh, and
# watch.sh --zone, which returns `zone` when a working worker's reading is
# due for a capture (#60).
#
# Reads the recorded hand-run transcript (tests/fixtures/transcripts/
# hand-run.jsonl) for the reading, and checks it against glance.sh on a
# status-line record holding the same call's tokens. The safe-point cases
# build small transcripts in the row shapes Claude Code writes: tool_use and
# tool_result blocks paired by id, a background Bash result carrying
# toolUseResult.backgroundTaskId, an async agent's carrying isAsync and
# agentId, and the <task-notification> that ends either, as a user row or
# in a queue-operation row's content. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/supervise-zone.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
fixtures="$root/tests/fixtures/agents-json"
transcripts="$root/tests/fixtures/transcripts"
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

# Every variable the scripts read, set or unset here, so the result does not
# depend on the session running the test.
unset MP_SMART_ZONE_K CLAUDE_CODE_SESSION_ID WORKSTREAM_KIT_CONTEXT_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
cfg="$work/config"
mkdir -p "$cfg"
export CLAUDE_CONFIG_DIR="$cfg"

zone() { sh "$scripts/zone.sh" "$@" </dev/null 2>&1; }

# --- the reading, from a recorded transcript --------------------------------
hand="$transcripts/hand-run.jsonl"
out=$(zone --transcript "$hand"); rc=$?
check "reading: exit 0" "0" "$rc"
check "reading: the last call's context, of the zone" "61% of zone" "$out"

# It matches what the status line shows for the same call: glance.sh reads
# the record the status line writes, holding input plus cache read and
# written as the context's tokens.
last=$(jq -s '[.[] | select(.type == "assistant" and .message.usage != null) | .message.usage
        | .input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens] | last' "$hand")
sid=0f3c2b1a-0000-4000-8000-000000000002
mkdir -p "$work/ctx" "$work/project"
printf '{"session_id":"%s","project_dir":"%s","tokens":%s,"remaining_pct":50,"updated":"2026-09-25T20:52:06Z"}\n' \
    "$sid" "$work/project" "$last" >"$work/ctx/claude-$sid-zone.json"
glance() { (export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx"
    sh "$root/plugins/mp-ported-skills/skills/glance/scripts/glance.sh" "$work/project" "$sid" </dev/null); }
check "reading: matches glance" "$(glance)" "$out"
check "reading: matches glance for another zone" \
    "$( (export MP_SMART_ZONE_K=40; glance) )" "$( (export MP_SMART_ZONE_K=40; zone --transcript "$hand") )"

# A subagent's call, in the main transcript as a sidechain row, is not the
# worker's context.
{ command cat "$hand"
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":180000,"cache_creation_input_tokens":0,"output_tokens":5},"content":[{"type":"text"}]}}'
} >"$work/sidechain.jsonl"
check "reading: a sidechain call is left out" "61% of zone" "$(zone --transcript "$work/sidechain.jsonl")"

out=$(zone --transcript "$transcripts/just-launched.jsonl"); rc=$?
check "reading: none before the first call exits 2" "2" "$rc"
check "reading: none before the first call says so" "No reading yet: the session has made no call" "$out"

# --session and --id find the transcript in any project folder.
mkdir -p "$cfg/projects/-work-project-wt" "$cfg/jobs/c2a368ee"
command cp "$hand" "$cfg/projects/-work-project-wt/c2a368ee-c513-484c-83d3-581830e209a5.jsonl"
check "reading: --session" "61% of zone" "$(zone --session c2a368ee-c513-484c-83d3-581830e209a5)"
printf '{"sessionId":"c2a368ee-c513-484c-83d3-581830e209a5"}\n' >"$cfg/jobs/c2a368ee/state.json"
check "reading: --id reads the job's session" "61% of zone" "$(zone --id c2a368ee)"

zone --session nope >/dev/null; check "reading: no transcript exits 1" "1" "$?"
zone --id nope >/dev/null; check "reading: no job exits 1" "1" "$?"
zone --transcript "$work/missing.jsonl" >/dev/null; check "reading: a missing file exits 1" "1" "$?"
zone >/dev/null; check "reading: no source exits 1" "1" "$?"
zone --id a --session b >/dev/null; check "reading: two sources exit 1" "1" "$?"
zone --bogus >/dev/null; check "reading: an unknown option exits 1" "1" "$?"

# --- the threshold -----------------------------------------------------------
# The capture must fire before the session compacts. With the profile's
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE of 80, a 200k-token window compacts at
# 160k tokens, about 106% of a 150k zone; a 1M window at about 533%. Between
# two polls a worker can add at least one tool result, and Read's cap of 25k
# tokens is the largest a single one takes, so the threshold plus that one
# result must stay under the smaller window's point.
threshold=$(sed -n 's/^ZONE_CAPTURE=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
check "threshold: set in zone.sh" "yes" "$([ -n "$threshold" ] && echo yes || echo no)"
check "threshold: plus one Read result stays below a 200k window's auto-compact point" "yes" \
    "$([ $((threshold * 150000 / 100 + 25000)) -lt $((200000 * 80 / 100)) ] && echo yes || echo no)"
check "threshold: zone.sh names it in its not-due line" "not due: below $threshold% of zone" \
    "$(zone --transcript "$hand" --due | sed -n 2p)"

# --- due, at a safe point ----------------------------------------------------
# call <tokens> <tool_use id or empty> -- a main-chain call row
call() {
    jq -cn --argjson t "$1" --arg id "$2" '{type: "assistant", isSidechain: false,
        message: {role: "assistant", usage: {input_tokens: 2, cache_read_input_tokens: ($t - 2),
            cache_creation_input_tokens: 0, output_tokens: 10},
            content: (if $id == "" then [{type: "text"}] else [{type: "tool_use", id: $id, name: "Bash"}] end)}}'
}
result() { # <tool_use id> [toolUseResult json] -- its result row
    jq -cn --arg id "$1" --argjson r "${2:-null}" '{type: "user", isSidechain: false,
        message: {role: "user", content: [{type: "tool_result", tool_use_id: $id}]}}
        + (if $r == null then {} else {toolUseResult: $r} end)'
}
notified() { # <task id> -- a task-notification prompt row
    jq -cn --arg id "$1" '{type: "user", origin: {kind: "task-notification"},
        message: {role: "user", content: ("<task-notification>\n<task-id>" + $id + "</task-id>\n<status>completed</status>\n</task-notification>")}}'
}
due() { zone --transcript "$work/t.jsonl" --due; }

{ call 60000 a; result a; call 120000 b; result b; } >"$work/t.jsonl"
out=$(due); rc=$?
check "due: at 80% with every call answered" "80% of zone
due" "$out"
check "due: exit 0" "0" "$rc"

{ call 60000 a; result a; call 118500 b; result b; } >"$work/t.jsonl"
out=$(due); rc=$?
check "due: below the threshold is not due" "79% of zone
not due: below 80% of zone" "$out"
check "due: not due exits 2" "2" "$rc"

{ call 60000 a; result a; call 130000 b; } >"$work/t.jsonl"
check "due: a tool call still running is not a safe point" "86% of zone
not due: a tool call is running" "$(due)"

{ call 60000 a; call 130000 b; result b; } >"$work/t.jsonl"
check "due: an earlier call with no result is still running" "86% of zone
not due: a tool call is running" "$(due)"

# The recorded mid-turn fixture keeps no ids; its last row is a tool_use.
jq -c 'if .type == "assistant" then .message.usage = {input_tokens: 2, cache_read_input_tokens: 129998,
        cache_creation_input_tokens: 0, output_tokens: 1} else . end' \
    "$transcripts/mid-turn.jsonl" >"$work/t.jsonl"
check "due: a last row that calls a tool, with no ids" "86% of zone
not due: a tool call is running" "$(due)"

{ call 60000 a; result a '{"backgroundTaskId":"bbij1","stdout":""}'; call 130000 b; result b; } >"$work/t.jsonl"
check "due: a background command still running" "86% of zone
not due: background task bbij1 is running" "$(due)"
notified bbij1 >>"$work/t.jsonl"
check "due: a background command that ended" "86% of zone
due" "$(due)"

{ call 60000 a; result a '{"isAsync":true,"status":"async_launched","agentId":"aa30"}'; call 130000 b; result b; } >"$work/t.jsonl"
check "due: an async agent still running" "86% of zone
not due: background task aa30 is running" "$(due)"
jq -cn '{type: "queue-operation", operation: "enqueue",
    content: "<task-notification>\n<task-id>aa30</task-id>\n<status>completed</status>\n</task-notification>"}' >>"$work/t.jsonl"
check "due: an async agent whose report is queued" "86% of zone
due" "$(due)"

# A subagent's own pending call, on a sidechain row, is the Agent call's,
# which is already counted on the main chain.
{ call 60000 a; result a; call 130000 b; result b
  jq -cn '{type: "assistant", isSidechain: true, message: {role: "assistant",
      content: [{type: "tool_use", id: "sub1", name: "Read"}]}}'; } >"$work/t.jsonl"
check "due: a sidechain call does not hold it" "86% of zone
due" "$(due)"

: >"$work/t.jsonl"
out=$(due); rc=$?
check "due: no reading is not due" "No reading yet: the session has made no call
not due: no reading" "$out"
check "due: no reading exits 2" "2" "$rc"

# --- watch.sh --zone ---------------------------------------------------------
# working-busy's worker is c2a368ee, in /work/project.
wsid=c2a368ee-c513-484c-83d3-581830e209a5
put() { command rm -rf "$cfg/projects"; mkdir -p "$cfg/projects/-work-project"; command cp "$work/t.jsonl" "$cfg/projects/-work-project/$wsid.jsonl"; }
watch() { sh "$scripts/watch.sh" --id c2a368ee --file "$fixtures/working-busy.json" "$@" </dev/null 2>&1; }

{ call 60000 a; result a; call 130000 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: due returns zone, with the reading" "zone
cwd /work/project
reading 86% of zone" "$(watch --zone)"
check "watch: without --zone, still working" "working
cwd /work/project" "$(watch)"

{ call 60000 a; result a; call 130000 b; } >"$work/t.jsonl"; put
check "watch --zone: not at a safe point, still working" "working
cwd /work/project" "$(watch --zone)"

{ call 60000 a; result a; call 90000 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: below the threshold, still working" "working
cwd /work/project" "$(watch --zone)"

command rm -rf "$cfg/projects"
check "watch --zone: no transcript, still working" "working
cwd /work/project" "$(watch --zone)"

# A done worker is not a zone stop: its settled capture follows the report.
{ call 60000 a; result a; call 130000 b; result b; } >"$work/t.jsonl"
command rm -rf "$cfg/projects"; mkdir -p "$cfg/projects/-work-project"
command cp "$work/t.jsonl" "$cfg/projects/-work-project/9121ff49-5e25-43f0-bf48-307db0776c36.jsonl"
check "watch --zone: a done worker stays done" "done
cwd /work/project" \
    "$(sh "$scripts/watch.sh" --id 9121ff49 --zone --file "$fixtures/done.json" </dev/null 2>&1)"

printf 'supervise-zone: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
