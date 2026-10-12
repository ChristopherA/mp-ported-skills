#!/bin/sh
# supervise-watch-detail.test.sh -- tests for watch.sh --detail and
# --capture, which cut a watch's output to a verdict and write the full
# result and the worker's last message to a file (#192).
#
# Runs watch.sh --file on the recorded `claude agents --json --all` fixture
# done.json, with its worker's cwd set to a scratch repo, and the
# turn-ended transcript fixture with its last text filled in, installed
# under the config dir's projects/. A background Bash result carrying
# toolUseResult.backgroundTaskId, with no <task-notification> for it, stands
# for a command still running at the turn end. Touches nothing outside its
# own mktemp directory.
#
# Usage: sh tests/supervise-watch-detail.test.sh

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
unset CLAUDE_CODE_SESSION_ATTENDED MP_SMART_ZONE_K CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
cfg="$work/config"
mkdir -p "$cfg"
export CLAUDE_CONFIG_DIR="$cfg"

repo="$work/project"
mkdir -p "$repo"
git -C "$repo" init -q -b main
commit() { git -C "$repo" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
commit start
sh "$scripts/watch.sh" --dir "$repo" --snapshot </dev/null >"$work/snap"
start=$(git -C "$repo" rev-parse --short=7 HEAD)
agents() { # <state> -- done.json with the worker in that state, its cwd the scratch repo
    jq --arg d "$repo" --arg s "$1" 'map(if .id == "9121ff49" then .cwd = $d | .state = $s else . end)' \
        "$fixtures/done.json" >"$work/$1.json"
}
agents done
sid=9121ff49-5e25-43f0-bf48-307db0776c36

transcript() { # <last text> [jq filter on each row] -- the worker's transcript
    dir="$cfg/projects/-project"
    command rm -rf "$cfg/projects"; mkdir -p "$dir"
    jq -c --arg t "$1" 'if .type == "assistant" and .message.content == [{"type": "text"}]
        then .message.content[0].text = $t else . end' "$transcripts/turn-ended.jsonl" >"$dir/$sid.jsonl"
    [ $# -lt 2 ] || { jq -c "$2" "$dir/$sid.jsonl" >"$dir/x" && command mv "$dir/x" "$dir/$sid.jsonl"; }
}
detail="$work/detail.txt"
watch_as() { # <state> [option]... -- watch.sh --detail on that state
    s=$1; shift
    sh "$scripts/watch.sh" --id 9121ff49 --dir "$repo" --since "$work/snap" --file "$work/$s.json" \
        --detail "$detail" "$@" </dev/null 2>&1
}
watch() { watch_as done "$@"; }

# --- without --detail, nothing changes ---------------------------------------
transcript "Built it."
check "no detail: the report as before" "done
cwd $repo" "$(sh "$scripts/watch.sh" --id 9121ff49 --dir "$repo" --since "$work/snap" --file "$work/done.json" </dev/null)"
check "no detail: --capture changes nothing" "done
cwd $repo" "$(sh "$scripts/watch.sh" --id 9121ff49 --dir "$repo" --since "$work/snap" --capture --file "$work/done.json" </dev/null)"

# --- a done with no new commits prints the message ---------------------------
check "no commits: unsettled, with the message" "done
cwd $repo
unsettled: no new commits since $start
detail $detail
message:
Built it." "$(watch)"
check "detail file: the report and the whole message" "done
cwd $repo
message:
Built it." "$(command cat "$detail")"

# --- a settled done prints no message ----------------------------------------
commit "Add the thing"
check "settled: state, cwd and detail only" "done
cwd $repo
detail $detail" "$(watch)"
check "settled: the detail file still holds the message" "Built it." "$(sed -n '/^message:$/,$p' "$detail" | sed 1d)"

# The note that claude agents still said working is left out of a settled done.
agents working
check "settled: no note from the list" "done
cwd $repo
detail $detail" "$(watch_as working)"

# --- a background command still running at the turn end ----------------------
started='if .type == "user" and (.message.content | type) == "array" and .message.content[0].type == "tool_result"
    then .toolUseResult = {"backgroundTaskId": "bash-7"} else . end'
transcript "Committed; the signing runs in the background." "$started"
check "running: unsettled, with the message" "done
cwd $repo
unsettled: background task bash-7 still running at the turn end
detail $detail
message:
Committed; the signing runs in the background." "$(watch)"
# Once its notification arrives, it no longer runs.
transcript "Committed; the signing runs in the background." "$started"'
    | if .type == "last-prompt" then {"type": "queue-operation", "content": "<task-notification><task-id>bash-7</task-id></task-notification>"} else . end'
check "ended: settled again" "done
cwd $repo
detail $detail" "$(watch)"

# --- a turn that ended on a question -----------------------------------------
transcript "Built it. Should the flag default to on?"
check "question: unsettled, with the message" "done
cwd $repo
unsettled: its last message asks a question
detail $detail
message:
Built it. Should the flag default to on?" "$(watch)"

# --- a long message is cut ---------------------------------------------------
# A question, so the message is printed.
transcript "$(printf '%03099d?' 0)"
out=$(watch)
check "cut: 3000 characters printed" "3000" \
    "$(printf '%s\n' "$out" | sed -n '/^message:$/{n;p;}' | tr -d '\n' | wc -c | tr -d ' ')"
check "cut: says so" "(cut at 3000 characters; the whole message is in the detail file)" \
    "$(printf '%s\n' "$out" | tail -n 1)"
check "cut: the detail file holds it whole" "3100" \
    "$(sed -n '/^message:$/{n;p;}' "$detail" | tr -d '\n' | wc -c | tr -d ' ')"

# --- a capture's done always prints the message ------------------------------
transcript "Capture: two notes posted on #192."
check "capture: a settled done still prints the message" "done
cwd $repo
detail $detail
message:
Capture: two notes posted on #192." "$(watch --capture)"

# --- other states keep their lines --------------------------------------------
transcript "Committed.

\`Waiting on: the maintainer's push\`"
check "blocked input needed: its lines, no message" "blocked input needed
cwd $repo
needs the maintainer's push
detail $detail" "$(watch)"
check "capture: a blocked state prints the message" "blocked input needed
cwd $repo
needs the maintainer's push
detail $detail
message:
Committed.

\`Waiting on: the maintainer's push\`" "$(watch --capture)"
agents blocked
transcript "Which name should the option take?"
check "blocked question with no needs: prints the message" "blocked question
cwd $repo
detail $detail
message:
Which name should the option take?" "$(watch_as blocked)"

# A snapshot with no head line counts no commits, and says why.
grep -v '^head ' "$work/snap" >"$work/snap-nohead"
check "no head line: unsettled, saying why" "unsettled: the snapshot holds no head line, so its commits are not counted" \
    "$(sh "$scripts/watch.sh" --id 9121ff49 --dir "$repo" --since "$work/snap-nohead" --file "$work/done.json" \
        --detail "$detail" </dev/null 2>&1 | grep '^unsettled')"

# A detail file that cannot be written leaves the report whole, with a note.
check "unwritable detail: the report and a note" "blocked question
cwd $repo
note the detail file $work/none/d.txt was not written" \
    "$(sh "$scripts/watch.sh" --id 9121ff49 --dir "$repo" --since "$work/snap" --file "$work/blocked.json" \
        --detail "$work/none/d.txt" </dev/null 2>&1)"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
