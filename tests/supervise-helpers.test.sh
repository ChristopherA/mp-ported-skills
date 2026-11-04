#!/bin/sh
# supervise-helpers.test.sh -- tests for the supervise skill's shared
# helpers: agents.sh (claude agents within a time limit) (#240),
# marker.sh (the checkout's worker marker), settle.sh (stop a
# worker and wait until it has settled) (#137), live.sh (which background
# sessions are live in a checkout), accept.sh (which next: step /supervise
# takes) (#115), park.sh (how a parked ticket and worker are told apart)
# (#158), transcript.sh (where a session's transcripts are) (#172),
# own-repo.sh (whether a path is a repo of its own) (#167) and
# distribution-repo.sh (a Distribution repo's path checks and state) (#209).
#
# Sources each helper and runs its function against a scratch repo and a
# fake `claude` first on PATH. The fake logs each call and answers
# `agents --json --all` with the next of the lists agents.1, agents.2, ...
# in its folder, staying on the last, and fails when FAKE_AGENTS_FAIL is
# set. With FAKE_AGENTS_HANG=N, its first N such calls print part of a
# list, ignore TERM, ALRM, HUP and INT, and sleep for 601 seconds. With each list N it writes roster.N, when there is one, as the
# daemon's roster file, so the roster changes with the list. Touches
# nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-helpers.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
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

unset FAKE_AGENTS_FAIL FAKE_AGENTS_HANG MP_AGENTS_TIMEOUT CLAUDE_CODE_SESSION_ATTENDED MP_SESSION_TITLE

# --- fake claude -----------------------------------------------------------
mkdir -p "$work/bin" "$work/lists"
cat >"$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/claude-calls"
case "\$*" in
    "agents --json --all")
        [ -z "\${FAKE_AGENTS_FAIL:-}" ] || exit 1
        if [ -n "\${FAKE_AGENTS_HANG:-}" ]; then
            h=\$(command cat "$work/hangs" 2>/dev/null || echo 0)
            if [ "\$h" -lt "\$FAKE_AGENTS_HANG" ]; then
                echo \$((h + 1)) >"$work/hangs"
                trap '' TERM ALRM HUP INT
                printf '[{"partial'
                sleep 601
            fi
        fi
        n=\$(command cat "$work/count" 2>/dev/null || echo 0)
        n=\$((n + 1))
        [ -f "$work/lists/agents.\$n" ] || n=\$((n - 1))
        echo "\$n" >"$work/count"
        [ ! -f "$work/lists/roster.\$n" ] || command cp -f "$work/lists/roster.\$n" "$work/roster.json"
        command cat "$work/lists/agents.\$n" ;;
    stop\ *) ;;
    *) echo "fake claude: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/claude"
PATH="$work/bin:$PATH"
[ "$(command -v claude)" = "$work/bin/claude" ] || {
    echo "FAIL the fake claude is not the one found; not running the rest"
    exit 1
}

# lists <json>...: the lists the fake answers, in order.
lists() {
    command rm -f "$work"/lists/agents.* "$work"/lists/roster.* "$work/roster.json" "$work/count" "$work/claude-calls" "$work/hangs"
    i=0
    for l in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$l" >"$work/lists/agents.$i"
    done
}
# rosters <json>...: the roster files written with lists 1, 2, ..., in order.
rosters() {
    i=0
    for r in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$r" >"$work/lists/roster.$i"
    done
}
held='{"workers":{"c2a368ee":{"pid":202}}}'
freed='{"workers":{"0ca7d123":{"pid":303}}}'
row() { printf '[{"kind":"background","id":"c2a368ee","state":"%s","pid":%s}]' "$1" "$2"; }

# --- agents.sh -------------------------------------------------------------
. "$scripts/agents.sh"

check "agents limit: unset reads as 60" "60" "$(unset MP_AGENTS_TIMEOUT; agents_limit)"
check "agents limit: a whole number is kept" "5" "$(export MP_AGENTS_TIMEOUT=5; agents_limit)"
for bad in abc 0 05 -3 1.5; do
    check "agents limit: '$bad' reads as 60" "60" "$(export MP_AGENTS_TIMEOUT=$bad; agents_limit)"
done
lists '[{"id":"a1"}]'
out=$(agents_list); rc=$?
check "agents list: an answer is printed" '[{"id":"a1"}]' "$out"
check "agents list: an answer returns 0" "0" "$rc"
out=$( (export FAKE_AGENTS_FAIL=1; agents_list) ); rc=$?
check "agents list: a failed call returns its status" "1" "$rc"
# Inside a background job, as state.sh's gather runs it, a failed call
# still returns its status: `command cat` there once ended the function
# with cat's 0.
# The bug needs a function as the background job, as gather is.
bg_read() { x=$(agents_list 2>/dev/null); echo $? >"$work/bg-rc"; }
FAKE_AGENTS_FAIL=1; export FAKE_AGENTS_FAIL
bg_read &
wait $!
unset FAKE_AGENTS_FAIL
check "agents list: a failed call in a background job returns its status" "1" "$(command cat "$work/bg-rc")"
# A call that hangs and ignores every signal but KILL is ended at the
# limit. Timed through a 2>&1 capture, so a process left holding the pipe
# would show as a long wait.
lists '[{"id":"a1"}]'
t0=$(date +%s)
out=$( (export FAKE_AGENTS_HANG=1 MP_AGENTS_TIMEOUT=1; agents_list 2>&1; echo "rc=$?") )
t1=$(date +%s)
check "agents list: a hung call returns 124 and prints nothing" "rc=124" "$out"
check "agents list: a hung call ends within the limit and a second" "yes" "$( [ $((t1 - t0)) -le 2 ] && echo yes || echo "no, $((t1 - t0))s")"
check "agents list: nothing of the hung call is left running" "0" "$(ps -axo command= | grep -c '^sleep 601$')"
# Stopping the reader (a TERM to the perl parent, as a stopped watch sends)
# ends the hung call too: it runs in a process group of its own, which a
# signal to the caller's group does not reach.
lists '[{"id":"a1"}]'
(export FAKE_AGENTS_HANG=1 MP_AGENTS_TIMEOUT=30; agents_list >/dev/null 2>&1) &
reader=$!
i=0
while [ "$i" -lt 50 ] && [ "$(ps -axo command= | grep -c '^sleep 601$')" -eq 0 ]; do sleep 0.1; i=$((i + 1)); done
pkill -TERM -P "$reader" perl
wait "$reader"
sleep 1
check "agents list: a TERM to the reader ends the hung call" "0" "$(ps -axo command= | grep -c '^sleep 601$')"
pkill -9 -f '^sleep 601$' 2>/dev/null
out=$( (export FAKE_AGENTS_HANG=1 MP_AGENTS_TIMEOUT=1; agents_list >/dev/null; agents_list) )
check "agents list: the call after a hung one answers" '[{"id":"a1"}]' "$out"
# Every script reads the list through agents_list: a call of its own has
# no time limit.
raw=$(grep -rnE --include='*.sh' '(^|[;&|(])[[:space:]]*([A-Za-z_]+=[^[:space:]]+[[:space:]]+)*(command[[:space:]]+)?claude[[:space:]]+agents' "$root/plugins" | grep -v '^[^:]*/agents\.sh:' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
check "agents list: no script calls claude agents on its own" "" "$raw"

# --- marker.sh -------------------------------------------------------------
. "$scripts/marker.sh"

git init -q "$work/repo"
repo=$(CDPATH= cd -- "$work/repo" && pwd -P)
check "marker_path names the checkout's git dir" "$repo/.git/mp-supervise-worker" "$(marker_path "$repo")"
mkdir "$work/repo/sub"
check "marker_path from a folder inside the checkout" "$repo/.git/mp-supervise-worker" "$(marker_path "$repo/sub")"
mkdir "$work/plain"
out=$(marker_path "$work/plain" 2>/dev/null); rc=$?
check "marker_path outside a checkout fails" "1 " "$([ "$rc" -ne 0 ] && echo 1) $out"
err=$(marker_path "$work/plain" 2>&1 >/dev/null)
check "marker_path leaves git's error on stderr for the caller" "yes" "$([ -n "$err" ] && echo yes)"
printf 'c2a368ee\ndistribution /d\n' >"$work/m1"
printf 'c2a368ee\ndistribution\n' >"$work/m2"
printf 'c2a368ee\ndistributions /x\n' >"$work/m3"
check "marker_holder prints the first line" "c2a368ee" "$(marker_holder "$work/m1")"
check "marker_field prints a field's value" "0 /d" "$(v=$(marker_field "$work/m1" distribution); echo "$? $v")"
check "marker_field prints a bare field as empty" "0 " "$(v=$(marker_field "$work/m2" distribution); echo "$? $v")"
check "marker_field fails with no such line, a longer key included" "1 " "$(v=$(marker_field "$work/m3" distribution); echo "$? $v")"
check "marker_record_path names the worker's launch record" "$repo/.git/mp-supervise-launch-c2a368ee" "$(marker_record_path "$repo" c2a368ee)"
# marker_launch_dist: the marker while it names the worker, else the record.
mk=$(marker_path "$repo"); rec=$(marker_record_path "$repo" c2a368ee)
ld() { v=$(marker_launch_dist "$repo" c2a368ee); echo "$? $v"; }
check "marker_launch_dist: neither marker nor record fails" "1 " "$(ld)"
printf 'distribution /r\n' >"$rec"
check "marker_launch_dist: the record with no marker" "0 /r" "$(ld)"
printf 'c2a368ee\ndistribution /m\n' >"$mk"
check "marker_launch_dist: the marker wins over the record" "0 /m" "$(ld)"
printf '7a6a0741\ndistribution /o\n' >"$mk"
check "marker_launch_dist: another worker's marker is passed over" "0 /r" "$(ld)"
printf 'c2a368ee\n' >"$mk"
command rm -f "$rec"
check "marker_launch_dist: a marker with no distribution line and no record fails" "1 " "$(ld)"
command rm -f "$mk"
check "marker_line: a key and value, or a bare key" "distribution /d
distribution" "$(marker_line distribution /d; marker_line distribution "")"
marker_write "$work/w1" c2a368ee distribution /d
marker_write "$work/w2" c2a368ee distribution
check "marker_write: the id, then the line, read back by marker_field" "c2a368ee 0 /d c2a368ee 0 " \
    "$(marker_holder "$work/w1") $(v=$(marker_field "$work/w1" distribution); echo "$? $v") $(marker_holder "$work/w2") $(v=$(marker_field "$work/w2" distribution); echo "$? $v")"
check "marker_write: fails when the file cannot be written" "1" "$(marker_write "$work/nodir/m" x distribution 2>/dev/null; echo $?)"

# --- settle.sh -------------------------------------------------------------
. "$scripts/settle.sh"

lists "$(row running 101)" "$(row stopped null)"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "stopped ends the wait" "0 stopped" "$rc $out"
check "the stop comes before the first read" "stop c2a368ee" "$(head -n 1 "$work/claude-calls")"

lists '[]'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "a session no longer listed is gone" "0 gone" "$rc $out"

lists "$(row done null)"
out=$(stop_and_settle c2a368ee 0 0 300 settle_row); rc=$?
check "no pid for the settle time reads as stopped" "0 stopped" "$rc $out"

# A pid showing again starts the settle time over: with a 1-second settle,
# nopid, pid, nopid, nopid... ends only after the pid, so at least two reads
# follow it.
lists "$(row done null)" "$(row running 101)" "$(row done null)"
out=$(stop_and_settle c2a368ee 1 1 300 settle_row); rc=$?
reads=$(grep -c '^agents' "$work/claude-calls")
check "a pid showing again restarts the settle time" "0 stopped yes" "$rc $out $([ "$reads" -ge 4 ] && echo yes)"

lists "$(row running 101)"
out=$(stop_and_settle c2a368ee 60 0 0 settle_row); rc=$?
check "a session not seen to stop times out" "1 session c2a368ee was not stopped 0s after claude stop" "$rc $out"

lists "$(row running 101)"
out=$(FAKE_AGENTS_FAIL=1; export FAKE_AGENTS_FAIL; stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "a failed agents read is reported" "1 claude agents --json --all failed, so session c2a368ee's state is unknown" "$rc $out"
# A read that hangs past the limit counts as one failed poll (#240): the
# next read decides, and only reads hung that many times in a row fail.
lists "$(row stopped null)"
out=$( (export FAKE_AGENTS_HANG=2 MP_AGENTS_TIMEOUT=1; stop_and_settle c2a368ee 60 0 300 settle_row) ); rc=$?
check "a hung agents read is read again" "0 stopped" "$rc $out"
lists "$(row stopped null)"
t0=$(date +%s)
out=$( (export FAKE_AGENTS_HANG=9 MP_AGENTS_TIMEOUT=1; stop_and_settle c2a368ee 60 0 300 settle_row 2>&1) ); rc=$?
t1=$(date +%s)
check "agents reads hung 3 times in a row are reported" "1 claude agents --json --all did not answer in 1s, 3 times in a row, so session c2a368ee's state is unknown" "$rc $out"
check "hung agents reads end the wait within their limits" "yes" "$( [ $((t1 - t0)) -le 5 ] && echo yes || echo "no, $((t1 - t0))s")"

lists 'not json'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row); rc=$?
check "an unreadable list is reported" "1 claude agents --json --all printed no list jq could read, so session c2a368ee's state is unknown" "$rc $out"

# The daemon lets the job go a moment after `claude agents` shows it
# stopped, and a resume in that moment starts a copy (#185). So a session
# the roster still lists is not settled yet, whichever way it was read as
# stopped, and the wait goes on until the roster drops it.
lists "$(row stopped null)" "$(row stopped null)" "$(row stopped null)"
rosters "$held" "$held" "$freed"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "stopped waits until the roster drops the job" "0 stopped 3" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row done null)" "$(row done null)"
rosters "$held" "$freed"
out=$(stop_and_settle c2a368ee 0 0 300 settle_row "$work/roster.json"); rc=$?
check "the settle time's stopped waits for the roster too" "0 stopped 2" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row stopped null)"
rosters "$held"
out=$(stop_and_settle c2a368ee 60 0 0 settle_row "$work/roster.json"); rc=$?
check "a job the roster keeps is stopped at the timeout" "0 stopped" "$rc $out"

lists "$(row stopped null)" "$(row stopped null)"
rosters 'not json' "$freed"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "an unreadable roster is read again" "0 stopped 2" "$rc $out $(grep -c '^agents' "$work/claude-calls")"

lists "$(row stopped null)"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "no roster file means no daemon holds the job" "0 stopped" "$rc $out"

lists "$(row stopped null)"
rosters '{"proto":1}'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "a roster with no workers holds no job" "0 stopped" "$rc $out"

lists "$(row stopped null)"
rosters '{"workers":[]}'
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "a roster whose workers is no object holds no job" "0 stopped" "$rc $out"

# Only a stop waits for the roster: gone and a caller's own word end the
# wait as they did.
lists '[]'
rosters "$held"
out=$(stop_and_settle c2a368ee 60 0 300 settle_row "$work/roster.json"); rc=$?
check "gone does not wait for the roster" "0 gone" "$rc $out"

# A caller's own verdict: any word but pid and nopid ends the wait with it.
mine() { echo "others somewhere"; }
lists "$(row running 101)"
out=$(stop_and_settle c2a368ee 60 0 300 mine); rc=$?
check "a caller's verdict word ends the wait" "0 others somewhere" "$rc $out"

# --- live.sh ---------------------------------------------------------------
. "$scripts/live.sh"

# bg <id> <cwd> <state json> <pid json> [kind]: one claude agents row.
bg() { printf '{"id":"%s","kind":"%s","cwd":"%s","state":%s,"pid":%s}' "$1" "${5:-background}" "$2" "$3" "$4"; }
d=/w/proj
agents="[$(bg a1 $d '"working"' 11),$(bg a2 $d '"stopped"' null),$(bg a3 $d '"done"' null),$(bg a4 $d '"done"' 14),$(bg a5 $d null null),$(bg a6 /w/other '"working"' 16),$(bg a7 $d '"working"' 17 interactive),$(bg a8 $d '"blocked"' null)]"
out=$(live_others "$agents" "$d"); rc=$?
check "live: working, done with a pid, unknown and blocked count; stopped, done with no pid, another folder and an interactive row do not" \
    "0 a1 (working), a4 (done), a5 (unknown), a8 (blocked)" "$rc $out"
out=$(live_others "[$(bg a2 $d '"stopped"' null)]" "$d"); rc=$?
check "live: none live prints nothing" "0 " "$rc $out"
out=$(live_others "[]" "$d"); rc=$?
check "live: an empty list prints nothing" "0 " "$rc $out"
live_others "not json" "$d" >/dev/null; rc=$?
check "live: a list jq cannot read fails" "fail" "$([ $rc -ne 0 ] && echo fail || echo ok)"
out=$(printf '%s' "$agents" | jq -c "$live_def [.[] | select(live) | .id]")
check "live: live_def works inside a caller's own jq" '["a1","a4","a5","a6","a8"]' "$out"

# The rule lives only in live.sh: no script carries its own copy (#115).
skills="$root/plugins/mp-ported-skills/skills"
copies=$(grep -l '.state != "done" or .pid != null' "$skills"/*/scripts/*.sh | sed "s|$skills/||")
check "live: the rule is written only in live.sh" "supervise/scripts/live.sh" "$copies"
for f in supervise/scripts/launch.sh supervise/scripts/resume.sh resuming/scripts/state.sh; do
    grep -q 'live\.sh"' "$skills/$f"; rc=$?
    check "live: $f sources live.sh" 0 "$rc"
done

# --- accept.sh -------------------------------------------------------------
. "$scripts/accept.sh"

check "accept: case 2 names its ticket" 12 \
    "$(accept_step '2 /implement #12 (you type it): #12 Do a thing')"
check "accept: case 1 with only an in-motion parent takes its ready-for-agent child" 41 \
    "$(accept_step '1 work in flight: in motion #40 Supervise; next child #41 (ready-for-agent, /implement #41, you type it)')"
check "accept: case 1 with git work before the parent is not taken" "" \
    "$(accept_step '1 work in flight: 2 uncommitted paths, in motion #40 Supervise; next child #41 (ready-for-agent, /implement #41, you type it)')"
check "accept: a ready-for-human child is not taken" "" \
    "$(accept_step '1 work in flight: in motion #40 Supervise; next child #41 (ready-for-human, by hand)')"
check "accept: case 3 is not taken" "" \
    "$(accept_step '3 /triage (you type it): 1 unlabelled')"

# The patterns live only in accept.sh: step.sh and state.sh both use it.
copies=$(grep -l 'in motion #\[0-9\]\[0-9\]\* \[^;\]\*; next child' "$skills"/*/scripts/*.sh | sed "s|$skills/||")
check "accept: the patterns are written only in accept.sh" "supervise/scripts/accept.sh" "$copies"
for f in supervise/scripts/step.sh resuming/scripts/state.sh; do
    grep -q 'accept\.sh"' "$skills/$f"; rc=$?
    check "accept: $f sources accept.sh" 0 "$rc"
done

# --- park.sh ---------------------------------------------------------------
. "$scripts/park.sh"
parked() { jq -rn --arg b "$1" "$park_def"'$b | parked'; }
check "park: the heading alone" true "$(parked "$park_heading")"
check "park: the heading after blank lines, with its question" true "$(parked "
$park_heading: which name?")"
check "park: a longer word is not the heading" false "$(parked "${park_heading}ness")"
check "park: the heading inside a line is not" false "$(parked "Not $park_heading")"
record() { jq -rn --arg b "$1" "$park_record_def"'$b | run_record'; }
check "park: a supervised run record" true "$(record '## Supervised run of #158
- worker: abc')"
check "park: a hand run record" true "$(record '## Hand run of #7')"
check "park: a comment naming a run record is not one" false "$(record 'See ## Supervised run of #158')"
out=$(printf '%s\n' 'Done.' '**Parked: first?**' 'mid Parked: no' '`Parked: which name?`  ' | sed -n "$park_line_sed")
check "park: park_line_sed prints each question, less its markdown" "first?
which name?" "$out"
check "park: park_question takes the last, less its markdown" "which name?" \
    "$(jq -rn --arg t "$(printf '%s\n' '**Parked: first?**' '`Parked: which name?`')" "$park_question_def"'$t | park_question')"
check "park: park_question with no Parked: line" null "$(jq -rn "$park_question_def"'"Done." | park_question')"

# --- transcript.sh -----------------------------------------------------------
. "$scripts/transcript.sh"
tof() { # <session id>: transcript_of's status and output
    out=$(transcript_of "$1"); printf '%s %s' "$?" "$out"
}
tcfg="$work/tcfg"
mkdir -p "$tcfg/projects/-work-project" "$tcfg/projects/-work-project--claude-worktrees-x"
: >"$tcfg/projects/-work-project--claude-worktrees-x/s1.jsonl"
mkdir -p "$tcfg/projects/-work-project/s2.jsonl"
check "transcript: found in any project folder" "0 $tcfg/projects/-work-project--claude-worktrees-x/s1.jsonl" \
    "$(CLAUDE_CONFIG_DIR=$tcfg; tof s1)"
check "transcript: none found prints nothing, status 1" "1 " "$(CLAUDE_CONFIG_DIR=$tcfg; tof s9)"
check "transcript: a folder of that name is not one" "1 " "$(CLAUDE_CONFIG_DIR=$tcfg; tof s2)"
check "transcript: an empty id finds none" "1 " "$(CLAUDE_CONFIG_DIR=$tcfg; tof '')"
check "transcript: subagents beside the main one" "$tcfg/projects/-w/s1/subagents" \
    "$(transcript_subagents_dir "$tcfg/projects/-w/s1.jsonl")"

# --- own-repo.sh -------------------------------------------------------------
. "$scripts/own-repo.sh"
own() { # <dir>: own_repo_top's output and status
    out=$(own_repo_top "$1"); printf '%s %s' "$?" "$out"
}
mkdir -p "$work/own/repo/sub" "$work/own/plain"
git -C "$work/own/repo" init -q
ln -s "$work/own/repo" "$work/own/link"
check "own-repo: a repo's top passes, resolved" "0 $work/own/repo" "$(own "$work/own/repo")"
check "own-repo: a symlink to a repo's top passes, resolved" "0 $work/own/repo" "$(own "$work/own/link")"
check "own-repo: a relative path to a repo's top passes, resolved" "0 $work/own/repo" "$(cd "$work/own/plain" && own ../repo)"
check "own-repo: a plain folder inside a repo fails" "1 " "$(own "$work/own/repo/sub")"
check "own-repo: a folder in no repo fails" "1 " "$(own "$work/own/plain")"
check "own-repo: a missing folder fails" "1 " "$(own "$work/own/gone")"

# --- distribution-repo.sh -----------------------------------------------------
. "$scripts/distribution-repo.sh"
dcheck() { # <path> <project top>: distribution_check's output and status
    out=$(distribution_check "$1" "$2"); printf '%s %s' "$?" "$out"
}
dg() { git -C "$work/drepo/r" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
mkdir -p "$work/drepo/r/sub" "$work/drepo/proj"
git -C "$work/drepo/r" init -q -b main
git -C "$work/drepo/proj" init -q -b main
dg commit --allow-empty -m seed
dg worktree add "$work/drepo/linked" -b linked
ln -s "$work/drepo/r" "$work/drepo/link"
check "distribution: a repo's top passes, silent" "0 " "$(dcheck "$work/drepo/r" "$work/drepo/proj")"
check "distribution: a symlink to a repo's top passes" "0 " "$(dcheck "$work/drepo/link" "$work/drepo/proj")"
check "distribution: a missing folder" "1 missing" "$(dcheck "$work/drepo/gone" "$work/drepo/proj")"
check "distribution: a plain folder inside a repo is not its top" "1 not-top" "$(dcheck "$work/drepo/r/sub" "$work/drepo/proj")"
check "distribution: a folder in no repo is not a top" "1 not-top" "$(dcheck "$work/own/plain" "$work/drepo/proj")"
check "distribution: a linked worktree" "1 linked-worktree" "$(dcheck "$work/drepo/linked" "$work/drepo/proj")"
check "distribution: the Project's own repo" "1 own-repo" "$(dcheck "$work/drepo/r" "$work/drepo/r")"
check "distribution: the Project's own repo, by a symlink" "1 own-repo" "$(dcheck "$work/drepo/link" "$work/drepo/r")"

dstate() { # <dir>: distribution_state's status and variables
    distribution_state "$1"; printf '%s %s %s %s %s' "$?" "$distribution_branch" "$distribution_default" "$distribution_dirty" "$distribution_unpushed"
}
check "distribution state: clean, no remote" "0 main main 0 0" "$(dstate "$work/drepo/r")"
echo x >"$work/drepo/r/a"; echo y >"$work/drepo/r/b"
check "distribution state: uncommitted paths counted" "0 main main 2 0" "$(dstate "$work/drepo/r")"
command rm -f "$work/drepo/r/a" "$work/drepo/r/b"
git init -q --bare "$work/drepo/r.git"
dg remote add origin "$work/drepo/r.git"
dg push -u origin main
dg remote set-head origin main
dg commit --allow-empty -m wip
check "distribution state: commits no remote holds counted" "0 main main 0 1" "$(dstate "$work/drepo/r")"
dg checkout -b topic
check "distribution state: the branch against origin's default" "0 topic main 0 1" "$(dstate "$work/drepo/r")"
dg checkout --detach
check "distribution state: a detached HEAD" "0 (detached) main 0 1" "$(dstate "$work/drepo/r")"
check "distribution state: git status failing exits 1, dirty 0" "1 (detached) main 0 0" "$(dstate "$work/drepo/gone" 2>/dev/null)"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
