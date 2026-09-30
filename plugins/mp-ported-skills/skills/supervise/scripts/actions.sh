#!/bin/sh
# actions.sh -- list every shared action a supervised worker took.
#
# The hook from #66 refuses a worker's shared actions only in the forms it
# recognizes, so this is the check on what got through. It lists, one line
# each:
#   <kind> <id> ungranted: <url>       each entry in the job's `children`
#                                      (a PR or issue it opened)
#   branch <remote/branch> ungranted: holds the worker's commits
#                                      each remote-tracking branch in DIR
#                                      holding a commit in START..HEAD
#   command <status> ungranted: <cmd>  each Bash call in the worker's
#                                      transcript, or a subagent's, that is
#                                      a shared action
# A call is a shared action when the #66 hook would refuse it, when it runs
# a `gh pr` or `gh issue` subcommand that is not read-only (view, list,
# status, diff, checks, checkout), or when Claude Code recorded a push or PR
# on its result. That record comes from what ran, so it catches a script
# that pushes, which the command text does not show. Only calls whose text
# names gh, push, send-pack or alias are checked against the hook, so a push
# through a git alias from config shows only when its result recorded it.
#
# <status> is `succeeded`, `refused` (by the auto-mode classifier or the
# #66 hook), `failed` (any other error) or `no result`. <cmd> is the
# command's first line, with ` ...` when it has more, and ` -- push
# <branch>` or ` -- pr <n> <action>` when the result recorded one.
#
# The branch lines read DIR's remote-tracking refs without fetching, so a
# push from another checkout of the same repo shows only after a fetch
# there.
#
# This version holds no standing grants (#58), so every action is
# `ungranted`. After the actions it prints a `note` line for each source it
# could not read, which is never taken as empty, and prints `none` only when
# there are neither actions nor notes.
#
# The job's state.json and the transcripts are read under
# $CLAUDE_CONFIG_DIR, the transcript by session id in any project folder,
# since a worker that entered a worktree has its transcript moved there.
#
# Usage:
#   actions.sh --id ID --dir DIR --start SHA
#
# DIR is the checkout the worker committed in (watch.sh's cwd line), START
# the commit the branch started at.

set -u

ID=""
DIR=""
START=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)    need_value "$@"; ID="$2"; shift 2 ;;
        --dir)   need_value "$@"; DIR="$2"; shift 2 ;;
        --start) need_value "$@"; START="$2"; shift 2 ;;
        --help)
            printf 'Usage: actions.sh --id ID --dir DIR --start SHA\n'
            printf 'Lists each PR, issue, remote branch and shared command the worker took, then note lines; none when empty.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$START" ] || fail "--start is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the worker's job is unknown"
git -C "$DIR" rev-parse -q --verify "$START^{commit}" >/dev/null || fail "not a commit in $DIR: $START"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
hook="$SCRIPT_DIR/../../../scripts/deny-shared-actions.sh"
[ -f "$hook" ] || fail "the shared-action hook is missing: $hook"

job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
actions=""
notes=""
add() { actions="$actions$1
"; }
note() { notes="${notes}note $1
"; }

# refused <command>: whether the #66 hook refuses it in an unattended
# auto-mode session. Run in DIR, where it looks up git aliases.
refused() {
    [ -n "$(jq -cn --arg c "$1" '{permission_mode: "auto", tool_name: "Bash", tool_input: {command: $c}}' |
        (cd "$DIR" && CLAUDE_CODE_SESSION_ATTENDED=0 sh "$hook"))" ]
}

# gh_write_words <word>...: prints yes when the words run `gh pr` or
# `gh issue` with a subcommand that is not read-only.
gh_write_words() {
    while [ $# -gt 0 ]; do
        case "$1" in
            [A-Za-z_]*=* | env | command | exec | time | nohup) shift ;;
            *) break ;;
        esac
    done
    [ "${1##*/}" = gh ] || return 0
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -R | --repo) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            --repo=* | -R?*) shift ;;
            *) break ;;
        esac
    done
    case "${1:-}" in
        pr | issue) ;;
        *) return 0 ;;
    esac
    case "${2:-}" in
        '' | -* | view | list | status | diff | checks | checkout) return 0 ;;
    esac
    echo yes
}

# gh_write <command>: whether a command in it is such a gh write. Split as
# the hook splits, on separators, with quotes dropped.
gh_write() {
    segments=$(printf '%s\n' "$1" | sed -E 's/(&&|\|\||[;&|()`])/\n/g' | tr -d "\"'\\\\")
    oldIFS=$IFS
    IFS='
'
    set -f
    found=""
    for seg in $segments; do
        IFS=$oldIFS
        # shellcheck disable=SC2086
        found=$found$(gh_write_words $seg)
    done
    set +f
    IFS=$oldIFS
    [ -n "$found" ]
}

# calls <transcript>: one JSON row per Bash call worth checking: its
# command, whether its result recorded a push or PR, and its report line.
calls() {
    jq -c -s '
        [.[] | select(.type == "assistant" or .type == "user")] as $rows
        | ([$rows[] | select(.type == "user") | . as $row | .message.content[]? | objects
            | select(.type == "tool_result" and .tool_use_id != null)
            | {key: .tool_use_id,
               value: {error: (.is_error // false),
                       text: (.content | if type == "string" then . else ([.[]? | .text? // empty] | join("\n")) end),
                       op: ($row.toolUseResult | if type == "object" then .gitOperation else null end)}}]
           | from_entries) as $results
        | $rows[] | select(.type == "assistant") | .message.content[]? | objects
        | select(.type == "tool_use" and .name == "Bash")
        | $results[.id // ""] as $result
        | (.input.command // "") as $cmd
        | ([($result.op // {}) | (.push // empty | "push \(.branch)"), (.pr // empty | "pr \(.number) \(.action)")]
           | join(", ")) as $ops
        | select($ops != "" or ($cmd | test("\\bgh\\b|push|send-pack|alias")))
        | ($cmd | split("\n")) as $lines
        | {cmd: $cmd, recorded: ($ops != ""),
           line: ("command "
                  + (if $result == null then "no result"
                     elif ($result.error | not) then "succeeded"
                     elif ($result.text | test("denied by the Claude Code auto mode classifier|on its own \\(#66\\)")) then "refused"
                     else "failed" end)
                  + " ungranted: " + $lines[0]
                  + (if ($lines | length) > 1 then " ..." else "" end)
                  + (if $ops != "" then " -- " + $ops else "" end))}' "$1" 2>/dev/null
}

sid=""
if [ ! -f "$job" ]; then
    note "no job state for $ID under $CLAUDE_CONFIG_DIR/jobs, so its PRs, issues and commands were not read"
elif ! children=$(jq -r '.children // [] | .[] | "\(.kind) \(.id) ungranted: \(.href // "")"' "$job" 2>/dev/null) ||
    ! sid=$(jq -r '.sessionId // empty' "$job" 2>/dev/null); then
    note "job state $job could not be read, so its PRs, issues and commands were not read"
    sid=""
else
    [ -z "$children" ] || add "$children"
    [ -n "$sid" ] || note "job state $job names no session, so its commands were not read"
fi

if commits=$(git -C "$DIR" rev-list "$START..HEAD" 2>/dev/null); then
    branches=$(for c in $commits; do
        git -C "$DIR" for-each-ref --contains "$c" --format='%(refname:short)' refs/remotes
    done | grep -v '/HEAD$' | sort -u)
    for b in $branches; do
        add "branch $b ungranted: holds the worker's commits"
    done
else
    note "git rev-list $START..HEAD failed in $DIR, so remote branches were not read"
fi

if [ -n "$sid" ]; then
    set -- "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl
    [ -f "$1" ] || note "no transcript for session $sid under $CLAUDE_CONFIG_DIR/projects, so its commands were not read"
    for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl "$CLAUDE_CONFIG_DIR"/projects/*/"$sid"/subagents/*.jsonl; do
        [ -f "$t" ] || continue
        if ! rows=$(calls "$t"); then
            note "transcript $t could not be read, so its commands were not read"
            continue
        fi
        oldIFS=$IFS
        IFS='
'
        set -f
        for row in $rows; do
            IFS=$oldIFS
            cmd=$(printf '%s' "$row" | jq -r .cmd)
            if [ "$(printf '%s' "$row" | jq -r .recorded)" = true ] || gh_write "$cmd" || refused "$cmd"; then
                add "$(printf '%s' "$row" | jq -r .line)"
            fi
        done
        set +f
        IFS=$oldIFS
    done
fi

printf '%s%s' "$actions" "$notes"
[ -n "$actions$notes" ] || echo none
