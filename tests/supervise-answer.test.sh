#!/bin/sh
# supervise-answer.test.sh -- tests for the supervise skill's answer.sh.
#
# Writes a worker transcript under a scratch config dir for each case, with
# the row shapes last-message.sh reads, and a fake `claude` on PATH that
# prints the agents-json/done.json fixture naming the worker's sessionId.
# Grants come from a scratch repo whose origin holds
# docs/agents/supervision.md. Touches nothing outside its own mktemp
# directory.
#
# Usage: sh tests/supervise-answer.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/supervise/scripts/answer.sh"
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

# Every variable the scripts read, set or unset here, so the result does not
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
grant_push() { # commit a push grant and push it to origin
    mkdir -p "$repo/docs/agents"
    printf '# Supervision\n\n## Grants\n\n- push: to main, after the worker'\''s own tests pass\n' \
        >"$repo/docs/agents/supervision.md"
    repo_git "$repo" add docs/agents/supervision.md
    repo_git "$repo" commit -q -m "Grant push"
    repo_git "$repo" push -q origin main 2>/dev/null
}

# --- the worker ------------------------------------------------------------
sid=9121ff49-5e25-43f0-bf48-307db0776c36
folder="$cfg/projects/-work-project"
prompt() { # <text> -- a user row
    jq -cn --arg s "$1" '{type: "user", message: {role: "user", content: $s}}'
}
said() { # <message id> <text> -- an assistant text row
    jq -cn --arg m "$1" --arg s "$2" '{type: "assistant", message: {id: $m, role: "assistant", content: [{type: "text", text: $s}]}}'
}
asked() { # <message id> <questions json> -- an assistant AskUserQuestion row
    jq -cn --arg m "$1" --argjson q "$2" '{type: "assistant", message: {id: $m, role: "assistant",
        content: [{type: "tool_use", id: "t1", name: "AskUserQuestion", input: {questions: $q}}]}}'
}
transcript() { # rows on stdin become the worker's transcript, after its launch prompt
    command rm -rf "$cfg/projects"
    mkdir -p "$folder"
    { prompt '<command-name>/mattpocock-skills:implement</command-name>'; command cat; } >"$folder/$sid.jsonl"
}
last_says() { # <text> -- a transcript whose last message is that text
    { said m1 'Reading the ticket.'; said m2 "$1"; } | transcript
}

run() { # [args...] -- answer.sh for worker 9121ff49 on ticket 90 in $repo
    (
        PATH="$work/bin:$PATH"
        FAKE_AGENTS=${agents_file-$agents/done.json}
        export FAKE_AGENTS
        sh "$script" --id 9121ff49 --dir "$repo" --ticket 90 --state "${state:-blocked question}" "$@" \
            >"$work/out" 2>"$work/err" </dev/null
        echo $? >"$work/rc"
    )
}
run_as() { # <state> [args...] -- run, with watch.sh having read that state
    (state=$1; shift; run "$@")
}
out() { command cat "$work/out"; }
err() { command cat "$work/err"; }
rc() { command cat "$work/rc"; }
answer_for() { # <question> <body> -- the answer line answer.sh should print
    printf 'answer [supervisor answer to "%s"] %s' "$1" "$2"
}
confirm="Yes, proceed with #90 as the ticket and its latest Agent Brief describe. This is /supervise's routine answer: it confirms the launched ticket and approves nothing beyond it, so if your plan departs from the ticket, stop and say so."

# --- confirming the launched ticket ----------------------------------------
last_says 'I have read #90 and its brief, and the plan is to add answer.sh.

Proceed with #90?'
run
check "ticket: exit 0" 0 "$(rc)"
check "ticket: the answer" "question Proceed with #90?
rule ticket
$(answer_for 'Proceed with #90?' "$confirm")" "$(out)"

last_says 'Plan above. **Shall I go ahead and start implementing ticket #90 now?**'
run
check "ticket: a longer form" "0 question Shall I go ahead and start implementing ticket #90 now?" \
    "$(rc) $(sed -n 1p "$work/out")"

# A pending AskUserQuestion with one question is read like text.
{ said m1 'Reading the ticket.'; asked m2 '[{"question": "Proceed with #90?", "options": []}]'; } | transcript
run_as 'blocked input needed'
check "ticket: an AskUserQuestion" "0 rule ticket" "$(rc) $(sed -n 2p "$work/out")"

# --- questions it leaves to the maintainer ---------------------------------
not_routine() { # <name> <expected why>
    check "$1: exit 2" 2 "$(rc)"
    check "$1: why" "not routine: $2" "$(sed -n '$p' "$work/out")"
    check "$1: no answer" "" "$(grep '^answer ' "$work/out")"
}

last_says 'Proceed with #91?'
run
not_routine "another ticket" "it names a ticket other than #90"

last_says 'Proceed with #90, or should I split it first?'
run
not_routine "a choice" "it offers a choice"

last_says 'The brief names the flag --force, which CONTEXT.md avoids. Should I call it --overwrite instead?'
run
not_routine "a spec question" "it is not one the policy decides: only confirming #90 or a granted shared action is"
check "a spec question: the question" "question Should I call it --overwrite instead?" "$(sed -n 1p "$work/out")"

last_says 'Proceed with #90 using the approach from the comment instead of the brief?'
run
not_routine "a ticket confirm that changes the spec" \
    "it is not one the policy decides: only confirming #90 or a granted shared action is"

last_says 'Is the brief current? Proceed with #90?'
run
not_routine "two questions" "its last message asks more than one question"

last_says 'Proceed with #90? I will wait.'
run
not_routine "text after the question" "its last message does not end on a question"

{ said m1 'Reading the ticket.'; asked m2 '[{"question": "Proceed with #90?"}, {"question": "Push after?"}]'; } | transcript
run_as 'blocked input needed'
not_routine "an AskUserQuestion with two questions" "it asks 2 questions at once"

last_says 'Proceed with #90?'
run_as 'blocked permission prompt'
not_routine "a permission prompt" "the worker is blocked permission prompt, not waiting on a question"

# A question answered once and asked again goes to the maintainer.
{
    said m1 'Proceed with #90?'
    prompt "[supervisor answer to \"Proceed with #90?\"] $confirm"
    said m2 'Proceed with #90?'
} | transcript
run
not_routine "asked again" "it was answered once already and the worker asked again"

# --- shared actions --------------------------------------------------------
last_says 'Tests pass and /code-review is clean.

Waiting on: git push origin main'
run_as 'blocked input needed'
not_routine "a push no grant covers" "no standing grant covers push"
check "a push no grant covers: the question" "question Waiting on: git push origin main" "$(sed -n 1p "$work/out")"

last_says 'Shall I push to origin main?'
run
not_routine "a push question, no grant" "no standing grant covers push"

grant_push
grant_answer="Yes, go ahead with the push. The Project's standing grant covers it (\"push: to main, after the worker's own tests pass\"), so take it as the grant allows, without asking again."
last_says 'Tests pass and /code-review is clean.

Waiting on: `git push origin main`'
run_as 'blocked input needed'
check "a granted push: exit 0" 0 "$(rc)"
check "a granted push: the answer" "question Waiting on: git push origin main
rule grant push: to main, after the worker's own tests pass
$(answer_for 'Waiting on: git push origin main' "$grant_answer")" "$(out)"

last_says 'Shall I push to origin main?'
run
check "a granted push asked in text" "0 rule grant push: to main, after the worker's own tests pass" \
    "$(rc) $(sed -n 2p "$work/out")"

last_says 'Shall I push to main and close #90?'
run
not_routine "two actions" "it asks about more than one shared action"

last_says 'Shall I close #90?'
run
not_routine "an action granted for push only" "no standing grant covers issue-close"

last_says 'Waiting on: git push origin main && gh pr merge 1'
run_as 'blocked input needed'
not_routine "a Waiting on: line with two commands" "it waits on more than one command"

# A period inside the question does not cut it short.
last_says 'Tests pass. Shall I push v0.9 to main?'
run
check "a period inside the question" "0 question Shall I push v0.9 to main?" "$(rc) $(sed -n 1p "$work/out")"

# A grant that cannot be read is named, not taken as no grant.
last_says 'Shall I push to main?'
(
    repo=$work/bin
    run
)
not_routine "grant.sh failed" "grant.sh failed: Error: not a git checkout: $work/bin"

last_says 'Waiting on: rm -rf build'
run_as 'blocked input needed'
not_routine "a Waiting on: line no grant can cover" "it waits on an action no grant can cover"

# --- errors ----------------------------------------------------------------
last_says 'Proceed with #90?'
(agents_file=''; run)
check "no claude agents: exit 1" 1 "$(rc)"
check "no claude agents: nothing on stdout" "" "$(out)"
check "no claude agents: named" "Error: claude agents --json --all could not be read" "$(err)"

command rm -rf "$cfg/projects"
run
check "no transcript: exit 1" 1 "$(rc)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
