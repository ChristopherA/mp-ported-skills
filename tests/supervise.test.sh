#!/bin/sh
# supervise.test.sh -- tests for the supervise skill's step.sh, launch.sh,
# watch.sh, resume.sh and actions.sh.
#
# step.sh reads canned state.sh output. watch.sh reads the recorded
# `claude agents --json --all` fixtures in tests/fixtures/agents-json/, once
# with --file and in its polling loop through a fake `claude` on PATH that
# serves them in sequence, with a worker's transcript from
# tests/fixtures/transcripts/ installed under the config dir's projects/ where
# a test needs one. launch.sh runs against the same fake `claude`,
# which records its arguments, working directory and CLAUDE_CONFIG_DIR, and
# writes the job's state.json the daemon would. resume.sh runs against it
# too: the fake logs each stop, rm and resume in order, and answers each
# resume with a wake or a copy, as the resume-out list says. actions.sh
# reads a job's state.json and the shared-actions transcript fixture,
# against a scratch repo with a bare remote. Touches nothing outside its own mktemp directory.
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
unset MP_SUPERVISE_WAIT MP_RESUME_BUDGET CLAUDE_PROJECT_DIR FAKE_AGENTS_FAIL FAKE_BG_OUT FAKE_NO_STATE FAKE_STATE_FILTER FAKE_RM_FAIL FAKE_GH_TITLE FAKE_GH_FAIL CLAUDE_CODE_SESSION_ATTENDED
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
check "watch: question asked" "blocked input needed
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

# A worker that ended its turn on a plain-text question is blocked with no
# waitingFor; it is named a question, and keeps the job's needs line (#85).
mkdir -p "$cfg/jobs/91a06a74"
jq '.needs = "push to origin/main now?"' "$fixtures/job-state.json" >"$cfg/jobs/91a06a74/state.json"
jq '[.[] | if .kind == "background" then del(.waitingFor) else . end]' \
    "$fixtures/blocked-permission-prompt.json" >"$work/no-waiting-for.json"
check "watch: blocked with no waitingFor is a question" "blocked question
cwd /work/project
needs push to origin/main now?" "$(sh "$scripts/watch.sh" --id 91a06a74 --file "$work/no-waiting-for.json" </dev/null)"
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
# A turn that ended on a `Waiting on:` line, as launch.sh tells a worker to
# end on an ungranted shared action (#88), is blocked on that action, with it
# as the needs line, whether claude agents says working or done.
waiting_on() { # <last text> [session id] -- turn-ended, its final text block set to it
    dir="$cfg/projects/-work-project"
    command rm -rf "$cfg/projects"; mkdir -p "$dir"
    jq -c --arg t "$1" 'if .type == "assistant" and .message.content == [{"type": "text"}]
        then .message.content[0].text = $t else . end' "$transcripts/turn-ended.jsonl" \
        >"$dir/${2:-9121ff49-5e25-43f0-bf48-307db0776c36}.jsonl"
}
waiting_on "Committed 3 changes on main.

\`Waiting on: git push origin main\`"
check "watch: a turn that ended waiting on an action is blocked on it" "blocked input needed
cwd /work/project
note claude agents still said working
needs git push origin main" "$(watch_file working-idle 9121ff49)"
check "watch: done waiting on an action is blocked on it" "blocked input needed
cwd /work/project
needs git push origin main" "$(watch_file done 9121ff49)"
waiting_on "All done; pushed to main. Nothing is Waiting on: anything."
check "watch: a mention mid-line is not waiting" "done
cwd /work/project" "$(watch_file done 9121ff49)"
# The background service can mark that worker blocked with no waitingFor
# before watch.sh sees it done. The `Waiting on:` line still names what it
# waits on, and wins over the job's needs summary, which can name a side
# question from the worker's report (#97).
blocked_session=91a06a74-3c17-4d7f-a012-61d07453d1c8
mkdir -p "$cfg/jobs/91a06a74"
jq '.needs = "clarify: should pid always win?"' "$fixtures/job-state.json" >"$cfg/jobs/91a06a74/state.json"
waiting_on "Committed 3 changes on main.

\`Waiting on: git push origin main\`" "$blocked_session"
check "watch: blocked with no waitingFor, waiting on an action" "blocked input needed
cwd /work/project
needs git push origin main" "$(sh "$scripts/watch.sh" --id 91a06a74 --file "$work/no-waiting-for.json" </dev/null)"
waiting_on "Should pid always win?" "$blocked_session"
check "watch: blocked with no waitingFor and no Waiting on: is a question" "blocked question
cwd /work/project
needs clarify: should pid always win?" "$(sh "$scripts/watch.sh" --id 91a06a74 --file "$work/no-waiting-for.json" </dev/null)"
# A row that names what it waits for is read as before.
waiting_on "\`Waiting on: git push origin main\`" "$blocked_session"
check "watch: blocked with a waitingFor ignores Waiting on:" "blocked permission prompt
cwd /work/project
needs clarify: should pid always win?" "$(watch_file blocked-permission-prompt 91a06a74)"
command rm -rf "$cfg/jobs/91a06a74"
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

# With --dir, a working worker whose cwd has left the Project folder (it
# entered a worktree) is reported at once. --dir must name a real folder, so
# these fixtures are rewritten from /work/project to one.
project="$work/project"
mkdir -p "$project"
in_project() { # <fixture> -- its path, with /work/project rewritten to $project
    jq --arg d "$project" '[.[] | .cwd |= (if . then sub("^/work/project"; $d) else . end)]' \
        "$fixtures/$1.json" >"$work/$1.in-project.json"
    echo "$work/$1.in-project.json"
}
watch_in_project() { # <fixture> <id> -- watch.sh --dir $project on that fixture
    sh "$scripts/watch.sh" --id "$2" --dir "$project" --file "$(in_project "$1")" </dev/null
}
check "watch --dir: working in a worktree is moved" "moved
cwd $project/.claude/worktrees/issue-66" "$(watch_in_project working-moved c2a368ee)"
check "watch --dir: working in the folder is working" "working
cwd $project" "$(watch_in_project working-busy c2a368ee)"
check "watch --dir: done is not moved" "done
cwd $project" "$(watch_in_project done 9121ff49)"
check "watch: without --dir, a worktree cwd is working" "working
cwd /work/project/.claude/worktrees/issue-66" "$(watch_file working-moved c2a368ee)"
out=$(sh "$scripts/watch.sh" --id c2a368ee --dir "$work/missing" --file "$fixtures/working-busy.json" </dev/null 2>&1)
check "watch --dir: missing folder exits 1" "1" "$?"
check "watch --dir: missing folder says so" "Error: not a directory: $work/missing" "$out"

# With --since, a worktree or branch made in the Project's repo after the
# snapshot is reported, whatever the worker's cwd: a worker with EnterWorktree
# denied ran `git worktree add` from Bash and kept its cwd in the folder.
project_git() { # <git args> -- git in $project, its output dropped, errors shown
    git -C "$project" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@" >/dev/null
}
project_git init -b main
echo seed >"$project/README"
project_git add README
project_git commit -m seed
project_git branch older
project_git worktree add -q "$work/kept" -b kept
sh "$scripts/watch.sh" --dir "$project" --snapshot </dev/null >"$work/since"
check "snapshot: head, branch, worktrees and refs" "head $(git -C "$project" rev-parse HEAD)
branch main
worktree $project
worktree $work/kept
ref kept $(git -C "$project" rev-parse HEAD)
ref main $(git -C "$project" rev-parse HEAD)
ref older $(git -C "$project" rev-parse HEAD)" "$(command cat "$work/since")"
watch_since() { # <fixture> <id> -- watch.sh --dir $project --since on that fixture
    sh "$scripts/watch.sh" --id "$2" --dir "$project" --since "$work/since" --file "$(in_project "$1")" </dev/null
}
check "watch --since: nothing made is working" "working
cwd $project" "$(watch_since working-busy c2a368ee)"
# Commits on the default branch in the folder are where they belong.
echo more >>"$project/README"
project_git commit -am "Add more"
check "watch --since: commits on the folder's branch are working" "working
cwd $project" "$(watch_since working-busy c2a368ee)"
project_git worktree add -q "$project/.wt-iso" -b iso-test
echo hi >"$project/.wt-iso/hello.txt"
git -C "$project/.wt-iso" add hello.txt
git -C "$project/.wt-iso" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q -m "Add hello.txt"
made="worktree $project/.wt-iso
branch iso-test
commit $(git -C "$project" rev-parse --short iso-test) Add hello.txt"
check "watch --since: a worktree made from Bash is moved" "moved
cwd $project
$made" "$(watch_since working-busy c2a368ee)"
check "watch --since: done with a worktree made is moved" "moved
cwd $project
$made" "$(watch_since done 9121ff49)"
check "watch --since: blocked keeps its state and names the worktree" "blocked permission prompt
cwd $project
$made" "$(watch_since blocked-permission-prompt 91a06a74)"
check "watch --since: stopped keeps its state and names the worktree" "stopped
cwd $project
$made" "$(watch_since stopped c2a368ee)"
project_git worktree remove --force "$project/.wt-iso"
project_git branch -D iso-test
# A branch the worker checks out and commits on in the folder counts too.
project_git checkout -q older
project_git commit --allow-empty -m "On older"
check "watch --since: a branch checked out in the folder is moved" "moved
cwd $project
branch older
commit $(git -C "$project" rev-parse --short older) On older" "$(watch_since working-busy c2a368ee)"
project_git checkout -q main
project_git branch -f older "$(sed -n 's/^head //p' "$work/since")"
git -C "$work/kept" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m "On kept"
check "watch --since: commits on an older worktree's branch are moved" "moved
cwd $project
branch kept
commit $(git -C "$project" rev-parse --short kept) On kept" "$(watch_since working-busy c2a368ee)"
# A detached worktree's commits are on no branch, so they follow its line.
project_git worktree add -q --detach "$project/.wt-detached"
git -C "$project/.wt-detached" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m "Detached"
check "watch --since: a detached worktree lists its commits" "moved
cwd $project
worktree $project/.wt-detached
commit $(git -C "$project/.wt-detached" rev-parse --short HEAD) Detached
branch kept
commit $(git -C "$project" rev-parse --short kept) On kept" "$(watch_since working-busy c2a368ee)"
project_git worktree remove --force "$project/.wt-detached"
# A worktree locked with a reason starting `claude agent bridge-` is a
# session the Claude app started in the Project during the run, not the
# worker: it is listed as `other <path>`, and neither it nor its branch
# turns a working or done worker into moved. A fresh snapshot keeps this
# check clear of the `kept` branch's commit added above.
sh "$scripts/watch.sh" --dir "$project" --snapshot </dev/null >"$work/since-bridge"
watch_since_bridge() { # <fixture> <id> -- watch.sh --dir $project --since on a fresh snapshot
    sh "$scripts/watch.sh" --id "$2" --dir "$project" --since "$work/since-bridge" --file "$(in_project "$1")" </dev/null
}
bridge="$project/.claude/worktrees/bridge-x"
project_git worktree add -q -b bridge-x "$bridge"
git -C "$bridge" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m "Bridge commit"
project_git worktree lock --reason 'claude agent bridge-x (pid 1)' "$bridge"
check "watch --since: a Claude-app bridge worktree is not moved" "working
cwd $project
other $bridge" "$(watch_since_bridge working-busy c2a368ee)"
check "watch --since: a bridge worktree leaves done alone too" "done
cwd $project
other $bridge" "$(watch_since_bridge done 9121ff49)"
# Unlocked, or locked for another reason, it is still moved.
project_git worktree unlock "$bridge"
check "watch --since: an unlocked worktree in a bridge path is still moved" "moved
cwd $project
worktree $bridge
branch bridge-x
commit $(git -C "$bridge" rev-parse --short HEAD) Bridge commit" "$(watch_since_bridge working-busy c2a368ee)"
project_git worktree lock --reason 'something else' "$bridge"
check "watch --since: locked for another reason is still moved" "moved
cwd $project
worktree $bridge
branch bridge-x
commit $(git -C "$bridge" rev-parse --short HEAD) Bridge commit" "$(watch_since_bridge working-busy c2a368ee)"
project_git worktree unlock "$bridge"
project_git worktree remove --force "$bridge"
project_git branch -D bridge-x
out=$(sh "$scripts/watch.sh" --dir "$project" --since "$work/missing" --id c2a368ee --file "$(in_project working-busy)" </dev/null 2>&1)
check "watch --since: missing snapshot exits 1" "1" "$?"
check "watch --since: missing snapshot says so" "Error: no such snapshot: $work/missing" "$out"
sh "$scripts/watch.sh" --since "$work/since" --id c2a368ee --file "$(in_project working-busy)" </dev/null >/dev/null 2>&1
check "watch --since: needs --dir" "1" "$?"
sh "$scripts/watch.sh" --snapshot </dev/null >/dev/null 2>&1
check "watch --snapshot: needs --dir" "1" "$?"
sh "$scripts/watch.sh" --snapshot --dir "$work/not-a-repo" </dev/null >/dev/null 2>&1
check "watch --snapshot: not a repo exits 1" "1" "$?"

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
    rm) echo "rm $2" >>"$fake/calls"
        [ -n "${FAKE_RM_FAIL:-}" ] && { echo "cannot remove $2" >&2; exit 1; }
        echo "removed $2" ;;
    --bg)
        if [ "${2:-}" = --resume ]; then
            m=$(command cat "$fake/resumes" 2>/dev/null || echo 0); m=$((m + 1)); echo "$m" >"$fake/resumes"
            echo "resume after $(command cat "$fake/count" 2>/dev/null || echo 0) reads" >>"$fake/calls"
            printf '%s\n' "$@" >"$fake/resume-args"; pwd -P >"$fake/cwd"
            echo "${CLAUDE_CONFIG_DIR-unset}" >"$fake/env"
            r=$(sed -n "${m}p" "$fake/resume-out")
            echo "Starting background service…"
            case $r in
                woke) echo "note: woke session c2a368ee with its saved options (--disallowedTools, --permission-mode, --model)."
                      echo "backgrounded · c2a368ee" ;;
                copy\ *) echo "note: session c2a368ee is already running in the background, so this started a copy as ${r#copy }. \`claude attach c2a368ee\` opens the original."
                      echo "backgrounded · ${r#copy }" ;;
                *) echo "$r" ;;
            esac
            exit 0
        fi
        printf '%s\n' "$@" >"$fake/args"; pwd -P >"$fake/cwd"
        echo "${CLAUDE_CONFIG_DIR-unset}" >"$fake/env"
        if [ -n "${FAKE_BG_OUT+x}" ]; then printf '%s\n' "$FAKE_BG_OUT"; exit 0; fi
        # A named session's line ends with its name, and with FORCE_COLOR
        # set the id is colored, as 2.1.288 printed for `claude --bg --name`.
        asp=""; effort=""; name=""; prev=""
        for a in "$@"; do
            [ "$prev" = --append-system-prompt ] && asp=$a
            [ "$prev" = --effort ] && effort=$a
            [ "$prev" = --name ] && name=$a
            prev=$a
        done
        echo "Starting background service…"
        if [ -n "$name" ]; then printf 'backgrounded · \033[36mc2a368ee\033[39m · %s\n' "$name"
        else echo "backgrounded · c2a368ee"; fi
        if [ -z "${FAKE_NO_STATE:-}" ]; then
            # The daemon records --append-system-prompt first in the
            # job's flags, as a live launch with it did (#88).
            # It records --effort too, as a live `claude --bg --effort
            # medium` job did on 2.1.286, and --name, with the name in
            # .name, as a live `claude --bg --name` job did on 2.1.288.
            mkdir -p "$CLAUDE_CONFIG_DIR/jobs/c2a368ee"
            jq --arg cfg "$CLAUDE_CONFIG_DIR" --arg cwd "$(pwd -P)" --arg asp "$asp" --arg effort "$effort" --arg name "$name" \
                ".cwd = \$cwd | .providerEnv.CLAUDE_CONFIG_DIR = \$cfg
                 | if \$asp != \"\" then .respawnFlags = [\"--append-system-prompt\", \$asp] + .respawnFlags else . end
                 | if \$effort != \"\" then .respawnFlags += [\"--effort\", \$effort] else . end
                 | if \$name != \"\" then .respawnFlags += [\"--name\", \$name] | .name = \$name | .nameSource = \"user\" else . end
                 ${FAKE_STATE_FILTER:-}" \
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
# launch.sh reads the ticket's title with `gh issue view` in the Project
# folder; the fake serves FAKE_GH_TITLE, or fails with FAKE_GH_FAIL.
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$FAKE_DIR/gh-args"; pwd -P >"$FAKE_DIR/gh-cwd"
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
case "$1 $2" in
    "issue view") printf '%s\n' "${FAKE_GH_TITLE-Add the thing}" ;;
    *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
if [ "$(PATH="$work/bin:$PATH" command -v gh)" != "$work/bin/gh" ]; then
    echo "FAIL fake gh is not first on PATH; not running the rest" >&2
    exit 1
fi
# The job a launch writes carries launch.sh's --settings, as the job of a
# live launch with that flag did on Claude Code 2.1.286.
jq '.respawnFlags = ["--disallowedTools", "EnterWorktree", "--settings", "{\"worktree\":{\"bgIsolation\":\"none\"}}"] + .respawnFlags[2:]' \
    "$fixtures/job-state.json" >"$work/job-launched.json"
export FAKE_DIR="$fake" FAKE_JOB="$work/job-launched.json"
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
printf '%s\n' "$(in_project working-busy)" "$(in_project working-moved)" "$(in_project done)" >"$fake/seq"
check "poll --dir: stops when the worker moves" "moved
cwd $project/.claude/worktrees/issue-66" \
    "$(PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id c2a368ee --dir "$project" --interval 0 --timeout 30 </dev/null)"
check "poll --dir: stopped at the round it moved" "2" "$(command cat "$fake/count")"

# The kept worktree's branch has a commit since the snapshot (above).
reset_fake
in_project working-busy >"$fake/seq"
check "poll --since: stops at a branch made since the snapshot" "moved
cwd $project
branch kept
commit $(git -C "$project" rev-parse --short kept) On kept" \
    "$(PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id c2a368ee --dir "$project" --since "$work/since" --interval 0 --timeout 30 </dev/null)"
check "poll --since: stopped at the first round" "1" "$(command cat "$fake/count")"

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

# --stall (#58): a transcript that never grows across polls is reported as
# a hang, left running, well before the outer --timeout.
reset_fake
transcript just-launched -work-project c2a368ee-c513-484c-83d3-581830e209a5
echo "$fixtures/working-busy.json" >"$fake/seq"
out=$(PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id c2a368ee --interval 1 --timeout 30 --stall 1 </dev/null)
rc=$?
check "poll --stall: exits 0, worker left running" "0" "$rc"
check "poll --stall: reports hang, with cwd" "hang
cwd /work/project" "$(printf '%s\n' "$out" | sed -n '1,2p')"
check "poll --stall: a note names how long with no growth" "1" \
    "$(printf '%s\n' "$out" | grep -cE '^note its transcript has not grown in [0-9]+s$')"

# A --stall longer than --timeout never fires; the outer timeout still does.
reset_fake
transcript just-launched -work-project c2a368ee-c513-484c-83d3-581830e209a5
echo "$fixtures/working-busy.json" >"$fake/seq"
out=$(PATH="$work/bin:$PATH" sh "$scripts/watch.sh" --id c2a368ee --interval 1 --timeout 1 --stall 3600 </dev/null)
rc=$?
check "poll --stall: a high stall does not pre-empt the timeout" "124" "$rc"
check "poll --stall: the timeout still reports working, not hang" "working
cwd /work/project" "$out"
command rm -rf "$cfg/projects"

for bad in "--id c2a368ee --stall x" "--id c2a368ee --stall -1" "--id c2a368ee --stall"; do
    # shellcheck disable=SC2086
    sh "$scripts/watch.sh" $bad </dev/null >/dev/null 2>&1
    check "watch: refuses $bad" "1" "$?"
done

# --- launch.sh -------------------------------------------------------------
# launch.sh reads `claude agents` for other live sessions in the checkout;
# LAUNCH_AGENTS names the list the fake serves (by default, none there).
launch() { # [args...] -- launch.sh --dir $project with the fake claude
    reset_fake
    echo "${LAUNCH_AGENTS:-$fixtures/working-busy.json}" >"$fake/seq"
    PATH="$work/bin:$PATH" sh "$scripts/launch.sh" --dir "$project" "$@" </dev/null
}
out=$(launch --ticket 56 2>&1)
rc=$?
check "launch: exit 0" "0" "$rc"
check "launch: prints the id" "c2a368ee" "$out"
# The worker is told its Project's standing grants (#88). $project has no
# origin, so it has none, and an ungranted action ends the turn on one line.
no_grants="You are a supervised worker, launched by /supervise. This Project grants no shared action: docs/agents/supervision.md, as committed on origin/main, holds no standing grant.
A shared action no grant covers (git push, gh pr create, gh pr merge, gh issue close, gh issue comment, gh issue create) is not yours to take: do not take it or try it. Finish and commit the rest of the work, then end your turn with one line naming the action you wait on, as \`Waiting on: git push origin main\`."
check "launch: flags and the command" "--bg
--model
claude-sonnet-5
--disallowedTools
EnterWorktree
--settings
{\"worktree\":{\"bgIsolation\":\"none\"}}
--append-system-prompt
$no_grants
--name
worker project #56: Add the thing
--permission-mode
auto
/mattpocock-skills:implement #56" "$(command cat "$fake/args")"
check "launch: runs in the project folder" "$project" "$(command cat "$fake/cwd")"
check "launch: sets the config dir" "$cfg" "$(command cat "$fake/env")"
check "launch: stops nothing" "" "$(command cat "$fake/calls" 2>/dev/null)"
check "launch: reads the ticket's title in the project folder" "issue view 56 --json title --jq .title
$project" "$(command cat "$fake/gh-args" "$fake/gh-cwd")"

# The worker is named after its Project and ticket (#103), so the Claude
# app and `claude agents` tell workers apart. A long title is cut.
name_of() { sed -n '/^--name$/{n;p;}' "$fake/args"; }
long="Make every supervised worker show its Project and its ID in the Claude app list"
(export FAKE_GH_TITLE="$long"; launch --ticket 56 >/dev/null 2>&1)
check "launch: a long title is cut, with no space before the dots" "worker project #56: Make every supervised worker show its Project and its ID..." "$(name_of)"
check "launch: the cut name is at most 80 characters" "yes" "$([ "$(name_of | tr -d '\n' | LC_ALL=en_US.UTF-8 wc -m)" -le 80 ] && echo yes || echo no)"
(export FAKE_GH_TITLE="Fix the café sign"; launch --ticket 56 >/dev/null 2>&1)
check "launch: a title with non-ASCII text is kept whole" "worker project #56: Fix the café sign" "$(name_of)"
out=$( (export FAKE_GH_FAIL=1; launch --ticket 56 2>&1) )
rc=$?
check "launch: no title still launches" "0" "$rc"
check "launch: no title names the Project and ticket" "worker project #56" "$(name_of)"
check "launch: no title says why" "note: gh issue view 56 failed (HTTP 404: Not Found), so the worker's name leaves out the ticket's title
c2a368ee" "$out"
out=$( (export FAKE_GH_TITLE=""; launch --ticket 56 2>&1) )
check "launch: an empty title names the Project and ticket" "worker project #56" "$(name_of)"

launch --ticket 56 --model claude-opus-5-5 >/dev/null 2>&1
check "launch: --model passes through" "claude-opus-5-5" "$(sed -n 3p "$fake/args")"
check "launch: no --effort, none passed" "no" "$(grep -qx -- --effort "$fake/args" && echo yes || echo no)"

out=$(launch --ticket 56 --model claude-opus-5-5 --effort medium 2>&1)
rc=$?
check "launch: --effort exit 0" "0" "$rc"
check "launch: --effort passes through after the model" "--model
claude-opus-5-5
--effort
medium
--disallowedTools" "$(sed -n 2,6p "$fake/args")"

out=$(launch --ticket 56 --effort extreme 2>&1)
rc=$?
check "launch: unknown effort refused" "1" "$rc"
check "launch: unknown effort says why" "Error: --effort is low, medium, high, xhigh or max, not 'extreme'" "$out"
check "launch: unknown effort never launched" "no" "$([ -f "$fake/args" ] && echo yes || echo no)"

# The effort value sits before --name and its name, the last two flags.
out=$( (export FAKE_STATE_FILTER='| .respawnFlags[-3] = "high"'; launch --ticket 56 --effort medium 2>&1) )
rc=$?
check "launch: effort not recorded exits 2" "2" "$rc"
check "launch: effort not recorded stops the session" "stop c2a368ee" "$(command cat "$fake/calls" 2>/dev/null)"
check "launch: effort not recorded says why" "Error: session c2a368ee does not run at effort medium (its flags: --append-system-prompt $no_grants --disallowedTools EnterWorktree --settings {\"worktree\":{\"bgIsolation\":\"none\"}} --permission-mode auto --model claude-sonnet-5 --effort high --name worker project #56: Add the thing); stopped it" "$out"

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
mismatch "worktrees allowed" '| .respawnFlags = ["--settings", "{\"worktree\":{\"bgIsolation\":\"none\"}}", "--permission-mode", "auto", "--model", "claude-sonnet-5"]' \
    "Error: session c2a368ee can enter a worktree: EnterWorktree is not in its disallowed tools (its flags: --settings {\"worktree\":{\"bgIsolation\":\"none\"}} --permission-mode auto --model claude-sonnet-5); stopped it"
mismatch "isolation guard on" '| .respawnFlags = ["--disallowedTools", "EnterWorktree", "--permission-mode", "auto", "--model", "claude-sonnet-5"]' \
    "Error: session c2a368ee has the background worktree guard on, so its edits in $project would be refused: bgIsolation none is not in its settings (its flags: --disallowedTools EnterWorktree --permission-mode auto --model claude-sonnet-5); stopped it"
mismatch "isolation guard set to another value" '| .respawnFlags = ["--disallowedTools", "EnterWorktree", "--settings", "{\"worktree\":{\"bgIsolation\":\"worktree\"}}", "--permission-mode", "auto"]' \
    "Error: session c2a368ee has the background worktree guard on, so its edits in $project would be refused: bgIsolation none is not in its settings (its flags: --disallowedTools EnterWorktree --settings {\"worktree\":{\"bgIsolation\":\"worktree\"}} --permission-mode auto); stopped it"
mismatch "grants not recorded" '| .respawnFlags |= .[2:]' \
    "Error: session c2a368ee was not told its Project's grants: its flags hold no --append-system-prompt with them (its flags: --disallowedTools EnterWorktree --settings {\"worktree\":{\"bgIsolation\":\"none\"}} --permission-mode auto --model claude-sonnet-5 --name worker project #56: Add the thing); stopped it"
mismatch "other grants recorded" '| .respawnFlags[1] = "something else"' \
    "Error: session c2a368ee was not told its Project's grants: its flags hold no --append-system-prompt with them (its flags: --append-system-prompt something else --disallowedTools EnterWorktree --settings {\"worktree\":{\"bgIsolation\":\"none\"}} --permission-mode auto --model claude-sonnet-5 --name worker project #56: Add the thing); stopped it"
mismatch "wrong profile" '| .providerEnv.CLAUDE_CONFIG_DIR = "/elsewhere"' \
    "Error: session c2a368ee runs under config /elsewhere, not $cfg; stopped it"
mismatch "no profile recorded" '| del(.providerEnv)' \
    "Error: session c2a368ee runs under config (none recorded), not $cfg; stopped it"
mismatch "another folder" '| .cwd = "/elsewhere"' \
    "Error: session c2a368ee runs in /elsewhere, not $project; stopped it"
mismatch "a worktree" '| .worktreePath = "/w/.claude/worktrees/x"' \
    "Error: session c2a368ee was placed in worktree /w/.claude/worktrees/x, not $project; stopped it"
mismatch "name not recorded" '| .name = "mattpocock skills implementation"' \
    "Error: session c2a368ee is named 'mattpocock skills implementation', not 'worker project #56: Add the thing'; stopped it"
mismatch "no name recorded" '| del(.name)' \
    "Error: session c2a368ee is named '(none recorded)', not 'worker project #56: Add the thing'; stopped it"

out=$( (export FAKE_NO_STATE=1 MP_SUPERVISE_WAIT=1; launch --ticket 56 2>&1) )
rc=$?
check "launch: no job state exits 2" "2" "$rc"
check "launch: no job state stops the session" "stop c2a368ee" "$(command cat "$fake/calls" 2>/dev/null)"
check "launch: no job state says why" "Error: no job state for session c2a368ee under $cfg/jobs after 1s, so its profile is unconfirmed; stopped it" "$out"

# The worker's marker, which the read-only hook reads (#76).
marker=$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-worker)
command rm -f "$marker"
launch --ticket 56 >/dev/null 2>&1
check "launch: writes the worker's marker" "c2a368ee" "$(command cat "$marker" 2>/dev/null)"
command rm -f "$marker"
(export FAKE_STATE_FILTER='| .cwd = "/elsewhere"'; launch --ticket 56 >/dev/null 2>&1)
check "launch: a worker that failed a check leaves no marker" "no" "$([ -f "$marker" ] && echo yes || echo no)"

# The entry check: the default branch, a clean tree, and no other live
# background session in the checkout, before anything launches.
not_launched() { # <name> <expected message> -- run after a launch
    check "launch: $1 exits 1" "1" "$rc"
    check "launch: $1 never launched" "no" "$([ -f "$fake/args" ] && echo yes || echo no)"
    check "launch: $1 says why" "$2" "$out"
}
echo dirty >>"$project/README"
out=$(launch --ticket 56 2>&1); rc=$?
not_launched "a modified file" "Error: $project has uncommitted changes (1 path); commit or clear them before launching a worker there; not launched"
git -C "$project" checkout -q -- README
touch "$project/untracked.txt"
out=$(launch --ticket 56 2>&1); rc=$?
not_launched "an untracked file" "Error: $project has uncommitted changes (1 path); commit or clear them before launching a worker there; not launched"
command rm -f "$project/untracked.txt"
project_git checkout -q -b feature
out=$(launch --ticket 56 2>&1); rc=$?
not_launched "another branch" "Error: $project is on feature, not the default branch main; not launched"
project_git checkout -q main
project_git branch -D feature
jq --arg d "$project" '. + [{id: "7a6a0741", cwd: $d, kind: "background", sessionId: "7a6a0741-0000", name: "x", state: "blocked", pid: 99}]' \
    "$fixtures/working-busy.json" >"$work/other-in-project.json"
out=$(LAUNCH_AGENTS="$work/other-in-project.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "another live session" "Error: another live background session in $project: 7a6a0741 (blocked); not launched"
jq '[.[] | if .id == "7a6a0741" then .state = "stopped" | del(.pid) else . end]' \
    "$work/other-in-project.json" >"$work/stopped-in-project.json"
out=$(LAUNCH_AGENTS="$work/stopped-in-project.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
check "launch: a stopped session in the checkout does not block" "0 c2a368ee" "$rc $out"
# A finished worker shows done with no pid, before and after claude stop
# (#96): it is not live. A pid, or any state but done and stopped, is.
in_project() { # <out> <jq filter on 7a6a0741's row>
    jq "[.[] | if .id == \"7a6a0741\" then $2 else . end]" "$work/other-in-project.json" >"$work/$1.json"
}
in_project done-nopid '.state = "done" | .pid = null'
out=$(LAUNCH_AGENTS="$work/done-nopid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
check "launch: a done session with no pid in the checkout does not block" "0 c2a368ee" "$rc $out"
in_project done-pid '.state = "done"'
out=$(LAUNCH_AGENTS="$work/done-pid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "a done session with a pid" "Error: another live background session in $project: 7a6a0741 (done); not launched"
in_project working-nopid '.state = "working" | .pid = null'
out=$(LAUNCH_AGENTS="$work/working-nopid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "a working session with no pid" "Error: another live background session in $project: 7a6a0741 (working); not launched"
in_project blocked-nopid '.state = "blocked" | del(.pid)'
out=$(LAUNCH_AGENTS="$work/blocked-nopid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "a blocked session with no pid" "Error: another live background session in $project: 7a6a0741 (blocked); not launched"
in_project odd-nopid '.state = "crashed" | .pid = null'
out=$(LAUNCH_AGENTS="$work/odd-nopid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "an unknown state with no pid" "Error: another live background session in $project: 7a6a0741 (crashed); not launched"
in_project nostate-nopid 'del(.state) | .pid = null'
out=$(LAUNCH_AGENTS="$work/nostate-nopid.json"; export LAUNCH_AGENTS; launch --ticket 56 2>&1); rc=$?
not_launched "no state and no pid" "Error: another live background session in $project: 7a6a0741 (unknown); not launched"
out=$( (export FAKE_AGENTS_FAIL=1; launch --ticket 56 2>&1) ); rc=$?
not_launched "an unreadable session list" "Error: claude agents --json --all failed, so other sessions in $project are unknown; not launched"
# A marker left by a worker that is no longer live does not block, and is
# replaced.
echo 0ld0ld00 >"$marker"
out=$(launch --ticket 56 2>&1); rc=$?
check "launch: a stale marker does not block" "0 c2a368ee" "$rc $out"
check "launch: a stale marker is replaced" "c2a368ee" "$(command cat "$marker")"
mkdir -p "$work/not-a-repo"
out=$(PATH="$work/bin:$PATH" sh "$scripts/launch.sh" --dir "$work/not-a-repo" --ticket 56 </dev/null 2>&1); rc=$?
check "launch: not a git checkout exits 1" "1 Error: $work/not-a-repo is not a git checkout; not launched" "$rc $out"

# The grants come from grant.sh's source, docs/agents/supervision.md on
# origin's default branch (#88): one committed but not pushed is not listed.
granted="$work/granted"
git init -q --bare "$work/granted.git"
git init -q -b main "$granted"
granted_git() { git -C "$granted" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
mkdir -p "$granted/docs/agents"
printf '# Supervision\n\n## Grants\n\n- push: to main, once tests pass\n- issue-close\n- issue-comment: findings\n\n## Other\n\n- pr-merge\n' \
    >"$granted/docs/agents/supervision.md"
granted_git add docs
granted_git commit -m grants
granted_git remote add origin "$work/granted.git"
granted_git push origin main
granted_git remote set-head origin main
printf '# Supervision\n\n## Grants\n\n- push: to main, once tests pass\n- issue-close\n- issue-comment: findings\n- pr-create\n\n## Other\n\n- pr-merge\n' \
    >"$granted/docs/agents/supervision.md"
granted_git commit -am 'local grant'
launch_in() { # <dir> [args...] -- launch.sh --dir <dir> with the fake claude
    d=$1; shift
    reset_fake
    echo "$fixtures/working-busy.json" >"$fake/seq"
    PATH="$work/bin:$PATH" sh "$scripts/launch.sh" --dir "$d" "$@" </dev/null
}
out=$(launch_in "$granted" --ticket 56 2>/dev/null); rc=$?
check "launch with grants: exit 0" "0 c2a368ee" "$rc $out"
check "launch with grants: lists the grants on origin, and only those" "You are a supervised worker, launched by /supervise. This Project's standing grants, from docs/agents/supervision.md as committed on origin/main (push is git push; pr-create, pr-merge, issue-close, issue-comment and issue-create are gh pr create, gh pr merge, gh issue close, gh issue comment and gh issue create):
- push: to main, once tests pass
- issue-close
- issue-comment: findings
A shared action one of these grants covers goes ahead without asking: when /implement or a capture reaches it, take it, and do not end your turn to ask first.
A shared action no grant covers (git push, gh pr create, gh pr merge, gh issue close, gh issue comment, gh issue create) is not yours to take: do not take it or try it. Finish and commit the rest of the work, then end your turn with one line naming the action you wait on, as \`Waiting on: git push origin main\`." \
    "$(sed -n '/^--append-system-prompt$/,/^--name$/p' "$fake/args" | sed '1d;$d')"
check "launch with grants: notes the grant committed only locally" "note: docs/agents/supervision.md grants pr-create on the working tree or current branch, not on the committed origin/main; ignored" \
    "$(launch_in "$granted" --ticket 56 2>&1 >/dev/null)"
check "launch with grants: the job's flags carry them" "--append-system-prompt" \
    "$(jq -r '.respawnFlags[0]' "$cfg/jobs/c2a368ee/state.json")"
command rm -f "$(git -C "$granted" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
# A grant.sh error is not read as "no grants": nothing launches.
mkdir -p "$work/broken-scripts"
command cp -f "$scripts"/*.sh "$work/broken-scripts/"
printf '#!/bin/sh\necho "Error: broken" >&2\nexit 1\n' >"$work/broken-scripts/grant.sh"
reset_fake
echo "$fixtures/working-busy.json" >"$fake/seq"
out=$(PATH="$work/bin:$PATH" sh "$work/broken-scripts/launch.sh" --dir "$granted" --ticket 56 </dev/null 2>&1); rc=$?
check "launch: a grant.sh error exits 1" "1" "$rc"
check "launch: a grant.sh error never launched" "no" "$([ -f "$fake/args" ] && echo yes || echo no)"
check "launch: a grant.sh error says why" "grant.sh: Error: broken
Error: grant.sh failed for push, so the worker's grants are unknown; not launched" "$out"

# --- release.sh --------------------------------------------------------------
echo c2a368ee >"$marker"
out=$(sh "$scripts/release.sh" --dir "$project" --id 7a6a0741 </dev/null 2>&1); rc=$?
check "release: another worker's marker exits 1" "1" "$rc"
check "release: another worker's marker is kept" "c2a368ee" "$(command cat "$marker")"
check "release: another worker's marker says so" "Error: the marker in $project names worker c2a368ee, not 7a6a0741; left in place" "$out"
out=$(sh "$scripts/release.sh" --dir "$project" --id c2a368ee </dev/null 2>&1); rc=$?
check "release: removes the worker's marker" "0 released c2a368ee no" "$rc $out $([ -f "$marker" ] && echo yes || echo no)"
out=$(sh "$scripts/release.sh" --dir "$project" --id c2a368ee </dev/null 2>&1); rc=$?
check "release: no marker is not an error" "0 no marker in $project" "$rc $out"
out=$(cd "$project" && sh "$scripts/release.sh" --dir . --id c2a368ee </dev/null 2>&1)
check "release: names the folder by its full path" "no marker in $project" "$out"
sh "$scripts/release.sh" --dir "$project" </dev/null >/dev/null 2>&1
check "release: --id is required" "1" "$?"
sh "$scripts/release.sh" --id c2a368ee </dev/null >/dev/null 2>&1
check "release: --dir is required" "1" "$?"

# --- resume.sh -------------------------------------------------------------
# The worker's row after a stop, in the shapes #77 saw: still working with a
# pid, working with no pid, and stopped. Another background session in the
# same checkout, live or stopped, and one in another folder.
row() { # <out> <jq filter on the worker's row>
    jq "[.[] | if .id == \"c2a368ee\" then $2 else . end]" "$fixtures/stopped.json" >"$work/$1.json"
}
row pid '.state = "working" | .status = "busy" | .pid = 4242'
row nopid '.state = "working" | .status = "idle"'
other() { # <out> <cwd> <state> [pid, default 99]
    jq --arg cwd "$2" --arg state "$3" --argjson pid "${4:-99}" \
        '. + [{id: "7a6a0741", cwd: $cwd, kind: "background", sessionId: "7a6a0741-0000", name: "x", state: $state, pid: $pid}]' \
        "$fixtures/stopped.json" >"$work/$1.json"
}
other other-live /work/project working
other other-done-nopid /work/project done null
other other-done-pid /work/project done
other other-blocked-nopid /work/project blocked null
other other-odd-nopid /work/project crashed null
other other-working-nopid /work/project working null
jq '[.[] | if .id == "7a6a0741" then del(.state) else . end]' "$work/other-odd-nopid.json" >"$work/other-nostate-nopid.json"
other other-stopped /work/project stopped
other other-elsewhere /work/other working
sid=c2a368ee-c513-484c-83d3-581830e209a5
resume() { # <resume outputs, comma-separated> <agents lists...> -- then resume.sh's options after --
    outs=$1; shift
    reset_fake
    mkdir -p "$cfg/jobs/c2a368ee"
    command cp "$fixtures/job-state.json" "$cfg/jobs/c2a368ee/state.json"
    printf '%s\n' "$outs" | tr , '\n' >"$fake/resume-out"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        case $1 in /*) echo "$1" ;; *) echo "$work/$1.json" ;; esac
        shift
    done >"$fake/seq"
    [ $# -gt 0 ] && shift
    PATH="$work/bin:$PATH" sh "$scripts/resume.sh" --id c2a368ee --dir "$project" \
        --prompt /mp-ported-skills:capturing --interval 0 --settle 0 "$@" </dev/null
}
calls() { command cat "$fake/calls" 2>/dev/null; }

out=$(resume woke pid "$fixtures/stopped.json" 2>&1)
rc=$?
check "resume: exit 0" "0" "$rc"
check "resume: prints the id it resumed" "resumed c2a368ee" "$out"
check "resume: stop, wait for stopped, resume" "stop c2a368ee
resume after 2 reads" "$(calls)"
check "resume: the original session id and the prompt, no flags" "--bg
--resume
$sid
/mp-ported-skills:capturing" "$(command cat "$fake/resume-args")"
check "resume: runs in the project folder" "$project" "$(command cat "$fake/cwd")"
check "resume: sets the config dir" "$cfg" "$(command cat "$fake/env")"
check "resume: writes the worker's marker, live again" "c2a368ee" "$(command cat "$marker" 2>/dev/null)"
command rm -f "$marker"

# stopped may never show: a row with no pid for the settle time is enough,
# and a pid showing again starts the settle time over.
resume woke pid nopid -- --settle 2 --interval 1 >/dev/null 2>&1
check "resume: no pid for the settle time" "stop c2a368ee
resume after 4 reads" "$(calls)"
resume woke nopid pid nopid -- --settle 1 --interval 1 >/dev/null 2>&1
check "resume: a pid starts the settle time over" "stop c2a368ee
resume after 4 reads" "$(calls)"

out=$(resume woke pid -- --timeout 1 2>&1)
rc=$?
check "resume: never stopped exits 1" "1" "$rc"
check "resume: never stopped, never resumed" "stop c2a368ee" "$(calls)"
check "resume: never stopped says why" "Error: session c2a368ee was not stopped 1s after claude stop; not resumed" "$out"

out=$(resume woke "$fixtures/done.json" 2>&1)
rc=$?
check "resume: gone exits 1" "1" "$rc"
check "resume: gone, never resumed" "stop c2a368ee" "$(calls)"
check "resume: gone says so" "Error: session c2a368ee is not in claude agents; not resumed" "$out"

out=$( (export FAKE_AGENTS_FAIL=1; resume woke "$fixtures/stopped.json" 2>&1) )
rc=$?
check "resume: unreadable list exits 1" "1" "$rc"
check "resume: unreadable list, never resumed" "stop c2a368ee" "$(calls)"

printf 'not json\n' >"$work/garbage.json"
out=$(resume woke garbage 2>&1)
rc=$?
check "resume: an unreadable list exits 1 at once" "1" "$rc"
check "resume: an unreadable list says so" "Error: claude agents --json --all printed no list jq could read, so session c2a368ee's state is unknown; not resumed" "$out"
( unset CLAUDE_CONFIG_DIR; resume woke "$fixtures/stopped.json" >/dev/null 2>&1 )
check "resume: config dir required" "1" "$?"
check "resume: no config dir, never stopped" "" "$(calls)"

# Two live workers in one checkout would interleave their commits, so
# another live background session there stops the resume.
out=$(resume woke other-live 2>&1)
rc=$?
check "resume: another live session in the checkout exits 1" "1" "$rc"
check "resume: another live session, never resumed" "stop c2a368ee" "$(calls)"
check "resume: another live session is named" "Error: another live background session in /work/project: 7a6a0741 (working); not resumed" "$out"
check "resume: a stopped one in the checkout is fine" "resumed c2a368ee" "$(resume woke other-stopped 2>&1)"
check "resume: a live one elsewhere is fine" "resumed c2a368ee" "$(resume woke other-elsewhere 2>&1)"
check "resume: a done one with no pid in the checkout is fine" "resumed c2a368ee" "$(resume woke other-done-nopid 2>&1)"
out=$(resume woke other-done-pid 2>&1); rc=$?
check "resume: a done one with a pid stops the resume" "1 Error: another live background session in /work/project: 7a6a0741 (done); not resumed" "$rc $out"
out=$(resume woke other-blocked-nopid 2>&1); rc=$?
check "resume: a blocked one with no pid stops the resume" "1 Error: another live background session in /work/project: 7a6a0741 (blocked); not resumed" "$rc $out"
out=$(resume woke other-odd-nopid 2>&1); rc=$?
check "resume: an unknown state with no pid stops the resume" "1 Error: another live background session in /work/project: 7a6a0741 (crashed); not resumed" "$rc $out"
out=$(resume woke other-working-nopid 2>&1); rc=$?
check "resume: a working one with no pid stops the resume" "1 Error: another live background session in /work/project: 7a6a0741 (working); not resumed" "$rc $out"
out=$(resume woke other-nostate-nopid 2>&1); rc=$?
check "resume: no state and no pid stops the resume" "1 Error: another live background session in /work/project: 7a6a0741 (unknown); not resumed" "$rc $out"

# A copy runs without the launch's guards, so it is stopped and removed at
# once, and the resume retried on the original.
out=$(resume "copy 17d1a711,woke" "$fixtures/stopped.json" 2>&1)
rc=$?
check "resume: a copy, then the original, exits 0" "0" "$rc"
check "resume: the copy is reported" "copy 17d1a711 stopped and removed
resumed c2a368ee" "$out"
check "resume: the copy is stopped and removed, and the original stopped again, before the retry" "stop c2a368ee
resume after 1 reads
stop 17d1a711
rm 17d1a711
stop c2a368ee
resume after 2 reads" "$(calls)"
check "resume: the retry resumes the original" "$sid" "$(sed -n 3p "$fake/resume-args")"

# A copy means the original was live again (an attach woke it), so the
# retry waits for it to stop once more.
resume "copy 17d1a711,woke" "$fixtures/stopped.json" pid "$fixtures/stopped.json" >/dev/null 2>&1
check "resume: the retry waits for the original to stop again" "stop c2a368ee
resume after 1 reads
stop 17d1a711
rm 17d1a711
stop c2a368ee
resume after 3 reads" "$(calls)"

# A copy that could not be removed may still be listed as live in the
# checkout; it is this run's own, so it does not block the retry.
jq '. + [{id: "17d1a711", cwd: "/work/project", kind: "background", sessionId: "17d1a711-0000", name: "x", state: "working"}]' \
    "$fixtures/stopped.json" >"$work/copy-left.json"
out=$( (export FAKE_RM_FAIL=1; resume "copy 17d1a711,woke" "$fixtures/stopped.json" copy-left 2>&1) )
rc=$?
check "resume: a copy left listed does not block the retry" "0" "$rc"
check "resume: a copy not removed is named" "copy 17d1a711 stopped, not removed
resumed c2a368ee" "$out"
out=$( (export FAKE_RM_FAIL=1; resume "copy 17d1a711,copy fc9de9b3" "$fixtures/stopped.json" -- --tries 2 2>&1) )
check "resume: exit 2 names the copies not removed" "copy 17d1a711 stopped, not removed
copy fc9de9b3 stopped, not removed
Error: every resume of session c2a368ee started a copy (17d1a711 fc9de9b3); 17d1a711 fc9de9b3 stopped but not removed, and c2a368ee is left stopped" "$out"

out=$(resume "copy 17d1a711,copy fc9de9b3" "$fixtures/stopped.json" -- --tries 2 2>&1)
rc=$?
check "resume: a copy every try exits 2" "2" "$rc"
check "resume: every copy is removed and named" "copy 17d1a711 stopped and removed
copy fc9de9b3 stopped and removed
Error: every resume of session c2a368ee started a copy (17d1a711 fc9de9b3); each was removed, and c2a368ee is left stopped" "$out"
check "resume: tries stop at --tries" "2" "$(command cat "$fake/resumes")"

out=$(resume "Error: no conversation found" "$fixtures/stopped.json" 2>&1)
rc=$?
check "resume: unrecognized output exits 1" "1" "$rc"
check "resume: unrecognized output is shown" "Error: claude --bg --resume printed neither a wake nor a copy:
Starting background service…
Error: no conversation found" "$out"

# Without the job's session id there is nothing to resume, so nothing is
# stopped.
reset_fake
out=$(PATH="$work/bin:$PATH" sh "$scripts/resume.sh" --id c2a368ee --dir "$project" --prompt x </dev/null 2>&1)
rc=$?
check "resume: no job state exits 1" "1" "$rc"
check "resume: no job state stops nothing" "" "$(calls)"
check "resume: no job state says why" "Error: no session id in $cfg/jobs/c2a368ee/state.json, so there is nothing to resume" "$out"

for bad in "--dir $project --prompt x" "--id c2a368ee --prompt x" "--id c2a368ee --dir $project" \
    "--id c2a368ee --dir $project --prompt x --settle 1m" "--id c2a368ee --dir $project --prompt x --tries 0"; do
    # shellcheck disable=SC2086
    PATH="$work/bin:$PATH" sh "$scripts/resume.sh" $bad </dev/null >/dev/null 2>&1
    check "resume: refuses $bad" "1" "$?"
done

# --- actions.sh ------------------------------------------------------------
# A Project with a remote: the worker's start commit is on origin/main, and
# its own commit reached origin only on a branch it pushed.
repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}
remote="$work/remote.git"
repo="$work/worker-repo"
git init -q --bare "$remote"
git init -q -b main "$repo"
repo_git "$repo" commit -q --allow-empty -m start
repo_git "$repo" remote add origin "$remote"
repo_git "$repo" push -q origin main 2>/dev/null
# A clone has origin/HEAD, whose short name is the bare remote name.
git -C "$repo" remote set-head origin main
start=$(git -C "$repo" rev-parse HEAD)
repo_git "$repo" commit -q --allow-empty -m "worker's commit"
repo_git "$repo" push -q origin HEAD:66-deny-shared-actions-to-background-workers 2>/dev/null
pushed="branch origin/66-deny-shared-actions-to-background-workers ungranted: holds the worker's commits"
# The same branch when the transcript holds no push of the worker's to it.
others="branch origin/66-deny-shared-actions-to-background-workers pushed by someone else: holds the worker's commits"

sid=c2a368ee-c513-484c-83d3-581830e209a5
job() { # [jq filter] -- install job c2a368ee's state.json
    command rm -rf "$cfg/jobs"
    mkdir -p "$cfg/jobs/c2a368ee"
    jq "${1:-.}" "$fixtures/job-state.json" >"$cfg/jobs/c2a368ee/state.json"
}
actions() { # [start] -- actions.sh's output for job c2a368ee in $repo
    sh "$scripts/actions.sh" --id c2a368ee --dir "$repo" --start "${1:-$start}" </dev/null
}
bash_call() { # <id> <command> [is_error] -- a Bash call and its result, as transcript rows
    jq -cn --arg id "$1" --arg c "$2" \
        '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: $id, name: "Bash", input: {command: $c}}]}}'
    jq -cn --arg id "$1" --argjson e "${3:-false}" \
        '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: $id, is_error: $e, content: "ok"}]}}'
}
# The children entry as the #66 worker's job recorded it.
job '.children = [{"id": "72", "href": "https://github.com/ChristopherA/mp-ported-skills/pull/72", "kind": "pr"}]'
transcript shared-actions -work-project "$sid"
check "actions: the #66 run, every shared action ungranted" "pr 72 ungranted: https://github.com/ChristopherA/mp-ported-skills/pull/72
$pushed
command refused ungranted: git push origin HEAD:main 2>&1
command succeeded ungranted: git push -u origin 66-deny-shared-actions-to-background-workers 2>&1 -- push 66-deny-shared-actions-to-background-workers
command failed ungranted: gh pr create --repo ChristopherA/mp-ported-skills --title \"Deny shared actions to background workers\" --body-file \"\$CLAUDE_JOB_DIR/tmp/pr-body.md\" --head 66-deny-shared-actions-to-background-workers --base main 2>&1
command succeeded ungranted: gh pr create --repo ChristopherA/mp-ported-skills --title \"Deny shared actions to background workers\" --body-file /work/config/jobs/76153f47/tmp/pr-body.md --head 66-deny-shared-actions-to-background-workers --base main 2>&1 -- pr 72 created" "$(actions)"

# A script that pushes names no push in its text; the push Claude Code
# recorded on the result still lists it.
job
jq -c 'select(.message.content | any(.id == "toolu_01XdkrXwv1TnYznyvLWKGaRN" or .tool_use_id == "toolu_01XdkrXwv1TnYznyvLWKGaRN"))
    | .message.content |= map(if .type == "tool_use" then .input.command = "sh scripts/ship.sh" else . end)' \
    "$transcripts/shared-actions.jsonl" >"$cfg/projects/-work-project/$sid.jsonl"
check "actions: a push recorded on the result, whatever the command" "$pushed
command succeeded ungranted: sh scripts/ship.sh -- push 66-deny-shared-actions-to-background-workers" "$(actions)"

# gh writes are listed, refused by the hook or not; reads, and a commit message
# that names one, are not.
{
    bash_call w1 'gh issue comment 74 --body "done"'
    bash_call w2 'gh -R o/r pr review 72 --approve' true
    bash_call w3 'cd /work/project && gh issue edit 74 --add-label ready'
    bash_call r1 'gh issue view 74 --json title,body,comments'
    bash_call r2 'gh pr list --state all'
    bash_call r3 'git commit -m "then gh issue close 74"'
} >"$cfg/projects/-work-project/$sid.jsonl"
check "actions: gh writes, refused or not" "$others
command succeeded ungranted: gh issue comment 74 --body \"done\"
command failed ungranted: gh -R o/r pr review 72 --approve
command succeeded ungranted: cd /work/project && gh issue edit 74 --add-label ready" "$(actions)"

# A subagent's calls are in its own transcript beside the worker's.
transcript just-launched -work-project "$sid"
mkdir -p "$cfg/projects/-work-project/$sid/subagents"
jq -c 'select(.message.content | any(.id == "toolu_01U84F8dsqTtkMoD2YxRkZgs" or .tool_use_id == "toolu_01U84F8dsqTtkMoD2YxRkZgs")) | .isSidechain = true' \
    "$transcripts/shared-actions.jsonl" >"$cfg/projects/-work-project/$sid/subagents/agent-a1.jsonl"
check "actions: a subagent's push is listed" "$others
command refused ungranted: git push origin HEAD:main 2>&1" "$(actions)"
# A subagent's push that succeeded makes the branch the worker's.
jq -c 'select(.message.content | any(.id == "toolu_01XdkrXwv1TnYznyvLWKGaRN" or .tool_use_id == "toolu_01XdkrXwv1TnYznyvLWKGaRN"))' \
    "$transcripts/shared-actions.jsonl" >>"$cfg/projects/-work-project/$sid/subagents/agent-a1.jsonl"
check "actions: a subagent's succeeded push is the worker's" "$pushed" "$(actions | grep '^branch')"
command rm -rf "$cfg/projects/-work-project/$sid"

# A multi-line command is listed by its first line.
transcript just-launched -work-project "$sid"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cd /work/project\ngit push"}}]}}' >>"$cfg/projects/-work-project/$sid.jsonl"
check "actions: a call with no result yet, by its first line" "$pushed
command no result ungranted: cd /work/project ..." "$(actions)"

# A commit pushed to the default branch is listed once, by that branch, not
# again by origin/HEAD.
transcript turn-ended -work-project "$sid"
job
main_start=$(git -C "$repo" rev-parse HEAD)
repo_git "$repo" commit -q --allow-empty -m "pushed to main"
repo_git "$repo" push -q origin HEAD:main 2>/dev/null
check "actions: a push to main, not origin/HEAD" "branch origin/main pushed by someone else: holds the worker's commits" \
    "$(actions "$main_start")"

# Whose push a branch is (#98). The #96 run: the hook refused the worker's
# push to main, and the maintainer pushed main from their own terminal. A
# refused or failed push is not the worker's.
{
    bash_call p1 'git push origin main 2>&1; echo "rc=$?"' true
    bash_call p2 'git push origin HEAD:main' true
} >"$cfg/projects/-work-project/$sid.jsonl"
check "actions: a refused push, then the maintainer's" "branch origin/main pushed by someone else: holds the worker's commits
command failed ungranted: git push origin main 2>&1; echo \"rc=\$?\"
command failed ungranted: git push origin HEAD:main" "$(actions "$main_start")"
mine() { # <command> -- the branch line when the worker's one call succeeded
    bash_call p1 "$1" >"$cfg/projects/-work-project/$sid.jsonl"
    actions "$main_start" | grep '^branch'
}
check "actions: a succeeded push naming main is the worker's" "branch origin/main ungranted: holds the worker's commits" \
    "$(mine 'cd /work/project && git push origin main 2>&1 | tail -3')"
check "actions: a refspec's destination names the branch" "branch origin/main ungranted: holds the worker's commits" \
    "$(mine 'git -C /work/project push -u origin +HEAD:refs/heads/main')"
check "actions: git's own options before the subcommand are skipped" "branch origin/main pushed by someone else: holds the worker's commits" \
    "$(mine 'git --git-dir /work/project/.git push origin feature')"
check "actions: a push naming no branch could be any" "branch origin/main ungranted: holds the worker's commits" \
    "$(mine 'git push')"
check "actions: a push to another branch is not this one" "branch origin/main pushed by someone else: holds the worker's commits" \
    "$(mine 'git push origin feature 2>/dev/null')"
check "actions: a push with no result may have landed" "branch origin/main ungranted: holds the worker's commits" \
    "$(printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git push origin main"}}]}}' \
        >"$cfg/projects/-work-project/$sid.jsonl"; actions "$main_start" | grep '^branch')"
# An unreadable transcript clears no one: the branch stays the worker's.
printf 'not json\n' >"$cfg/projects/-work-project/$sid.jsonl"
check "actions: an unreadable transcript leaves the branch the worker's" "branch origin/main ungranted: holds the worker's commits" \
    "$(actions "$main_start" | grep '^branch')"
repo_git "$repo" push -q -f origin "$start:main" 2>/dev/null

# Nothing shared: the worker's commits are only local, and it ran no
# shared command.
repo_git "$repo" commit -q --allow-empty -m "local only"
local_start=$(git -C "$repo" rev-parse HEAD)
repo_git "$repo" commit -q --allow-empty -m "local only 2"
transcript turn-ended -work-project "$sid"
check "actions: nothing shared" "none" "$(actions "$local_start")"

# A source that cannot be read is named, never taken as empty, and a
# report of notes alone does not say none.
command rm -rf "$cfg/projects"
check "actions: no transcript is named" "note no transcript for session $sid under $cfg/projects, so its commands were not read" \
    "$(actions "$local_start")"
transcript turn-ended -work-project "$sid"
printf 'not json\n' >>"$cfg/projects/-work-project/$sid.jsonl"
check "actions: an unreadable transcript is named" "note transcript $cfg/projects/-work-project/$sid.jsonl could not be read, so its commands were not read" \
    "$(actions "$local_start")"
job 'del(.sessionId)'
check "actions: a job with no session is named" "note job state $cfg/jobs/c2a368ee/state.json names no session, so its commands were not read" \
    "$(actions "$local_start")"
printf 'not json\n' >"$cfg/jobs/c2a368ee/state.json"
check "actions: an unreadable job state is named" "$pushed
note job state $cfg/jobs/c2a368ee/state.json could not be read, so its PRs, issues and commands were not read" "$(actions)"
command rm -rf "$cfg/jobs"
check "actions: no job state is named" "$pushed
note no job state for c2a368ee under $cfg/jobs, so its PRs, issues and commands were not read" "$(actions)"
command rm -rf "$cfg/jobs" "$cfg/projects"

sh "$scripts/actions.sh" --dir "$repo" --start "$start" </dev/null >/dev/null 2>&1
check "actions: --id is required" "1" "$?"
sh "$scripts/actions.sh" --id c2a368ee --start "$start" </dev/null >/dev/null 2>&1
check "actions: --dir is required" "1" "$?"
sh "$scripts/actions.sh" --id c2a368ee --dir "$repo" </dev/null >/dev/null 2>&1
check "actions: --start is required" "1" "$?"
sh "$scripts/actions.sh" --id c2a368ee --dir "$repo" --start nosuchrev </dev/null >/dev/null 2>&1
check "actions: an unknown --start exits 1" "1" "$?"
sh "$scripts/actions.sh" --id c2a368ee --dir "$work/missing" --start "$start" </dev/null >/dev/null 2>&1
check "actions: a missing folder exits 1" "1" "$?"
( unset CLAUDE_CONFIG_DIR; sh "$scripts/actions.sh" --id c2a368ee --dir "$repo" --start "$start" </dev/null >/dev/null 2>&1 )
check "actions: config dir required" "1" "$?"

# A standing grant on the committed default branch cites itself on the
# matching branch and command lines, which read granted instead of
# ungranted (#58); a fresh repo and remote for each case, so the earlier
# checks above stay exact and the two grant cases do not share history.
new_grant_repo() { # <folder var name> <grant file content>: a repo with the
    # grant committed and pushed to origin/main before any worker commit,
    # then one worker commit pushed only to a topic branch, never main.
    eval "$1=\"\$work/grant-repo-$grant_n\""
    eval "grepo=\$$1"
    grant_n=$((grant_n + 1))
    gremote="$grepo.git"
    git init -q --bare "$gremote"
    git init -q -b main "$grepo"
    repo_git "$grepo" commit -q --allow-empty -m start
    repo_git "$grepo" remote add origin "$gremote"
    repo_git "$grepo" push -q origin main 2>/dev/null
    git -C "$grepo" remote set-head origin main
    mkdir -p "$grepo/docs/agents"
    printf '%s' "$2" >"$grepo/docs/agents/supervision.md"
    repo_git "$grepo" add docs/agents/supervision.md
    repo_git "$grepo" commit -q -m "grant"
    repo_git "$grepo" push -q origin main 2>/dev/null
    gstart=$(git -C "$grepo" rev-parse HEAD)
    repo_git "$grepo" commit -q --allow-empty -m "worker's commit"
    repo_git "$grepo" push -q origin HEAD:66-deny-shared-actions-to-background-workers 2>/dev/null
}
grant_n=1

command rm -rf "$cfg/jobs"
mkdir -p "$cfg/jobs/c2a368ee"
jq '.children = []' "$fixtures/job-state.json" >"$cfg/jobs/c2a368ee/state.json"
transcript shared-actions -work-project "$sid"

new_grant_repo grepo1 '## Grants

- push: release branches only
'
check "actions: a granted push is cited, not ungranted" \
    "branch origin/66-deny-shared-actions-to-background-workers granted (push: release branches only): holds the worker's commits
command refused granted (push: release branches only): git push origin HEAD:main 2>&1
command succeeded granted (push: release branches only): git push -u origin 66-deny-shared-actions-to-background-workers 2>&1 -- push 66-deny-shared-actions-to-background-workers
command failed ungranted: gh pr create --repo ChristopherA/mp-ported-skills --title \"Deny shared actions to background workers\" --body-file \"\$CLAUDE_JOB_DIR/tmp/pr-body.md\" --head 66-deny-shared-actions-to-background-workers --base main 2>&1
command succeeded ungranted: gh pr create --repo ChristopherA/mp-ported-skills --title \"Deny shared actions to background workers\" --body-file /work/config/jobs/76153f47/tmp/pr-body.md --head 66-deny-shared-actions-to-background-workers --base main 2>&1 -- pr 72 created" \
    "$(sh "$scripts/actions.sh" --id c2a368ee --dir "$grepo1" --start "$gstart" </dev/null)"

# A grant for a different action (pr-create) does not cover the push.
new_grant_repo grepo2 '## Grants

- pr-create
'
check "actions: an unmatched grant leaves the push ungranted" \
    "branch origin/66-deny-shared-actions-to-background-workers ungranted: holds the worker's commits" \
    "$(sh "$scripts/actions.sh" --id c2a368ee --dir "$grepo2" --start "$gstart" </dev/null | grep '^branch')"

# A grant present only on the working tree (never pushed to origin/main) is
# reported as ignored, not silently treated as absent (#58).
printf '## Grants\n\n- push\n' >"$grepo2/docs/agents/supervision.md"
check "actions: a working-tree-only grant is reported, not silent" \
    "note docs/agents/supervision.md grants push on the working tree or current branch, not on the committed origin/main; ignored" \
    "$(sh "$scripts/actions.sh" --id c2a368ee --dir "$grepo2" --start "$gstart" </dev/null | grep '^note docs/agents/supervision.md grants push' | sort -u)"
repo_git "$grepo2" checkout -q -- docs/agents/supervision.md

# A worker's comment and new ticket (#110) cite their own grants, by gh
# issue or the gh api write that does the same; with no grant, ungranted.
{
    bash_call c1 'gh issue comment 104 --body-file "$CLAUDE_JOB_DIR/tmp/c.md"'
    bash_call c2 'gh issue create --title "x" --body-file b.md --label ready-for-agent'
    bash_call c3 'gh api repos/o/r/issues/104/comments -f body=x'
    bash_call c4 'gh api repos/o/r/issues -f title=x'
    bash_call c5 'gh issue create --title "a comment to close"'
    bash_call c6 'gh issue comment 104 --edit-last --body x'
    bash_call c7 'gh issue comment 104 --delete-last --yes'
    bash_call c8 'gh api -X PATCH repos/o/r/issues/comments/99 -f body=x'
    bash_call c9 "gh api graphql -f query='mutation { addComment(input: {subjectId: 1, body: 2}) { clientMutationId } }'"
    bash_call c10 "gh api graphql -f query='mutation { createIssue(input: {repositoryId: 1, title: 2}) { issue { number } } }'"
    bash_call c11 'gh issue -R o/r comment 104 --body x'
    bash_call c12 'gh issue -R o/r comment 104 --edit-last'
    bash_call c13 'gh issue create --title y --repo=o/r'
    bash_call c14 'gh issue -R o/r view 104'
} >"$cfg/projects/-work-project/$sid.jsonl"
new_grant_repo grepo3 '## Grants

- issue-comment: findings for open tickets
- issue-create
'
check "actions: a granted comment and issue create are cited, an edit, delete or mutation is not" \
    "command succeeded granted (issue-comment: findings for open tickets): gh issue comment 104 --body-file \"\$CLAUDE_JOB_DIR/tmp/c.md\"
command succeeded granted (issue-create): gh issue create --title \"x\" --body-file b.md --label ready-for-agent
command succeeded granted (issue-comment: findings for open tickets): gh api repos/o/r/issues/104/comments -f body=x
command succeeded granted (issue-create): gh api repos/o/r/issues -f title=x
command succeeded granted (issue-create): gh issue create --title \"a comment to close\"
command succeeded ungranted: gh issue comment 104 --edit-last --body x
command succeeded ungranted: gh issue comment 104 --delete-last --yes
command succeeded ungranted: gh api -X PATCH repos/o/r/issues/comments/99 -f body=x
command succeeded ungranted: gh api graphql -f query='mutation { addComment(input: {subjectId: 1, body: 2}) { clientMutationId } }'
command succeeded ungranted: gh api graphql -f query='mutation { createIssue(input: {repositoryId: 1, title: 2}) { issue { number } } }'
command succeeded granted (issue-comment: findings for open tickets): gh issue -R o/r comment 104 --body x
command succeeded ungranted: gh issue -R o/r comment 104 --edit-last
command succeeded granted (issue-create): gh issue create --title y --repo=o/r" \
    "$(sh "$scripts/actions.sh" --id c2a368ee --dir "$grepo3" --start "$gstart" </dev/null | grep '^command')"
new_grant_repo grepo4 '## Grants

- issue-close
'
check "actions: an ungranted comment and issue create" \
    "command succeeded ungranted: gh issue comment 104 --body-file \"\$CLAUDE_JOB_DIR/tmp/c.md\"
command succeeded ungranted: gh issue create --title \"x\" --body-file b.md --label ready-for-agent
command succeeded ungranted: gh api repos/o/r/issues/104/comments -f body=x
command succeeded ungranted: gh api repos/o/r/issues -f title=x
command succeeded ungranted: gh issue create --title \"a comment to close\"
command succeeded ungranted: gh issue comment 104 --edit-last --body x
command succeeded ungranted: gh issue comment 104 --delete-last --yes
command succeeded ungranted: gh api -X PATCH repos/o/r/issues/comments/99 -f body=x
command succeeded ungranted: gh api graphql -f query='mutation { addComment(input: {subjectId: 1, body: 2}) { clientMutationId } }'
command succeeded ungranted: gh api graphql -f query='mutation { createIssue(input: {repositoryId: 1, title: 2}) { issue { number } } }'
command succeeded ungranted: gh issue -R o/r comment 104 --body x
command succeeded ungranted: gh issue -R o/r comment 104 --edit-last
command succeeded ungranted: gh issue create --title y --repo=o/r" \
    "$(sh "$scripts/actions.sh" --id c2a368ee --dir "$grepo4" --start "$gstart" </dev/null | grep '^command')"

echo "supervise: $pass passed, $fail failed"
[ "$fail" = 0 ]
