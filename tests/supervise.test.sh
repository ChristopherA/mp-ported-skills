#!/bin/sh
# supervise.test.sh -- tests for the supervise skill's step.sh, launch.sh and
# watch.sh.
#
# step.sh reads canned state.sh output. watch.sh reads the recorded
# `claude agents --json --all` fixtures in tests/fixtures/agents-json/, once
# with --file and in its polling loop through a fake `claude` on PATH that
# serves them in sequence, with a worker's transcript from
# tests/fixtures/transcripts/ installed under the config dir's projects/ where
# a test needs one. launch.sh runs against the same fake `claude`,
# which records its arguments, working directory and CLAUDE_CONFIG_DIR, and
# writes the job's state.json the daemon would. Touches nothing outside its
# own mktemp directory.
#
# Usage: sh tests/supervise.test.sh

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
unset MP_SUPERVISE_WAIT MP_RESUME_BUDGET CLAUDE_PROJECT_DIR FAKE_AGENTS_FAIL FAKE_BG_OUT FAKE_NO_STATE FAKE_STATE_FILTER
cfg="$work/config"
mkdir -p "$cfg/plugins/cache/mkt/mattpocock-skills/1.2.3/skills/engineering/implement"
touch "$cfg/plugins/cache/mkt/mattpocock-skills/1.2.3/skills/engineering/implement/SKILL.md"
export CLAUDE_CONFIG_DIR="$cfg"

# --- step.sh ---------------------------------------------------------------
step() { # <next: line> -- step.sh's output for a state.sh report ending in it
    printf 'branch: main\n%s\nrunner-up: 7 nothing else in motion\n' "$1" >"$work/state.txt"
    sh "$scripts/step.sh" --from "$work/state.txt" </dev/null
}
you="you type it; user-invoked"

check "step: case 2 ready ticket" "implement #52" \
    "$(step "next: 2 /implement #52 ($you): #52 t52")"
check "step: in-motion parent's ready-for-agent child" "implement #28" \
    "$(step "next: 1 work in flight: in motion #24 t24; next child #28 (ready-for-agent, /implement #28, $you): t28")"
check "step: child under a custom agent label" "implement #28" \
    "$(step "next: 1 work in flight: in motion #24 t24; next child #28 (agent-ok, /implement #28, $you): t28")"
line="next: 1 work in flight: 2 uncommitted paths, in motion #24 t24; next child #28 (ready-for-agent, /implement #28, $you): t28"
check "step: git work in flight comes first" "stop: $line" "$(step "$line")"
line="next: 1 work in flight: on topic not main"
check "step: another branch" "stop: $line" "$(step "$line")"
line="next: 1 work in flight: in motion #24 t24; next child #26 (ready-for-human, by hand): t26"
check "step: hand child" "stop: $line" "$(step "$line")"
line="next: 1 work in flight: in motion #24 t24; every open child blocked: #27 by #26"
check "step: every child blocked" "stop: $line" "$(step "$line")"
line="next: 3 /triage ($you): 1 unlabelled, 0 needs-triage, replied needs-info: none"
check "step: triage" "stop: $line" "$(step "$line")"
line="next: 6 by hand: #30 t30"
check "step: hand work" "stop: $line" "$(step "$line")"
line="next: none known: the tracker was not read"
check "step: tracker unread" "stop: $line" "$(step "$line")"
printf 'git: not a repository\n' >"$work/state.txt"
check "step: no next: line" "stop: state.sh printed no next: line" \
    "$(sh "$scripts/step.sh" --from "$work/state.txt" </dev/null)"
mkdir -p "$work/not-a-repo"
check "step: runs resuming's state.sh in the folder" "stop: next: 7 nothing in motion" \
    "$(sh "$scripts/step.sh" "$work/not-a-repo" </dev/null)"
sh "$scripts/step.sh" "$work/missing" </dev/null >/dev/null 2>&1
check "step: missing folder exits 1" "1" "$?"

# --- watch.sh --file ------------------------------------------------------
watch_file() { # <fixture> <id>
    sh "$scripts/watch.sh" --id "$2" --file "$fixtures/$1.json" </dev/null
}
check "watch: idle but still working" "working
cwd /work/project" "$(watch_file working-idle 9121ff49)"
check "watch: busy" "working
cwd /work/project" "$(watch_file working-busy c2a368ee)"
check "watch: done" "done
cwd /work/project" "$(watch_file done 9121ff49)"
check "watch: permission prompt" "blocked permission prompt
cwd /work/project" "$(watch_file blocked-permission-prompt 91a06a74)"
check "watch: SessionStart question" "blocked input needed
cwd /work/project" "$(watch_file blocked-input-needed c2a368ee)"
check "watch: stopped" "stopped
cwd /work/project" "$(watch_file stopped c2a368ee)"
check "watch: removed session is gone" "gone" "$(watch_file done c2a368ee)"
check "watch: interactive sessions never match" "gone" "$(watch_file done null)"
jq '[.[] | if .kind == "background" then .state = "crashed" else . end]' "$fixtures/done.json" >"$work/odd.json"
check "watch: an unknown state is reported" "unknown crashed
cwd /work/project" "$(sh "$scripts/watch.sh" --id 9121ff49 --file "$work/odd.json" </dev/null)"

# The job's own state.json names what a blocked session waits for.
mkdir -p "$cfg/jobs/91a06a74"
jq '.needs = "approve Bash: git push origin main"' "$fixtures/job-state.json" >"$cfg/jobs/91a06a74/state.json"
check "watch: blocked adds the job's needs" "blocked permission prompt
cwd /work/project
needs approve Bash: git push origin main" "$(watch_file blocked-permission-prompt 91a06a74)"
command rm -rf "$cfg/jobs/91a06a74"

printf 'not json\n' >"$work/bad.json"
sh "$scripts/watch.sh" --id c2a368ee --file "$work/bad.json" </dev/null >"$work/out" 2>/dev/null
rc=$?
check "watch: unreadable list exits 1" "1" "$rc"
check "watch: unreadable list is not gone" "" "$(command cat "$work/out")"
sh "$scripts/watch.sh" --file "$fixtures/done.json" </dev/null >/dev/null 2>&1
check "watch: --id is required" "1" "$?"
sh "$scripts/watch.sh" --id c2a368ee --interval 5s </dev/null >/dev/null 2>&1
check "watch: --interval must be a number" "1" "$?"
sh "$scripts/watch.sh" --id c2a368ee --timeout 1h </dev/null >/dev/null 2>&1
check "watch: --timeout must be a number" "1" "$?"
( unset CLAUDE_CONFIG_DIR; sh "$scripts/watch.sh" --id 9121ff49 --file "$fixtures/done.json" </dev/null >/dev/null 2>&1 )
check "watch: config dir required" "1" "$?"
jq '[.[] | if .kind == "background" then del(.cwd) else . end]' "$fixtures/done.json" >"$work/nocwd.json"
check "watch: no cwd line without a cwd" "done" "$(sh "$scripts/watch.sh" --id 9121ff49 --file "$work/nocwd.json" </dev/null)"

# The state list can go on saying working after the turn ended. The worker's
# transcript, found by session id in any project folder, says it ended.
transcript() { # <fixture> [folder] [session id] -- install it as a worker's transcript
    dir="$cfg/projects/${2:--work-project}"
    command rm -rf "$cfg/projects"
    mkdir -p "$dir"
    command cp "$transcripts/$1.jsonl" "$dir/${3:-9121ff49-5e25-43f0-bf48-307db0776c36}.jsonl"
}
transcript turn-ended
check "watch: turn ended while the list says working" "done
cwd /work/project
note claude agents still said working" "$(watch_file working-idle 9121ff49)"
# A turn can end while the worker waits on background agents; their reports
# start the next turn.
transcript waiting-on-agents
check "watch: turn ended with agents pending is working" "working
cwd /work/project" "$(watch_file working-idle 9121ff49)"
transcript just-launched
check "watch: just launched, prompt only, is working" "working
cwd /work/project" "$(watch_file working-idle 9121ff49)"
transcript mid-turn
check "watch: transcript ending in a tool call is working" "working
cwd /work/project" "$(watch_file working-idle 9121ff49)"
command rm -rf "$cfg/projects"
check "watch: no transcript is working" "working
cwd /work/project" "$(watch_file working-idle 9121ff49)"
# A worker that entered a worktree has its transcript in the worktree's folder.
transcript turn-ended -work-project--claude-worktrees-issue-66
check "watch: transcript found in a worktree's folder" "done
cwd /work/project
note claude agents still said working" "$(watch_file working-idle 9121ff49)"
# status busy means mid-turn, whatever the transcript says.
transcript turn-ended -work-project c2a368ee-c513-484c-83d3-581830e209a5
check "watch: busy is working whatever the transcript says" "working
cwd /work/project" "$(watch_file working-busy c2a368ee)"
command rm -rf "$cfg/projects"

# --- fake claude -----------------------------------------------------------
fake="$work/fake"
mkdir -p "$work/bin" "$fake"
cat >"$work/bin/claude" <<'EOF'
#!/bin/sh
fake="$FAKE_DIR"
case "$1" in
    agents)
        n=$(command cat "$fake/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$fake/count"
        [ -n "${FAKE_AGENTS_FAIL:-}" ] && { echo "daemon unreachable" >&2; exit 1; }
        f=$(sed -n "${n}p" "$fake/seq"); [ -n "$f" ] || f=$(tail -n 1 "$fake/seq")
        command cat "$f" ;;
    stop) echo "stop $2" >>"$fake/calls"; echo "stopped $2" ;;
    --bg)
        printf '%s\n' "$@" >"$fake/args"; pwd -P >"$fake/cwd"
        echo "${CLAUDE_CONFIG_DIR-unset}" >"$fake/env"
        if [ -n "${FAKE_BG_OUT+x}" ]; then printf '%s\n' "$FAKE_BG_OUT"; exit 0; fi
        echo "Starting background service…"; echo "backgrounded · c2a368ee"
        if [ -z "${FAKE_NO_STATE:-}" ]; then
            mkdir -p "$CLAUDE_CONFIG_DIR/jobs/c2a368ee"
            jq --arg cfg "$CLAUDE_CONFIG_DIR" --arg cwd "$(pwd -P)" \
                ".cwd = \$cwd | .providerEnv.CLAUDE_CONFIG_DIR = \$cfg ${FAKE_STATE_FILTER:-}" \
                "$FAKE_JOB" >"$CLAUDE_CONFIG_DIR/jobs/c2a368ee/state.json"
        fi ;;
    *) echo "fake claude: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/claude"
# A fake that is not found first would send these launches to the real
# claude, so stop before any of them runs.
if [ "$(PATH="$work/bin:$PATH" command -v claude)" != "$work/bin/claude" ]; then
    echo "FAIL fake claude is not first on PATH; not running the rest" >&2
    exit 1
fi
export FAKE_DIR="$fake" FAKE_JOB="$fixtures/job-state.json"
reset_fake() { command rm -rf "$fake" "$cfg/jobs"; mkdir -p "$fake"; }

# --- watch.sh polling -----------------------------------------------------
poll() { # <id> <fixture>... -- watch.sh's output over that sequence
    id=$1; shift
    reset_fake
    for f in "$@"; do echo "$fixtures/$f.json"; done >"$fake/seq"
    PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id "$id" --interval 0 --timeout 30 </dev/null
}
check "poll: working until done" "done
cwd /work/project" "$(poll 9121ff49 working-idle working-idle done)"
check "poll: read the list each round" "3" "$(command cat "$fake/count")"
check "poll: working until blocked" "blocked input needed
cwd /work/project" "$(poll c2a368ee working-busy blocked-input-needed)"
check "poll: stops at stopped" "stopped
cwd /work/project" "$(poll c2a368ee working-busy stopped)"
transcript turn-ended
check "poll: stops when the transcript says the turn ended" "done
cwd /work/project
note claude agents still said working" "$(poll 9121ff49 working-idle working-idle)"
check "poll: stopped at the first such round" "1" "$(command cat "$fake/count")"
command rm -rf "$cfg/projects"

reset_fake
echo "$fixtures/working-busy.json" >"$fake/seq"
out=$(PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id c2a368ee --interval 1 --timeout 1 </dev/null)
rc=$?
check "poll: timeout exits 124" "124" "$rc"
check "poll: timeout prints the last state" "working
cwd /work/project" "$out"

reset_fake
echo "$fixtures/done.json" >"$fake/seq"
out=$( (export FAKE_AGENTS_FAIL=1; PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id 9121ff49 --interval 0 --timeout 5 </dev/null 2>/dev/null) )
rc=$?
check "poll: failing agents command exits 1" "1" "$rc"
check "poll: failing agents command is not gone" "" "$out"

# --- launch.sh -------------------------------------------------------------
project="$work/project"
mkdir -p "$project"
launch() { # [args...] -- launch.sh --dir $project with the fake claude
    reset_fake
    PATH="$work/bin:$PATH" sh "$scripts/launch.sh" --dir "$project" "$@" </dev/null
}
out=$(launch --ticket 56 2>&1)
rc=$?
check "launch: exit 0" "0" "$rc"
check "launch: prints the id" "c2a368ee" "$out"
check "launch: flags and the command" "--bg
--model
claude-sonnet-5
--permission-mode
auto
/mattpocock-skills:implement #56" "$(command cat "$fake/args")"
check "launch: runs in the project folder" "$project" "$(command cat "$fake/cwd")"
check "launch: sets the config dir" "$cfg" "$(command cat "$fake/env")"
check "launch: stops nothing" "" "$(command cat "$fake/calls" 2>/dev/null)"

launch --ticket 56 --model claude-opus-5-5 >/dev/null 2>&1
check "launch: --model passes through" "claude-opus-5-5" "$(sed -n 3p "$fake/args")"

out=$(launch --ticket 56 --model claude-haiku-4-5-20251001 2>&1)
rc=$?
check "launch: haiku refused" "1" "$rc"
check "launch: haiku never launched" "no" "$([ -f "$fake/args" ] && echo yes || echo no)"

launch --ticket abc >/dev/null 2>&1
check "launch: ticket must be a number" "1" "$?"
launch >/dev/null 2>&1
check "launch: ticket required" "1" "$?"
( unset CLAUDE_CONFIG_DIR; launch --ticket 56 >/dev/null 2>&1 )
check "launch: config dir required" "1" "$?"
check "launch: no config dir, never launched" "no" "$([ -f "$fake/args" ] && echo yes || echo no)"

command mv "$cfg/plugins" "$cfg/plugins.off"
out=$(launch --ticket 56 2>&1)
rc=$?
command mv "$cfg/plugins.off" "$cfg/plugins"
check "launch: implement not installed exits 1" "1" "$rc"
check "launch: names the missing skill" "Error: mattpocock-skills:implement is not installed under $cfg/plugins/cache; install mattpocock-skills first" "$out"

out=$( (export FAKE_BG_OUT="Error: something broke"; launch --ticket 56 2>&1) )
rc=$?
check "launch: no id exits 1" "1" "$rc"
check "launch: no id shows claude's output" "Error: claude --bg printed no session id:
Error: something broke" "$out"

# Each launch-time check stops the session and exits 2.
mismatch() { # <name> <jq filter> <expected message>
    out=$( (export FAKE_STATE_FILTER="$2"; launch --ticket 56 2>&1) )
    rc=$?
    check "launch: $1 exits 2" "2" "$rc"
    check "launch: $1 stops the session" "stop c2a368ee" "$(command cat "$fake/calls" 2>/dev/null)"
    check "launch: $1 says why" "$3" "$out"
}
mismatch "wrong permission mode" '| .respawnFlags = ["--permission-mode", "default", "--model", "claude-sonnet-5"]' \
    "Error: session c2a368ee is not in auto mode (its flags: --permission-mode default --model claude-sonnet-5); stopped it"
mismatch "wrong profile" '| .providerEnv.CLAUDE_CONFIG_DIR = "/elsewhere"' \
    "Error: session c2a368ee runs under config /elsewhere, not $cfg; stopped it"
mismatch "no profile recorded" '| del(.providerEnv)' \
    "Error: session c2a368ee runs under config (none recorded), not $cfg; stopped it"
mismatch "another folder" '| .cwd = "/elsewhere"' \
    "Error: session c2a368ee runs in /elsewhere, not $project; stopped it"
mismatch "a worktree" '| .worktreePath = "/w/.claude/worktrees/x"' \
    "Error: session c2a368ee was placed in worktree /w/.claude/worktrees/x, not $project; stopped it"

out=$( (export FAKE_NO_STATE=1 MP_SUPERVISE_WAIT=1; launch --ticket 56 2>&1) )
rc=$?
check "launch: no job state exits 2" "2" "$rc"
check "launch: no job state stops the session" "stop c2a368ee" "$(command cat "$fake/calls" 2>/dev/null)"
check "launch: no job state says why" "Error: no job state for session c2a368ee under $cfg/jobs after 1s, so its profile is unconfirmed; stopped it" "$out"

echo "supervise: $pass passed, $fail failed"
[ "$fail" = 0 ]
