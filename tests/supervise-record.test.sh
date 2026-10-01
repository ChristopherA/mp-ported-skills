#!/bin/sh
# supervise-record.test.sh -- tests for the supervise skill's record.sh.
#
# Builds one supervised run in miniature under a scratch config dir: the
# job's state.json (from tests/fixtures/agents-json/job-state.json) and
# timeline.jsonl, the worker's transcript and a subagent's, and the
# supervisor's transcript, with the row shapes Claude Code 2.1.285 writes,
# against a scratch repo with a bare remote and a fake `gh` on PATH. The
# timeline's `blocked` row copies the shape of the `working` and `done` rows a
# live job wrote; no live job's blocked row has been recorded. Then runs it
# on recorded fixtures: a live job (tests/fixtures/jobs/1420c08b) and a
# hand-run /implement session (tests/fixtures/transcripts/hand-run), whose
# peak zone reading it checks against glance.sh. Touches nothing outside its
# own mktemp directory.
#
# Usage: sh tests/supervise-record.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
fixtures="$root/tests/fixtures/agents-json"
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
unset MP_SMART_ZONE_K CLAUDE_CODE_SESSION_ID FAKE_GH_FAIL WORKSTREAM_KIT_CONTEXT_DIR CLAUDE_CODE_SESSION_ATTENDED
cfg="$work/config"
mkdir -p "$cfg"
export CLAUDE_CONFIG_DIR="$cfg"

# --- fake gh ---------------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: not reachable" >&2; exit 1; }
[ "$*" = "issue view 56 --json state --jq .state" ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
echo CLOSED
EOF
chmod +x "$work/bin/gh"
if [ "$(PATH="$work/bin:$PATH" command -v gh)" != "$work/bin/gh" ]; then
    echo "FAIL fake gh is not first on PATH; not running the rest" >&2
    exit 1
fi

# --- the Project -----------------------------------------------------------
repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}
remote="$work/remote.git"
repo="$work/project"
git init -q --bare "$remote"
git init -q -b main "$repo"
repo_git "$repo" commit -q --allow-empty -m start
repo_git "$repo" remote add origin "$remote"
repo_git "$repo" push -q origin main 2>/dev/null
start=$(git -C "$repo" rev-parse HEAD)
short=$(git -C "$repo" rev-parse --short "$start")
repo_git "$repo" commit -q --allow-empty -m "worker's first commit"
repo_git "$repo" commit -q --allow-empty -m "worker's second commit"
repo_git "$repo" push -q origin HEAD:56-topic 2>/dev/null

# --- the run ---------------------------------------------------------------
# Launched 06:01:24, turn ended 06:14:24, reported 06:15:24.
sid=c2a368ee-c513-484c-83d3-581830e209a5
sup=5f0e1d2c-0000-4000-8000-000000000001
job() { # [jq filter] -- install job c2a368ee's state.json and timeline
    command rm -rf "$cfg/jobs"
    mkdir -p "$cfg/jobs/c2a368ee"
    jq "${1:-.}" "$fixtures/job-state.json" >"$cfg/jobs/c2a368ee/state.json"
    {
        echo '{"at":"2026-09-29T06:01:30.000Z","state":"working","detail":"","text":""}'
        echo '{"at":"2026-09-29T06:03:00.000Z","state":"blocked","detail":"approve Bash: git push","text":""}'
        echo '{"at":"2026-09-29T06:04:00.000Z","state":"working","detail":"","text":""}'
        echo '{"at":"2026-09-29T06:14:24.529Z","state":"done","detail":"implemented #56","text":"Done."}'
    } >"$cfg/jobs/c2a368ee/timeline.jsonl"
}
call() { # <time> <request> <model> <input> <cache read> <cache created> <output> [content json]
    content='[{"type":"text","text":"ok"}]'
    [ $# -lt 8 ] || content=$8
    jq -cn --arg t "$1" --arg r "$2" --arg m "$3" --argjson i "$4" --argjson cr "$5" --argjson cc "$6" \
        --argjson o "$7" --argjson c "$content" \
        '{type: "assistant", timestamp: $t, requestId: $r,
          message: {role: "assistant", model: $m, content: $c,
                    usage: {input_tokens: $i, cache_read_input_tokens: $cr,
                            cache_creation_input_tokens: $cc, output_tokens: $o}}}'
}
said() { # <time> <text> -- a user row with plain text content
    jq -cn --arg t "$1" --arg s "$2" '{type: "user", timestamp: $t, message: {role: "user", content: $s}}'
}
cost() { # <total> <model usage json> -- a cost-state row
    jq -cn --argjson c "$1" --argjson u "$2" '{type: "cost-state", totalCostUSD: $c, modelUsage: $u}'
}
worker() { # install the worker's transcript and its subagent's
    dir="$cfg/projects/-work-project"
    mkdir -p "$dir/$sid/subagents"
    {
        said 2026-09-29T06:01:25.000Z '<command-message>mattpocock-skills:implement</command-message>'
        # One call, written as two rows: a request is counted once.
        call 2026-09-29T06:02:00.000Z r1 claude-sonnet-5 2 0 60000 100
        call 2026-09-29T06:02:01.000Z r1 claude-sonnet-5 2 0 60000 100
        call 2026-09-29T06:05:00.000Z r2 claude-sonnet-5 2 60000 100000 200 \
            '[{"type":"tool_use","id":"s1","name":"Skill","input":{"skill":"mp-ported-skills:capturing"}}]'
        jq -cn '{type: "user", timestamp: "2026-09-29T06:05:01.000Z", message: {role: "user",
            content: [{type: "tool_result", tool_use_id: "s1", content: "Launching skill"}]}}'
        jq -cn '{type: "system", subtype: "compact_boundary", timestamp: "2026-09-29T06:06:00.000Z"}'
        said 2026-09-29T06:07:00.000Z '<command-name>/clear</command-name>'
        said 2026-09-29T06:08:00.000Z 'yes, go on'
        jq -cn '{type: "user", isMeta: true, timestamp: "2026-09-29T06:08:01.000Z", message: {role: "user", content: "meta"}}'
        call 2026-09-29T06:10:00.000Z r3 claude-sonnet-5 1 161000 100000 300
        jq -cn '{type: "system", subtype: "turn_duration", timestamp: "2026-09-29T06:09:00.000Z", pendingBackgroundAgentCount: 2}'
        jq -cn '{type: "system", subtype: "turn_duration", timestamp: "2026-09-29T06:14:24.529Z", pendingBackgroundAgentCount: 0}'
        cost 8.4512 '{"claude-sonnet-5": {"inputTokens": 5, "outputTokens": 600, "cacheReadInputTokens": 221000,
            "cacheCreationInputTokens": 27800000, "costUSD": 8.43},
            "claude-haiku-4-5-20251001": {"inputTokens": 10, "outputTokens": 90, "cacheReadInputTokens": 0,
            "cacheCreationInputTokens": 20000, "costUSD": 0.0212}}'
    } >"$dir/$sid.jsonl"
    {
        call 2026-09-29T06:03:10.000Z a1 claude-haiku-4-5-20251001 5 0 10000 40
        call 2026-09-29T06:03:20.000Z a2 claude-haiku-4-5-20251001 5 0 10000 50
    } >"$dir/$sid/subagents/agent-a1.jsonl"
}
supervisor() { # install the supervisor's transcript
    dir="$cfg/projects/-work-hub"
    mkdir -p "$dir"
    {
        call 2026-09-29T05:00:00.000Z s0 claude-opus-5-5 2 0 90000 100
        cost 1.00 '{}'
        call 2026-09-29T06:01:30.000Z s1 claude-opus-5-5 2 90000 1000 200
        cost 1.30 '{}'
        call 2026-09-29T06:15:20.000Z s2 claude-opus-5-5 2 91000 500 300
        cost 1.5412 '{}'
    } >"$dir/$sup.jsonl"
}
setup() {
    command rm -rf "$cfg/projects"
    job '.children = [{"id": "72", "href": "https://github.com/ChristopherA/mp-ported-skills/pull/72", "kind": "pr"}]'
    worker
    supervisor
}
record() { # [args...] -- record.sh's output for job c2a368ee in $repo
    PATH="$work/bin:$PATH" sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 \
        --supervisor "$sup" --now 2026-09-29T06:15:24Z "$@" </dev/null
}
field() { # <name> <record> -- that field's value
    printf '%s\n' "$2" | sed -n "s/^- $1: //p"
}

setup
out=$(record)
check "record: the whole record" "## Supervised run of #56

- worker: c2a368ee, claude-sonnet-5
- launched: 2026-09-29T06:01:24Z
- turn ended: 2026-09-29T06:14:24Z, 13 min after launch
- reported: 2026-09-29T06:15:24Z, 1 min after the turn ended
- API calls: 5, 3 by the worker and 2 by its subagents
- tokens and cost: claude-haiku-4-5-20251001 20k tokens \$0.02; claude-sonnet-5 28.0M tokens \$8.43; \$8.45 in all
- supervisor since launch: 2 API calls, 183k tokens, \$0.54
- peak zone: 174%, past 100% from worker call 2
- captures and clears: 1 capture, 1 clear, 1 compact
- human interventions: 1 wait on a human (approve Bash: git push), 1 message typed into the worker
- shared actions:
  - pr 72 ungranted: https://github.com/ChristopherA/mp-ported-skills/pull/72
  - branch origin/56-topic ungranted: holds the worker's commits
- outcome: 2 commits after $short, PR #72, ticket #56 CLOSED" "$out"

# The zone follows MP_SMART_ZONE_K, as the status line does.
check "record: the smart zone's size" "87%" \
    "$(field 'peak zone' "$( (export MP_SMART_ZONE_K=300; record) )")"

# The supervisor defaults to this session.
check "record: supervisor from the session id" "2 API calls, 183k tokens, \$0.54" \
    "$(field 'supervisor since launch' "$( (export CLAUDE_CODE_SESSION_ID="$sup";
        PATH="$work/bin:$PATH" sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" \
            --ticket 56 --now 2026-09-29T06:15:24Z </dev/null) )")"

# Hours past the turn end, as the #66 run's 4-hour timeout reported.
check "record: latency in hours" "2026-09-29T09:45:24Z, 3 h 31 min after the turn ended" \
    "$(field reported "$(record --now 2026-09-29T09:45:24Z)")"

# The launch prompt is not typed into the worker, whatever its form.
jq -c 'if .timestamp == "2026-09-29T06:01:25.000Z" then .message.content = "Live check. Reply OK." else . end' \
    "$cfg/projects/-work-project/$sid.jsonl" >"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
check "record: a plain launch prompt is not typed" "1 wait on a human (approve Bash: git push), 1 message typed into the worker" \
    "$(field 'human interventions' "$(record)")"

# A turn that ends within a minute.
check "record: under a minute" "2026-09-29T06:14:50Z, under a minute after the turn ended" \
    "$(field reported "$(record --now 2026-09-29T06:14:50Z)")"

# A run with nothing to count says none, not empty.
job
worker
jq -c 'select(.type != "system" and (.message.content | type) != "string"
        and ((.message.content // []) | map(.name) | index("Skill") | not))' \
    "$cfg/projects/-work-project/$sid.jsonl" >"$work/t" &&
    jq -cn '{type: "system", subtype: "turn_duration", timestamp: "2026-09-29T06:14:24.529Z"}' >>"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
printf '%s\n' '{"at":"2026-09-29T06:01:30.000Z","state":"working","detail":"","text":""}' >"$cfg/jobs/c2a368ee/timeline.jsonl"
out=$(record --start HEAD)
check "record: no captures" "none" "$(field 'captures and clears' "$out")"
check "record: no interventions" "none" "$(field 'human interventions' "$out")"
check "record: peak unchanged" "174%, past 100% from worker call 2" "$(field 'peak zone' "$out")"
check "record: no shared actions" "none" "$(field 'shared actions' "$out")"
check "record: no commits" "no commits after $(git -C "$repo" rev-parse --short HEAD), ticket #56 CLOSED" \
    "$(field outcome "$out")"

# A worker that stayed under the zone says so.
job
worker
jq -c 'select(.requestId != "r3")' "$cfg/projects/-work-project/$sid.jsonl" >"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
check "record: peak without the last call" "106%, past 100% from worker call 2" "$(field 'peak zone' "$(record)")"
jq -c 'select(.requestId != "r2")' "$cfg/projects/-work-project/$sid.jsonl" >"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
check "record: never past 100%" "40%" "$(field 'peak zone' "$(record)")"

# A source that cannot be read is named, never taken as zero.
setup
command rm -rf "$cfg/projects/-work-project"
out=$(record)
check "record: no worker transcript, calls unknown" "unknown" "$(field 'API calls' "$out")"
check "record: no worker transcript, zone unknown" "unknown" "$(field 'peak zone' "$out")"
check "record: no worker transcript, turn end unknown" "unknown" "$(field 'turn ended' "$out")"
check "record: no worker transcript, named" "- note: no transcript for session $sid under $cfg/projects, so its calls, cost, zone, captures and typed messages were not read" \
    "$(printf '%s\n' "$out" | grep '^- note: no transcript for session .*, so its calls')"

setup
command rm -rf "$cfg/projects/-work-hub"
out=$(record)
check "record: no supervisor transcript" "unknown" "$(field 'supervisor since launch' "$out")"
check "record: no supervisor transcript, named" "- note: no transcript for supervisor session $sup under $cfg/projects, so its share was not read" \
    "$(printf '%s\n' "$out" | grep '^- note: no transcript for supervisor')"
out=$(PATH="$work/bin:$PATH" sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 \
    --now 2026-09-29T06:15:24Z </dev/null)
check "record: no supervisor session, named" "- note: no supervisor session id (--supervisor or CLAUDE_CODE_SESSION_ID), so its share was not read" \
    "$(printf '%s\n' "$out" | grep '^- note: no supervisor')"

setup
command rm -f "$cfg/jobs/c2a368ee/timeline.jsonl"
out=$(record)
check "record: no timeline, waits unknown" "unknown waits, 1 message typed into the worker" "$(field 'human interventions' "$out")"
check "record: no timeline, named" "- note: no timeline for c2a368ee under $cfg/jobs, so its waits on a human were not read" \
    "$(printf '%s\n' "$out" | grep '^- note: no timeline')"

setup
out=$( (export FAKE_GH_FAIL=1; record) )
check "record: ticket state unread" "2 commits after $short, PR #72, ticket #56 state unknown" "$(field outcome "$out")"
check "record: ticket state unread, named" "- note: gh issue view 56 failed, so the ticket's state was not read" \
    "$(printf '%s\n' "$out" | grep '^- note: gh')"

setup
jq -c 'select(.type != "cost-state")' "$cfg/projects/-work-project/$sid.jsonl" >"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
out=$(record)
check "record: no cost-state row" "unknown" "$(field 'tokens and cost' "$out")"
check "record: no cost-state row, named" "- note: the transcript holds no cost-state row, so its tokens and cost were not read" \
    "$(printf '%s\n' "$out" | grep '^- note: the transcript')"

setup
command rm -rf "$cfg/jobs"
out=$(record)
check "record: no job, named" "- note: no job state for c2a368ee under $cfg/jobs, so the worker's model, launch, session, PRs and waits were not read" \
    "$(printf '%s\n' "$out" | grep '^- note: no job state .*, so the worker')"
check "record: no job, shared actions still listed" "  - branch origin/56-topic ungranted: holds the worker's commits" \
    "$(printf '%s\n' "$out" | grep '^  - branch')"

# --- recorded fixtures -----------------------------------------------------
# A live background job, cut down: tests/fixtures/jobs/1420c08b and its
# transcript, live-check-worker.jsonl.
command rm -rf "$cfg/jobs" "$cfg/projects"
mkdir -p "$cfg/jobs" "$cfg/projects/-work-project"
command cp -R "$root/tests/fixtures/jobs/1420c08b" "$cfg/jobs/"
command cp "$root/tests/fixtures/transcripts/live-check-worker.jsonl" \
    "$cfg/projects/-work-project/1420c08b-a2df-4dac-88a2-519854173c28.jsonl"
supervisor
out=$(PATH="$work/bin:$PATH" sh "$scripts/record.sh" --id 1420c08b --dir "$repo" --start HEAD --ticket 56 \
    --supervisor "$sup" --now 2026-09-30T05:47:26Z </dev/null)
check "record: a recorded job" "## Supervised run of #56

- worker: 1420c08b, claude-sonnet-5
- launched: 2026-09-30T05:46:16Z
- turn ended: 2026-09-30T05:46:26Z, under a minute after launch
- reported: 2026-09-30T05:47:26Z, 1 min after the turn ended
- API calls: 2, 2 by the worker and 0 by its subagents
- tokens and cost: claude-sonnet-5 147k tokens \$0.31; \$0.31 in all
- supervisor since launch: 0 API calls, 0 tokens, \$0.00
- peak zone: 49%
- captures and clears: none
- human interventions: none
- shared actions: none
- outcome: no commits after $(git -C "$repo" rev-parse --short HEAD), ticket #56 CLOSED" "$out"

# A hand-run /implement, cut down from a live interactive session with two
# subagents: hand-run.jsonl and hand-run/subagents/.
hand=0f3c2b1a-0000-4000-8000-000000000002
command rm -rf "$cfg/jobs" "$cfg/projects"
mkdir -p "$cfg/projects/-work-project"
command cp "$root/tests/fixtures/transcripts/hand-run.jsonl" "$cfg/projects/-work-project/$hand.jsonl"
command cp -R "$root/tests/fixtures/transcripts/hand-run" "$cfg/projects/-work-project/$hand"
out=$(PATH="$work/bin:$PATH" sh "$scripts/record.sh" --session "$hand" --dir "$repo" --start "$start" --ticket 56 </dev/null)
check "record: a hand run leaves out the job fields" "## Hand run of #56

- session: $hand, claude-opus-5-5
- started: 2026-09-25T20:07:49Z
- turn ended: 2026-09-25T20:52:06Z, 44 min after the start
- API calls: 55, 44 by the session and 11 by its subagents
- tokens and cost: claude-haiku-4-5-20251001 904 tokens \$0.00; claude-opus-5-5 4.2M tokens \$2.19; \$2.19 in all
- peak zone: 61%
- captures and clears: 1 capture, 1 clear
- human interventions: 5 messages typed into the session
- outcome: 2 commits after $short, ticket #56 CLOSED" "$out"

# The peak matches glance's reading of the same call: the status line
# records input plus cache read and written as the zone's tokens.
peak=$(jq -s '[.[] | select(.type == "assistant") | .message.usage
        | .input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens] | max' \
    "$root/tests/fixtures/transcripts/hand-run.jsonl")
mkdir -p "$work/ctx"
printf '{"session_id":"%s","project_dir":"%s","tokens":%s,"remaining_pct":50,"updated":"2026-09-25T20:52:06Z"}\n' \
    "$hand" "$repo" "$peak" >"$work/ctx/claude-$hand-zone.json"
glance=$( (export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx"
    sh "$root/plugins/mp-ported-skills/skills/glance/scripts/glance.sh" "$repo" "$hand" </dev/null) )
check "record: the peak matches glance" "$glance" "$(field 'peak zone' "$out") of zone"
glance=$( (export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx" MP_SMART_ZONE_K=40
    sh "$root/plugins/mp-ported-skills/skills/glance/scripts/glance.sh" "$repo" "$hand" </dev/null) )
check "record: the peak matches glance for another zone" "$glance" \
    "$(field 'peak zone' "$( (export MP_SMART_ZONE_K=40; PATH="$work/bin:$PATH" sh "$scripts/record.sh" \
        --session "$hand" --dir "$repo" --start "$start" --ticket 56 </dev/null) )" | sed 's/,.*//') of zone"

sh "$scripts/record.sh" --id c2a368ee --session "$hand" --dir "$repo" --start "$start" --ticket 56 </dev/null >/dev/null 2>&1
check "record: --id and --session are exclusive" "1" "$?"

# actions.sh failing makes the field unknown, never a list of its errors.
setup
mkdir -p "$work/scripts"
command cp "$scripts/record.sh" "$work/scripts/record.sh"
printf '#!/bin/sh\necho "branch origin/x ungranted: partial"\necho "Error: the shared-action hook is missing" >&2\nexit 1\n' \
    >"$work/scripts/actions.sh"
out=$(PATH="$work/bin:$PATH" sh "$work/scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 \
    --supervisor "$sup" --now 2026-09-29T06:15:24Z </dev/null)
check "record: actions.sh failed, unknown" "unknown" "$(field 'shared actions' "$out")"
check "record: actions.sh failed, named" "- note: actions.sh failed, so the shared actions were not read: Error: the shared-action hook is missing" \
    "$(printf '%s\n' "$out" | grep '^- note: actions')"
# Its stderr is never an action.
printf '#!/bin/sh\necho "warning: noise" >&2\necho none\n' >"$work/scripts/actions.sh"
out=$(PATH="$work/bin:$PATH" sh "$work/scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 \
    --supervisor "$sup" --now 2026-09-29T06:15:24Z </dev/null 2>/dev/null)
check "record: actions.sh stderr is not an action" "none" "$(field 'shared actions' "$out")"

# A worker that made no API calls has no zone reading, and says why.
setup
jq -c 'select(.type != "assistant")' "$cfg/projects/-work-project/$sid.jsonl" >"$work/t"
command mv "$work/t" "$cfg/projects/-work-project/$sid.jsonl"
out=$(record)
check "record: no calls, no zone" "none: no API calls" "$(field 'peak zone' "$out")"

setup
sh "$scripts/record.sh" --dir "$repo" --start "$start" --ticket 56 </dev/null >/dev/null 2>&1
check "record: --id is required" "1" "$?"
sh "$scripts/record.sh" --id c2a368ee --start "$start" --ticket 56 </dev/null >/dev/null 2>&1
check "record: --dir is required" "1" "$?"
sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --ticket 56 </dev/null >/dev/null 2>&1
check "record: --start is required" "1" "$?"
sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" </dev/null >/dev/null 2>&1
check "record: --ticket is required" "1" "$?"
sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 --now yesterday </dev/null >/dev/null 2>&1
check "record: a bad --now exits 1" "1" "$?"
( unset CLAUDE_CONFIG_DIR; sh "$scripts/record.sh" --id c2a368ee --dir "$repo" --start "$start" --ticket 56 </dev/null >/dev/null 2>&1 )
check "record: config dir required" "1" "$?"

echo "supervise-record: $pass passed, $fail failed"
[ "$fail" = 0 ]
