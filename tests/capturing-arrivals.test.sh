#!/bin/sh
# capturing-arrivals.test.sh -- tests for the capturing skill's arrivals.sh
# (#93): the commits on the current branch that another session made while
# this one worked.
#
# Builds a scratch repo whose commits carry set committer dates, and a
# scratch config dir holding the session's transcript and a subagent's,
# with only the row shapes the script reads: a first row's timestamp and
# the toolUseResult.gitOperation.commit rows Claude Code writes for a commit
# a Bash call made. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/capturing-arrivals.test.sh

set -u
unset CLAUDE_CODE_SESSION_ATTENDED

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/capturing/scripts/arrivals.sh"
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

cfg="$work/config"
export CLAUDE_CONFIG_DIR="$cfg"
sid=9a1b2c3d-0000-4000-8000-000000000093

commit_at() { # <folder> <ISO date> <message> -- an empty commit dated then
    (GIT_COMMITTER_DATE=$2 && GIT_AUTHOR_DATE=$2 && export GIT_COMMITTER_DATE GIT_AUTHOR_DATE &&
        git -C "$1" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$3")
    git -C "$1" rev-parse --short HEAD
}
row() { # <time> -- a user row with no git operation
    jq -cn --arg t "$1" '{type: "user", timestamp: $t, message: {role: "user", content: "<prompt>"}}'
}
committed() { # <time> <sha> -- the tool result row of a commit a Bash call made
    jq -cn --arg t "$1" --arg s "$2" '{type: "user", timestamp: $t, message: {role: "user",
        content: [{type: "tool_result", tool_use_id: "b1", content: "<output>"}]},
        toolUseResult: {stdout: "", gitOperation: {commit: {sha: $s, kind: "created", branch: "main"}}}}'
}

repo="$work/repo"
git init -q -b main "$repo"
commit_at "$repo" 2026-09-29T05:00:00Z "before the session" >/dev/null
own=$(commit_at "$repo" 2026-09-29T06:10:00Z "this session's commit")
sub=$(commit_at "$repo" 2026-09-29T06:15:00Z "its subagent's commit")
other=$(commit_at "$repo" 2026-09-29T06:20:00Z "another session's commit")

dir="$cfg/projects/-work-repo"
mkdir -p "$dir/$sid/subagents"
{
    row 2026-09-29T06:00:00.000Z
    committed 2026-09-29T06:10:01.000Z "$own"
} >"$dir/$sid.jsonl"
committed 2026-09-29T06:15:01.000Z "$sub" >"$dir/$sid/subagents/agent-a1.jsonl"

run() { sh "$script" "$@" </dev/null 2>&1; }

check "arrivals: only the commit no transcript recorded" \
    "arrival $other another session's commit" "$(run --dir "$repo" --session "$sid")"

# With the other session's commit recorded too, nothing arrived.
committed 2026-09-29T06:20:01.000Z "$other" >>"$dir/$sid.jsonl"
check "arrivals: none when every commit is recorded" "arrivals: none" "$(run --dir "$repo" --session "$sid")"

# A full sha in the record matches the short one git prints.
full=$(git -C "$repo" rev-parse "$other")
{
    row 2026-09-29T06:00:00.000Z
    committed 2026-09-29T06:10:01.000Z "$own"
    committed 2026-09-29T06:20:01.000Z "$full"
} >"$dir/$sid.jsonl"
check "arrivals: a full sha in the record counts" "arrivals: none" "$(run --dir "$repo" --session "$sid")"

# A commit made with -q prints no `[main <sha>]` line, so Claude Code
# records no gitOperation for it. Its subject in a command the session ran
# (quoted the shell's way) or a file it wrote still marks it as its own.
quiet=$(commit_at "$repo" 2026-09-29T06:25:00Z "Say what the session's quiet commit does")
written=$(commit_at "$repo" 2026-09-29T06:26:00Z "A message written to a file")
ran() { # <time> <tool> <input json> -- an assistant row calling a tool
    jq -cn --arg t "$1" --arg n "$2" --argjson i "$3" '{type: "assistant", timestamp: $t,
        message: {role: "assistant", content: [{type: "tool_use", id: "b2", name: $n, input: $i}]}}'
}
{
    row 2026-09-29T06:00:00.000Z
    committed 2026-09-29T06:10:01.000Z "$own"
    ran 2026-09-29T06:24:59.000Z Bash "$(jq -cn --arg c "git commit -q -m 'Say what the session'\"'\"'s quiet commit does'" '{command: $c}')"
    ran 2026-09-29T06:25:59.000Z Write '{"file_path":"/tmp/m.txt","content":"A message written to a file\n\nIts body."}'
} >"$dir/$sid.jsonl"
check "arrivals: a quiet commit whose subject the session wrote is its own" \
    "arrival $other another session's commit" "$(run --dir "$repo" --session "$sid")"

# Only a commit command, or a file whose first line is the subject, counts:
# another session's subject quoted in a note or another command is still an
# arrival, and so is a bad transcript line, which is skipped, not the end.
{
    row 2026-09-29T06:00:00.000Z
    committed 2026-09-29T06:10:01.000Z "$own"
    ran 2026-09-29T06:24:59.000Z Bash "$(jq -cn --arg c "git commit -q -m 'Say what the session'\"'\"'s quiet commit does'" '{command: $c}')"
    ran 2026-09-29T06:25:59.000Z Write '{"file_path":"/tmp/m.txt","content":"A message written to a file\n\nIts body."}'
    echo '{"type": "assistant", "trunc'
    ran 2026-09-29T06:30:00.000Z Write '{"file_path":"/tmp/n.md","content":"Seen: another session'"'"'s commit, by the remote one."}'
    ran 2026-09-29T06:30:01.000Z Bash '{"command":"git log --grep \"another session'"'"'s commit\""}'
    committed 2026-09-29T06:30:02.000Z "$sub"
} >"$dir/$sid.jsonl"
command rm -f "$dir/$sid/subagents/agent-a1.jsonl"
check "arrivals: a subject quoted elsewhere is still an arrival; a bad line is skipped" \
    "arrival $other another session's commit" "$(run --dir "$repo" --session "$sid")"
committed 2026-09-29T06:15:01.000Z "$sub" >"$dir/$sid/subagents/agent-a1.jsonl"

# A session that began after the last commit: no commit to read at all.
row 2026-09-29T07:00:00.000Z >"$dir/$sid.jsonl"
check "arrivals: none when no commit is that new" "arrivals: none" "$(run --dir "$repo" --session "$sid")"

# No transcript: said so, nothing listed, no start time guessed.
check "arrivals: no transcript, said and nothing listed" \
    "arrivals: no transcript for session 0000, so commits other sessions made were not listed" \
    "$(run --dir "$repo" --session 0000)"
check "arrivals: no session id, said and nothing listed" \
    "arrivals: no transcript for session (none given), so commits other sessions made were not listed" \
    "$(run --dir "$repo" --session '')"

# A transcript whose rows carry no time gives no start.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"<prompt>"}}' >"$dir/$sid.jsonl"
check "arrivals: a transcript with no time, said and nothing listed" \
    "arrivals: transcript $dir/$sid.jsonl holds no start time, so commits other sessions made were not listed" \
    "$(run --dir "$repo" --session "$sid")"

# Usage errors exit 1.
sh "$script" --dir "$work/nowhere" --session "$sid" </dev/null >/dev/null 2>&1
check "arrivals: a folder that is no repo exits 1" 1 "$?"
sh "$script" --bogus </dev/null >/dev/null 2>&1
check "arrivals: an unknown option exits 1" 1 "$?"

printf 'capturing-arrivals: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
