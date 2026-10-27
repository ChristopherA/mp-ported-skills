#!/bin/sh
# supervise-zone.test.sh -- tests for the supervise skill's zone.sh, and
# watch.sh --zone, which returns `zone` when a working worker's reading is
# due for a capture (#60).
#
# Checks the reading against the status line on a live pair: a session's
# transcript, cut to its shapes and usage counts (tests/fixtures/
# transcripts/zone-reading.jsonl), and the record its status line wrote
# after its last call (zone-reading-record.json), read through glance.sh.
# Reads the recorded hand-run transcript (hand-run.jsonl) for the rest. The safe-point cases
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
# The live pair: what the status line recorded, and the transcript's reading.
pair_sid=$(jq -r .session_id "$transcripts/zone-reading-record.json")
mkdir -p "$work/live-ctx" "$work/project"
jq -c --arg p "$work/project" '.project_dir = $p' "$transcripts/zone-reading-record.json" \
    >"$work/live-ctx/claude-$pair_sid-zone.json"
out=$(zone --transcript "$transcripts/zone-reading.jsonl")
check "reading: a live session's, as its status line recorded it" \
    "$( (export WORKSTREAM_KIT_CONTEXT_DIR="$work/live-ctx"
        sh "$root/plugins/mp-ported-skills/skills/glance/scripts/glance.sh" "$work/project" "$pair_sid" </dev/null) )" "$out"
check "reading: that live session's reading" "103% of zone" "$out"

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
mkdir -p "$work/ctx"
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
# two polls 30 seconds apart a worker's context grew by up to the margin
# measured in docs/research/zone-poll-margin.md, so the force point plus
# that margin must stay under the smaller window's point.
threshold=$(sed -n 's/^ZONE_CAPTURE=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
force=$(sed -n 's/^ZONE_FORCE=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
margin=$(sed -n 's/^ZONE_MARGIN_K=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
note="$root/docs/research/zone-poll-margin.md"
measured=$(sed -n 's/^- Largest growth in 30 seconds: \([0-9][0-9]*\) tokens.*/\1/p' "$note" 2>/dev/null)
check "threshold: set in zone.sh" "yes" "$([ -n "$threshold" ] && echo yes || echo no)"
check "threshold: the force point, set in zone.sh, is past the threshold" "yes" \
    "$([ -n "$force" ] && [ "$force" -gt "$threshold" ] && echo yes || echo no)"
check "threshold: the margin is the research note's measurement, rounded up to 1k" "yes" \
    "$([ -n "$margin" ] && [ -n "$measured" ] && [ $((margin * 1000)) -ge "$measured" ] &&
        [ $((margin * 1000 - 1000)) -lt "$measured" ] && echo yes || echo "no (margin $margin, measured $measured)")"
check "threshold: plus the margin stays below a 200k window's auto-compact point" "yes" \
    "$([ $((threshold * 150000 / 100 + margin * 1000)) -lt $((200000 * 80 / 100)) ] && echo yes || echo no)"
check "threshold: the force point plus the margin stays below that point" "yes" \
    "$([ $((force * 150000 / 100 + margin * 1000)) -lt $((200000 * 80 / 100)) ] && echo yes || echo no)"
check "threshold: zone.sh names it in its not-due line" "not due: below $threshold% of zone" \
    "$(zone --transcript "$hand" --due | sed -n 2p)"

# --- the auto-compact point, against the force point ---------------------------
compact() { zone --compact "$@"; }
out=$(compact claude-opus-5-5); rc=$?
check "compact: a 1M model passes, and captures at 100%" "compact point 533% of zone (80% of a 1000k window)
capture due at 100% of zone, forced at 108%" "$out"
check "compact: a 1M model exits 0" "0" "$rc"
check "compact: a [1m] model id is a 1M window" "compact point 533% of zone (80% of a 1000k window)
capture due at 100% of zone, forced at 108%" \
    "$(compact 'claude-sonnet-5[1m]')"
out=$(compact claude-made-up-1); rc=$?
check "compact: an unknown window is read as 200k, and says so" "note: the context window of model claude-made-up-1 is not known, so the smallest, 200k, is used
compact point 106% of zone (80% of a 200k window)
capture due at 64% of zone, forced at 72%" "$out"
check "compact: the default override with a 200k window exits 0" "0" "$rc"
check "compact: no model is read as 200k, and says so" "note: the worker's model is not known, so the smallest context window, 200k, is used
compact point 106% of zone (80% of a 200k window)
capture due at 64% of zone, forced at 72%" "$(compact '')"
out=$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; compact claude-made-up-1 2>&1 | grep -v '^note: ') )
check "compact: a low override refuses, naming both points" "Error: the zone capture's force point, $force% of zone, plus the largest growth measured between two polls, ${margin}k tokens, reaches the worker's auto-compact point, 80% of zone (60% of a 200k window), so it could compact before the capture" "$out"
(export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; compact claude-made-up-1 >/dev/null 2>&1); rc=$?
check "compact: a refusal exits 1" "1" "$rc"
check "compact: the same low override passes on a 1M window" "compact point 400% of zone (60% of a 1000k window)
capture due at 100% of zone, forced at 108%" \
    "$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; compact claude-opus-5-5) )"
check "compact: an override with a leading zero is read as decimal" "compact point 400% of zone (60% of a 1000k window)
capture due at 100% of zone, forced at 108%" \
    "$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=060; compact claude-opus-5-5) )"
check "compact: a larger zone moves the force point" "1" \
    "$( (export MP_SMART_ZONE_K=220; compact claude-made-up-1 >/dev/null 2>&1; echo $?) )"
compact >/dev/null; check "compact: needs a value" "1" "$?"

# --- the capture point, by the room the compact point leaves -------------------
# A compact point at least ZONE_CAPTURE_ROOM past the wide capture point, 150%
# of zone, captures at 100% and forces 8 points later; any lower one keeps
# the 200k window's pair. 1000k * 33% / 220k is exactly 150%; 1000k * 82% /
# 550k is 149%.
wide=$(sed -n 's/^ZONE_CAPTURE_WIDE=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
room=$(sed -n 's/^ZONE_CAPTURE_ROOM=\([0-9][0-9]*\).*/\1/p' "$scripts/zone.sh")
check "capture point: the wide one is 100% of zone" "100" "$wide"
check "capture point: it needs 50 points of room" "50" "$room"
check "capture point: a compact point of exactly 150% captures at 100%" "compact point 150% of zone (33% of a 1000k window)
capture due at 100% of zone, forced at 108%" \
    "$( (export MP_SMART_ZONE_K=220 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=33; compact claude-opus-5-5) )"
check "capture point: one at 149% keeps 64% and 72%" "compact point 149% of zone (82% of a 1000k window)
capture due at 64% of zone, forced at 72%" \
    "$( (export MP_SMART_ZONE_K=550 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=82; compact claude-opus-5-5) )"
# The wide pair also needs its force point plus the margin below the compact
# point. On a 100k zone at 15%, 1000k compacts at exactly 150%, but 108% of
# 100k plus 50k reaches it, so the worker keeps the pair that clears.
check "capture point: a wide pair the margin refuses falls back to 64% and 72%" "compact point 150% of zone (15% of a 1000k window)
capture due at 64% of zone, forced at 72%" \
    "$( (export MP_SMART_ZONE_K=100 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=15; compact claude-opus-5-5) )"

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
due_on() { zone --transcript "$work/t.jsonl" --due --model "$1"; } # <model>

{ call 60000 a; result a; call 96000 b; result b; } >"$work/t.jsonl"
out=$(due); rc=$?
check "due: at 64% with every call answered" "64% of zone
due" "$out"
check "due: exit 0" "0" "$rc"

{ call 60000 a; result a; call 94500 b; result b; } >"$work/t.jsonl"
out=$(due); rc=$?
check "due: below the threshold is not due" "63% of zone
not due: below 64% of zone" "$out"
check "due: not due exits 2" "2" "$rc"

{ call 60000 a; result a; call 102000 b; } >"$work/t.jsonl"
check "due: a tool call still running is not a safe point" "68% of zone
not due: a tool call is running" "$(due)"

{ call 60000 a; call 102000 b; result b; } >"$work/t.jsonl"
check "due: an earlier call with no result is still running" "68% of zone
not due: a tool call is running" "$(due)"

# The recorded mid-turn fixture keeps no ids; its last row is a tool_use.
jq -c 'if .type == "assistant" then .message.usage = {input_tokens: 2, cache_read_input_tokens: 101998,
        cache_creation_input_tokens: 0, output_tokens: 1} else . end' \
    "$transcripts/mid-turn.jsonl" >"$work/t.jsonl"
check "due: a last row that calls a tool, with no ids" "68% of zone
not due: a tool call is running" "$(due)"

{ call 60000 a; result a '{"backgroundTaskId":"bbij1","stdout":""}'; call 102000 b; result b; } >"$work/t.jsonl"
check "due: a background command still running" "68% of zone
not due: background task bbij1 is running" "$(due)"
# A tool's output that quotes a notification's tag does not end the task.
jq -cn '{type: "user", isSidechain: false, message: {role: "user",
    content: [{type: "tool_result", tool_use_id: "q", content: "<task-id>bbij1</task-id>"}]}}' >>"$work/t.jsonl"
check "due: a quoted task tag does not end the task" "68% of zone
not due: background task bbij1 is running" "$(due)"
notified bbij1 >>"$work/t.jsonl"
check "due: a background command that ended" "68% of zone
due" "$(due)"

{ call 60000 a; result a '{"isAsync":true,"status":"async_launched","agentId":"aa30"}'; call 102000 b; result b; } >"$work/t.jsonl"
check "due: an async agent still running" "68% of zone
not due: background task aa30 is running" "$(due)"
jq -cn '{type: "queue-operation", operation: "enqueue",
    content: "<task-notification>\n<task-id>aa30</task-id>\n<status>completed</status>\n</task-notification>"}' >>"$work/t.jsonl"
check "due: an async agent whose report is queued" "68% of zone
due" "$(due)"

# From the force point, a background task no longer holds the capture; a
# running tool call still does.
{ call 60000 a; result a '{"isAsync":true,"agentId":"rev1"}'; call "$((force * 1500))" b; result b; } >"$work/t.jsonl"
out=$(due); rc=$?
check "due: at the force point, a background task is cut" "$force% of zone
due: background task rev1 is cut" "$out"
check "due: a cut is due, exit 0" "0" "$rc"
{ call 60000 a; result a '{"isAsync":true,"agentId":"rev1"}'; call "$((force * 1500 - 1500))" b; result b; } >"$work/t.jsonl"
check "due: just below it, a background task still holds" "$((force - 1))% of zone
not due: background task rev1 is running" "$(due)"
{ call 60000 a; result a; call 160000 b; } >"$work/t.jsonl"
check "due: a running tool call holds at any reading" "106% of zone
not due: a tool call is running" "$(due)"

# The capture point follows the worker's model: a 1M window captures at 100%
# and forces at 108%; a window not known, or no model, keeps 64% and 72%.
{ call 60000 a; result a; call 120000 b; result b; } >"$work/t.jsonl"
check "due: a 1M model is not due at 80%" "80% of zone
not due: below 100% of zone" "$(due_on claude-opus-5-5)"
{ call 60000 a; result a; call 149999 b; result b; } >"$work/t.jsonl"
check "due: a 1M model is not due at 99%" "99% of zone
not due: below 100% of zone" "$(due_on claude-opus-5-5)"
{ call 60000 a; result a; call 150000 b; result b; } >"$work/t.jsonl"
out=$(due_on claude-opus-5-5); rc=$?
check "due: a 1M model is due at 100%" "100% of zone
due" "$out"
check "due: a 1M model due exits 0" "0" "$rc"
{ call 60000 a; result a '{"isAsync":true,"agentId":"rev1"}'; call 160499 b; result b; } >"$work/t.jsonl"
check "due: a 1M model's background task holds at 106%" "106% of zone
not due: background task rev1 is running" "$(due_on 'claude-sonnet-5[1m]')"
{ call 60000 a; result a '{"isAsync":true,"agentId":"rev1"}'; call 162000 b; result b; } >"$work/t.jsonl"
check "due: a 1M model's background task is cut at 108%" "108% of zone
due: background task rev1 is cut" "$(due_on claude-opus-5-5)"
{ call 60000 a; result a; call 96000 b; result b; } >"$work/t.jsonl"
check "due: a window not known is due at 64%" "64% of zone
due" "$(due_on claude-made-up-1)"
check "due: an empty model is due at 64%" "64% of zone
due" "$(due_on '')"
{ call 60000 a; result a; call 94500 b; result b; } >"$work/t.jsonl"
check "due: a window not known names 64% in its not-due line" "63% of zone
not due: below 64% of zone" "$(due_on claude-made-up-1)"
{ call 60000 a; result a '{"isAsync":true,"agentId":"rev1"}'; call 108000 b; result b; } >"$work/t.jsonl"
check "due: a window not known cuts a background task at 72%" "72% of zone
due: background task rev1 is cut" "$(due_on claude-made-up-1)"
{ call 60000 a; result a; call 352000 b; result b; } >"$work/t.jsonl"
check "due: a compact point of 149% is due at 64%" "64% of zone
due" "$( (export MP_SMART_ZONE_K=550 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=82; due_on claude-opus-5-5) )"
zone --transcript "$work/t.jsonl" --model >/dev/null; check "due: --model needs a value" "1" "$?"
check "due: --model is not for --compact" "Error: --compact takes the model as its value; give it alone" \
    "$(zone --compact claude-opus-5-5 --model claude-opus-5-5)"

# A last line still being written is skipped.
{ call 60000 a; result a; call 102000 b; result b; printf '{"type":"assistant","mess'; } >"$work/t.jsonl"
check "due: a half-written last line is skipped" "68% of zone
due" "$(due)"

# A subagent's own pending call, on a sidechain row, is the Agent call's,
# which is already counted on the main chain.
{ call 60000 a; result a; call 102000 b; result b
  jq -cn '{type: "assistant", isSidechain: true, message: {role: "assistant",
      content: [{type: "tool_use", id: "sub1", name: "Read"}]}}'; } >"$work/t.jsonl"
check "due: a sidechain call does not hold it" "68% of zone
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
# The job's flags name the worker's model, as launch.sh launches it.
job() { # <model or empty>
    jq -cn --arg s "$wsid" --arg m "$1" '{sessionId: $s,
        respawnFlags: (["--permission-mode", "auto"] + (if $m == "" then [] else ["--model", $m] end))}' \
        >"$cfg/jobs/c2a368ee/state.json"
}

{ call 60000 a; result a; call 90000 b; result b; } >"$work/t.jsonl"; put
job claude-made-up-1
out=$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; watch --zone) ); rc=$?
check "watch --zone: a low override refuses before the watch, naming both points" "Error: the zone capture's force point, $force% of zone, plus the largest growth measured between two polls, ${margin}k tokens, reaches the worker's auto-compact point, 80% of zone (60% of a 200k window), so it could compact before the capture" \
    "$(printf '%s\n' "$out" | grep -v '^note: ')"
check "watch --zone: a refusal exits 1" "1" "$rc"
check "watch: without --zone, the override is not checked" "working
cwd /work/project" "$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; watch) )"
check "watch --zone: an unknown window says so, and watches on" "note: the context window of model claude-made-up-1 is not known, so the smallest, 200k, is used
working
cwd /work/project" "$(watch --zone)"
job ""
check "watch --zone: a job naming no model says so, and watches on" "note: the worker's model is not known, so the smallest context window, 200k, is used
working
cwd /work/project" "$(watch --zone)"
job claude-opus-5-5
check "watch --zone: the low override passes on a 1M model" "working
cwd /work/project" "$( (export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60; watch --zone) )"
{ call 60000 a; result a; call 148500 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: a 1M model at 99% is still working" "working
cwd /work/project" "$(watch --zone)"
{ call 60000 a; result a; call 150000 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: a 1M model at 100% is capture-due" "capture-due
cwd /work/project
reading 100% of zone
due" "$(watch --zone)"
# The checks below read the 200k window's points; its note is checked above.
job claude-made-up-1
watch() { sh "$scripts/watch.sh" --id c2a368ee --file "$fixtures/working-busy.json" "$@" </dev/null 2>&1 | grep -v '^note: '; }

{ call 60000 a; result a; call 102000 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: due returns capture-due, with the reading" "capture-due
cwd /work/project
reading 68% of zone
due" "$(watch --zone)"
check "watch: without --zone, still working" "working
cwd /work/project" "$(watch)"

{ call 60000 a; result a; call 102000 b; } >"$work/t.jsonl"; put
check "watch --zone: not at a safe point, still working" "working
cwd /work/project" "$(watch --zone)"

{ call 60000 a; result a; call 90000 b; result b; } >"$work/t.jsonl"; put
check "watch --zone: below the threshold, still working" "working
cwd /work/project" "$(watch --zone)"

command rm -rf "$cfg/projects"
check "watch --zone: no transcript, still working" "working
cwd /work/project" "$(watch --zone)"

# A done worker is not capture-due: its settled capture follows the report.
{ call 60000 a; result a; call 102000 b; result b; } >"$work/t.jsonl"
command rm -rf "$cfg/projects"; mkdir -p "$cfg/projects/-work-project"
command cp "$work/t.jsonl" "$cfg/projects/-work-project/9121ff49-5e25-43f0-bf48-307db0776c36.jsonl"
mkdir -p "$cfg/jobs/9121ff49"
printf '{"respawnFlags":["--model","claude-opus-5-5"]}\n' >"$cfg/jobs/9121ff49/state.json"
check "watch --zone: a done worker stays done" "done
cwd /work/project" \
    "$(sh "$scripts/watch.sh" --id 9121ff49 --zone --file "$fixtures/done.json" </dev/null 2>&1)"

printf 'supervise-zone: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
