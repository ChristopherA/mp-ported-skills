#!/bin/sh
# arrivals.sh -- the commits on the current branch that this session did
# not make, since it began (#93). Capturing's move 5 runs it before `git
# status`, which sees only uncommitted changes: when two sessions work in one
# repo, a commit the other one made never shows up there.
#
# Git cannot tell sessions apart, since every session commits as the same
# author, so the session's transcript decides both ends. It began at the
# first row's timestamp in its main transcript, and it made the commits its
# transcript recorded: the toolUseResult.gitOperation.commit rows Claude
# Code writes for a commit a Bash call made, in the main transcript and its
# subagents' (supervise's transcript.sh finds them, wherever a worktree
# moved them). Claude Code writes that row from the `[<branch> <sha>]` line
# git commit prints, so a commit made with -q has none; a commit whose
# subject is in the text the session wrote into its tool calls counts as
# its own as well. A commit on the current branch with a committer date at
# or after the start, made by neither, is an arrival. With no transcript, or none
# with a start time, it says so and lists nothing: a guessed start would
# list this session's own commits as arrivals, or miss the other session's.
#
# Only the current branch's local history is read: not other branches, and
# not commits fetched from the remote.
#
# Usage:
#   arrivals.sh --session ID [--dir DIR]
#
# ID is the session's id (capturing passes ${CLAUDE_SESSION_ID}). DIR
# defaults to the working directory. Reads CLAUDE_CONFIG_DIR.
#
# Prints one line per arrival, oldest first:
#   arrival <short sha> <subject>
# or one of:
#   arrivals: none
#   arrivals: no transcript for session <id>, so commits other sessions made were not listed
#   arrivals: transcript <path> holds no start time, so commits other sessions made were not listed
#
# Exits 0 for all of these, and 1 on a usage error or when DIR is no git
# repo.

set -u

SESSION=""
SESSION_SET=""
DIR="."
need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$@"; SESSION="$2"; SESSION_SET=1; shift 2 ;;
        --dir)     need_value "$@"; DIR="$2"; shift 2 ;;
        --help)
            printf 'Usage: arrivals.sh --session ID [--dir DIR]\n'
            printf 'Prints the commits on the current branch this session did not make.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$SESSION_SET" ] || fail "--session is required"
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "$DIR is no git repo"

: "${CLAUDE_CONFIG_DIR:=$HOME/.claude}"
. "$(dirname -- "$0")/../../supervise/scripts/transcript.sh"

unlisted="so commits other sessions made were not listed"
if ! transcript=$(transcript_of "$SESSION"); then
    printf 'arrivals: no transcript for session %s, %s\n' "${SESSION:-(none given)}" "$unlisted"
    exit 0
fi
start=$(jq -r 'select(type == "object") | .timestamp // empty' "$transcript" 2>/dev/null | head -n 1)
if [ -z "$start" ]; then
    printf 'arrivals: transcript %s holds no start time, %s\n' "$transcript" "$unlisted"
    exit 0
fi

# The session's transcripts: the main one and its subagents'.
subagents=$(transcript_subagents_dir "$transcript")
transcripts() {
    printf '%s\n' "$transcript"
    [ -d "$subagents" ] || return 0
    for f in "$subagents"/*.jsonl; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/arrivals.XXXXXX") || fail "no temp folder"
trap 'rm -rf "$tmp"' EXIT
# The shas they recorded, one a line. Claude Code records a commit from the
# `[<branch> <sha>]` line git commit prints, so a commit made with -q has
# none; for those, the text the session wrote into its tool calls (commands,
# files, edits), with quotes and backslashes taken out, so a subject quoted
# the shell's way still matches. A commit whose subject is in that text is
# the session's too.
transcripts | while IFS= read -r f; do
    jq -r 'select(type == "object") | .toolUseResult | objects | .gitOperation | objects
           | .commit | objects | .sha // empty' "$f" 2>/dev/null
done >"$tmp/shas"
transcripts | while IFS= read -r f; do
    jq -r 'select(type == "object" and .type == "assistant") | .message.content[]? | objects
           | select(.type == "tool_use") | .input | .. | strings
           | gsub("[\"'"'"'\\\\]"; "")' "$f" 2>/dev/null
done >"$tmp/written"

# A branch with no commit yet has nothing to list.
if ! git -C "$DIR" rev-parse --verify -q HEAD >/dev/null; then
    echo "arrivals: none"
    exit 0
fi
log=$(git -C "$DIR" log --reverse --since="$start" --format='%H%x09%h%x09%ct%x09%s' HEAD) ||
    fail "git log failed in $DIR"

# -n with inputs: with no commit since the start, the log is empty, and jq -R
# with no -n prints nothing for empty input.
printf '%s' "$log" | jq -n -r -R --arg start "$start" --rawfile rec "$tmp/shas" --rawfile written "$tmp/written" '
    ($start | sub("\\.[0-9]+"; "") | fromdateiso8601) as $s
    | [$rec | splits("\n") | select(length >= 7)] as $shas
    | [inputs | select(. != "") | split("\t")
       | {full: .[0], short: .[1], at: (.[2] | tonumber), subject: (.[3:] | join("\t"))}
       | select(.at >= $s)
       | .full as $f | select([$shas[] | select(. as $r | $f | startswith($r))] | length == 0)
       | (.subject | gsub("[\"'"'"'\\\\]"; "")) as $bare
       | select($bare == "" or ($written | contains($bare) | not))]
    | sort_by(.at)
    | if length == 0 then "arrivals: none" else .[] | "arrival \(.short) \(.subject)" end' 2>/dev/null ||
    fail "the log of $DIR could not be read"
