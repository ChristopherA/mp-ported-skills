#!/bin/sh
# supervise-finish.test.sh -- tests for the supervise skill's finish.sh.
#
# Runs finish.sh over the real stop.sh, actions.sh, glance.sh and record.sh,
# against a scratch Project with a bare remote, a job's state.json, a
# worker's transcript, and a fake `claude` and `gh` first on PATH. The fake
# `claude` logs each call and answers `agents --json --all` with the list
# FAKE_AGENTS names. The fake `gh` answers record.sh's state read and the
# record's post, and refuses a missing or empty body file with exit 1, as
# the real gh does. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-finish.test.sh

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
unset MP_SMART_ZONE_K CLAUDE_CODE_SESSION_ID FAKE_AGENTS FAKE_GH_FAIL FAKE_GH_NOURL WORKSTREAM_KIT_CONTEXT_DIR CLAUDE_CODE_SESSION_ATTENDED TMUX MP_SESSION_TITLE
cfg="$work/config"
mkdir -p "$cfg"
export CLAUDE_CONFIG_DIR="$cfg"
export MP_RECORD_COST_WAIT=0

# --- fake claude and gh ----------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/claude-calls"
case "\$*" in
    "agents --json --all") command cat "\$FAKE_AGENTS" ;;
    stop\ *) ;;
    *) echo "fake claude: unexpected \$*" >&2; exit 1 ;;
esac
EOF
cat >"$work/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "issue view") echo OPEN; exit 0 ;;
    "issue comment") ;;
    *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
[ -n "\${FAKE_GH_FAIL:-}" ] && { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
[ -n "\${FAKE_GH_NOURL:-}" ] && exit 0
[ "\$4" = --body-file ] || { echo "fake gh: unexpected \$*" >&2; exit 1; }
[ -f "\$5" ] || { echo "open \$5: no such file or directory" >&2; exit 1; }
[ -s "\$5" ] || { echo "Body cannot be blank" >&2; exit 1; }
printf '%s %s\n' "\$PWD" "\$*" >>"$work/gh-posts"
echo "https://github.com/o/r/issues/\$3#issuecomment-1"
EOF
chmod +x "$work/bin/claude" "$work/bin/gh"
export PATH="$work/bin:$PATH"
if [ "$(command -v claude)" != "$work/bin/claude" ] || [ "$(command -v gh)" != "$work/bin/gh" ]; then
    echo "FAIL fake claude or gh is not first on PATH; not running the rest" >&2
    exit 1
fi

# --- the Project -----------------------------------------------------------
repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}
# project <name> <grant line or ''>: a Project whose origin holds the grant,
# and a worker commit pushed to origin/main.
project() {
    p="$work/$1"
    git init -q --bare "$p.git"
    git init -q -b main "$p"
    mkdir -p "$p/docs/agents"
    printf '# Supervision\n\n## Grants\n\n%s\n' "$2" >"$p/docs/agents/supervision.md"
    repo_git "$p" add docs
    repo_git "$p" commit -q -m start
    repo_git "$p" remote add origin "$p.git"
    repo_git "$p" push -q origin main 2>/dev/null
    git -C "$p" remote set-head origin main
    repo_git "$p" commit -q --allow-empty -m "worker's commit"
    repo_git "$p" push -q origin main 2>/dev/null
}
project granted '- push: to main'
project ungranted ''
start_of() { git -C "$work/$1" rev-parse HEAD~1; }

# --- the worker ------------------------------------------------------------
sid=c2a368ee-c513-484c-83d3-581830e209a5
mkdir -p "$cfg/projects/-work-project"
{
    jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t1", name: "Bash", input: {command: "git push origin main"}}]}}'
    jq -cn '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", is_error: false, content: "ok"}]}}'
} >"$cfg/projects/-work-project/$sid.jsonl"
worker() { # <project> -- the job, live in that Project, with its marker
    command rm -rf "$cfg/jobs" "$work/claude-calls" "$work/gh-posts" "$work/out"
    mkdir -p "$cfg/jobs/c2a368ee" "$work/out"
    jq --arg d "$work/$1" '.cwd = $d' "$fixtures/job-state.json" >"$cfg/jobs/c2a368ee/state.json"
    git -C "$work/$1" rev-parse --git-path mp-supervise-worker >/dev/null
    echo c2a368ee >"$(git -C "$work/$1" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
}
finish() { # <project> [finish.sh options...]
    p=$1; shift
    sh "$scripts/finish.sh" --dir "$work/$p" --id c2a368ee --start "$(start_of "$p")" --ticket 56 \
        --record "$work/out/run-record-56.md" --session "$sid" --session-dir "$work" \
        --settle 0 --interval 0 "$@" </dev/null
}
glance="No reading: this profile has no status line. /setup-mp-ported-skills turns one on."
marker_of() { git -C "$work/$1" rev-parse --path-format=absolute --git-path mp-supervise-worker; }

# --- a clean run -----------------------------------------------------------
worker granted
export FAKE_AGENTS="$fixtures/stopped.json"
out=$(finish granted 2>&1); rc=$?
check "finish: clean exits 0" "0" "$rc"
check "finish: clean prints one line, then the detail file" "clean https://github.com/o/r/issues/56#issuecomment-1; shared actions: 2, listed in the record; glance: $glance
detail $work/out/finish-c2a368ee.txt" "$out"
check "finish: stops the worker" "stop c2a368ee" "$(grep '^stop' "$work/claude-calls")"
check "finish: releases the marker" "no" "$([ -f "$(marker_of granted)" ] && echo yes || echo no)"
check "finish: posts the record from the Project folder" "$work/granted issue comment 56 --body-file $work/out/run-record-56.md" \
    "$(command cat "$work/gh-posts")"
check "finish: writes the record where it was told" "1" \
    "$(grep -cFx -- "- worker: c2a368ee, claude-sonnet-5" "$work/out/run-record-56.md")"
check "finish: the record lists the granted push" "1" \
    "$(grep -c 'command succeeded granted (push: to main): git push origin main' "$work/out/run-record-56.md")"
d="$work/out/finish-c2a368ee.txt"
for part in "stopped c2a368ee" "released c2a368ee" "branch origin/main granted (push: to main): holds the worker's commits" "$glance" "https://github.com/o/r/issues/56#issuecomment-1"; do
    check "finish: the detail file holds: $part" "1" "$(grep -cFx -- "$part" "$d")"
done

out=$(finish granted --detail "$work/out/elsewhere.txt" 2>&1)
check "finish: --detail names the file" "detail $work/out/elsewhere.txt" "$(printf '%s\n' "$out" | tail -n 1)"

# --- an ungranted action ---------------------------------------------------
worker ungranted
out=$(finish ungranted 2>&1); rc=$?
check "finish: ungranted exits 0" "0" "$rc"
check "finish: ungranted prints each one, then the record and the glance" "branch origin/main ungranted: holds the worker's commits
command succeeded ungranted: git push origin main
record https://github.com/o/r/issues/56#issuecomment-1
shared actions: 2, listed in the record
glance: $glance
detail $work/out/finish-c2a368ee.txt" "$out"

# --- a record that does not post -------------------------------------------
worker granted
out=$( (export FAKE_GH_FAIL=1; finish granted 2>&1) ); rc=$?
check "finish: a failed post exits 0" "0" "$rc"
check "finish: a failed post says so, and where the record is" "post failed: gh: HTTP 404: Not Found; the record is in $work/out/run-record-56.md
shared actions: 2, listed in the record
glance: $glance
detail $work/out/finish-c2a368ee.txt" "$out"

# A post that prints no URL is not clean.
worker granted
out=$( (export FAKE_GH_NOURL=1; finish granted 2>&1) )
check "finish: a post with no URL says so" "post printed no URL; the record is in $work/out/run-record-56.md" \
    "$(printf '%s\n' "$out" | head -n 1)"

# Relative record and detail paths still name the files the post and the
# detail file use, though the post runs in the Project folder.
worker granted
out=$( (cd "$work" && sh "$scripts/finish.sh" --dir "$work/granted" --id c2a368ee --start "$(start_of granted)" \
    --ticket 56 --record out/rel.md --session "$sid" --session-dir "$work" --settle 0 --interval 0 </dev/null 2>&1) )
check "finish: a relative record posts" "$work/granted issue comment 56 --body-file $work/out/rel.md" \
    "$(command cat "$work/gh-posts" 2>/dev/null)"
check "finish: a relative record keeps the detail file beside it" "detail $work/out/finish-c2a368ee.txt" \
    "$(printf '%s\n' "$out" | tail -n 1)"
check "finish: no detail file in the Project folder" "no" "$([ -e "$work/granted/out" ] && echo yes || echo no)"

# --- a stop that fails -----------------------------------------------------
# The worker never shows stopped: the record waits on the stop, since the
# worker's cost is written then, so nothing after it runs.
worker granted
jq '[.[] | if .kind == "background" then .state = "working" | .pid = 1 else . end]' \
    "$fixtures/stopped.json" >"$work/live.json"
out=$( (export FAKE_AGENTS="$work/live.json"; finish granted --timeout 0 2>&1) ); rc=$?
check "finish: a failed stop exits 1" "1" "$rc"
check "finish: a failed stop says so, with the command to finish" "stop failed: session c2a368ee was not stopped 0s after claude stop
marker kept: $work/granted is still read-only for commits, held by c2a368ee
finish with: sh \"$scripts/stop.sh\" --dir \"$work/granted\" --id c2a368ee
detail $work/out/finish-c2a368ee.txt" "$out"
check "finish: a failed stop writes no record" "no" "$([ -f "$work/out/run-record-56.md" ] && echo yes || echo no)"
check "finish: a failed stop posts nothing" "no" "$([ -f "$work/gh-posts" ] && echo yes || echo no)"
check "finish: a failed stop keeps the marker" "c2a368ee" "$(command cat "$(marker_of granted)")"

# A refused check stops nothing and has no finish-with line.
worker granted
echo 7a6a0741 >"$(marker_of granted)"
out=$(finish granted 2>&1); rc=$?
check "finish: another worker's marker exits 1" "1" "$rc"
check "finish: another worker's marker says so" "stop failed: the marker in $work/granted names worker 7a6a0741, not c2a368ee; not stopped
detail $work/out/finish-c2a368ee.txt" "$out"
check "finish: another worker's marker, nothing stopped" "" "$(grep '^stop' "$work/claude-calls" 2>/dev/null)"

# --- arguments -------------------------------------------------------------
worker granted
for bad in --dir --id --start --ticket --record; do
    # Each required option left out in turn.
    set -- --dir "$work/granted" --id c2a368ee --start "$(start_of granted)" --ticket 56 --record "$work/out/r.md"
    args=""
    while [ $# -gt 0 ]; do
        [ "$1" = "$bad" ] || args="$args $1 $2"
        shift 2
    done
    # shellcheck disable=SC2086
    sh "$scripts/finish.sh" $args </dev/null >/dev/null 2>&1
    check "finish: refuses without $bad" "1" "$?"
done
check "finish: refusals stopped nothing" "" "$(grep '^stop' "$work/claude-calls" 2>/dev/null)"
sh "$scripts/finish.sh" --dir "$work/granted" --id c2a368ee --start x --ticket 56 --record "$work/out/r.md" --tmux --pane '1 2 3' </dev/null >/dev/null 2>&1
check "finish: --tmux and --pane are exclusive" "1" "$?"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
