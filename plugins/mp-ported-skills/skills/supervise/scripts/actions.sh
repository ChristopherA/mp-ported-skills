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
#                                      holding a commit in START..HEAD that
#                                      the worker pushed
#   branch <remote/branch> pushed by someone else: holds the worker's commits
#                                      each such branch the worker did not
#                                      push (the maintainer's terminal, or a
#                                      plain push by the supervisor)
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
# `ungranted`, on a branch or command line, becomes `granted (<citation>)`
# when grant.sh (#58) finds a standing grant for the action on DIR's default
# branch as committed on origin -- never the working tree, so a grant a
# worker commits locally but cannot push stays ungranted, reported as a
# `note` line naming it as ignored, not silently treated as absent.
# A branch line's action is always push. A command line's action is a
# light word-token
# guess (push, pr-create, pr-merge, issue-close, issue-comment or
# issue-create) from its text and the
# recorded op, good enough to cite a grant, not an enforcement check; a gh
# write the hook's own scan would not single out, or one this guess cannot
# name, stays ungranted. A `children` entry -- a PR or issue the worker's
# own tool use opened, with no command text to classify -- is always
# `ungranted` too.
#
# A branch counts as the worker's push only when a call in its transcript,
# or a subagent's, that succeeded or has no result (it may have landed)
# pushed to it: a push Claude Code recorded on the result, or a push
# command whose text names the branch, or names no branch at all
# (`git push`, `HEAD`, `--all`), since that could be any. A refused or
# failed push does not count (#98). The remote a command names is not
# compared, so a push of `main` to any remote marks every `<remote>/main`
# as the worker's. When a transcript could not be read, every branch is
# read as the worker's, since nothing clears it. Each doubt resolves
# toward the worker's push, never away from it.
#
# A branch push.sh pushed for this worker, on the maintainer's approval in
# the supervisor's session (#100), is labelled `pushed by the supervisor on
# the maintainer's approval` instead, read from the checkout's
# `git rev-parse --git-path mp-supervise-pushed`, where push.sh records
# each push by worker id and upstream branch.
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

# refused <command>: whether the #66 hook would refuse it in an unattended
# auto-mode session, regardless of any grant now on record -- this is an
# inclusion test (did this command match a regulated form at all), not a
# grant lookup, so a grant added since the worker ran must not make a
# command it actually refused at the time drop out of the report.
# grant_label, below, is what cites the grant on the line. Run in DIR, where
# it looks up git aliases.
refused() {
    [ -n "$(jq -cn --arg c "$1" '{permission_mode: "auto", tool_name: "Bash", tool_input: {command: $c}}' |
        (cd "$DIR" && CLAUDE_CODE_SESSION_ATTENDED=0 MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS=1 sh "$hook"))" ]
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
# command, the op Claude Code recorded, and its report line's pieces --
# status and rest, with "<kind> ungranted:" left for the shell loop to fill
# in once it knows whether grant.sh covers the action.
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
        | {cmd: $cmd, ops: $ops, recorded: ($ops != ""),
           pushed: ($result.op.push.branch? // ""),
           status: (if $result == null then "no result"
                     elif ($result.error | not) then "succeeded"
                     elif ($result.text | test("denied by the Claude Code auto mode classifier|on its own \\(#66\\)")) then "refused"
                     else "failed" end),
           rest: ($lines[0]
                  + (if ($lines | length) > 1 then " ..." else "" end)
                  + (if $ops != "" then " -- " + $ops else "" end))}' "$1" 2>/dev/null
}

# action_for <cmd> <ops>: push, pr-create, pr-merge, issue-close,
# issue-comment, issue-create, or empty. A light word-token heuristic for
# citing a grant on the report line, not an enforcement check --
# deny-shared-actions.sh is the enforcement layer, and this only has to
# agree with it closely enough to cite the right grant. A `gh api` call
# naming an issue's comments reads as issue-comment (#110); one creating an
# issue through gh api is not told apart from the other issue writes, and
# stays ungranted.
action_for() {
    words=$(printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9_-' '\n')
    has() { printf '%s\n' "$words" | grep -qx -- "$1"; }
    if has push || has send-pack; then echo push
    elif has gh && has pr && has create; then echo pr-create
    elif has gh && has pr && has merge; then echo pr-merge
    elif has gh && has issue && has close; then echo issue-close
    elif has gh && has issue && has comment; then echo issue-comment
    elif has gh && has issue && { has create || has new; }; then echo issue-create
    elif has gh && has api && has issues && has comments; then echo issue-comment
    else echo ""
    fi
}

# push_targets <cmd> <recorded branch>: the branch names a succeeded push
# reached, one per line, or `*` when it may have reached any. The recorded
# branch is what Claude Code saw; the command's own `git push` words name
# the rest. Split as gh_write splits, with redirections dropped first so
# `2>&1` is not read as a refspec. Call it only through $(...): it reuses
# the globals gh_write and the transcript loop set.
push_targets() {
    [ -z "$2" ] || printf '%s\n' "$2"
    segments=$(printf '%s\n' "$1" | sed -E 's/[0-9]*[<>]+(&[0-9-]+| *[^ &|;<>]+)//g' |
        sed -E 's/(&&|\|\||[;&|()`])/\n/g' | tr -d "\"'\\\\")
    oldIFS=$IFS
    IFS='
'
    set -f
    named=""
    for seg in $segments; do
        IFS=$oldIFS
        # shellcheck disable=SC2086
        reached=$(push_words $seg)
        [ -z "$reached" ] || named="$named$reached
"
    done
    set +f
    IFS=$oldIFS
    if [ -n "$named" ]; then
        printf '%s' "$named"
    elif [ -z "$2" ]; then
        echo '*'
    fi
}

# push_words <word>...: for a `git push` or `git send-pack`, the branch
# names its refspecs push to, and `*` when it names none, or one that
# cannot be read as a branch.
push_words() {
    while [ $# -gt 0 ]; do
        case "$1" in
            [A-Za-z_]*=* | env | command | exec | time | nohup) shift ;;
            *) break ;;
        esac
    done
    [ "${1##*/}" = git ] || return 0
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -C | -c | --git-dir | --work-tree | --namespace) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) break ;;
        esac
    done
    case "${1:-}" in
        push) ;;
        send-pack) echo '*'; return 0 ;;
        *) return 0 ;;
    esac
    shift
    remote=""
    any=""
    refs=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --all | --mirror | --branches) any=yes ;;
            -o | --push-option | --repo | --receive-pack | --exec) [ $# -lt 2 ] || shift ;;
            -*) ;;
            *)
                if [ -z "$remote" ]; then
                    remote=$1
                else
                    dst=${1#+}
                    dst=${dst##*:}
                    dst=${dst#refs/heads/}
                    case "$dst" in
                        '' | HEAD | @ | *'*'*) any=yes ;;
                        *) refs="$refs$dst
" ;;
                    esac
                fi ;;
        esac
        shift
    done
    if [ -n "$any" ] || [ -z "$refs" ]; then
        echo '*'
    fi
    printf '%s' "$refs"
}

# grant_label <action>: sets GRANT_LABEL to "ungranted", or
# "granted (<citation>)" when grant.sh finds a standing grant for it on the
# committed default branch (#58). An empty action (action_for found none)
# is always ungranted. grant.sh's own note of a grant it found only on the
# working tree or an unpushed commit -- ignored, since a worker can reach
# either without the maintainer seeing it -- is surfaced as a `note` line
# via note(), not swallowed, so a tampered or merely premature grant is
# reported, not just quietly ignored. Called directly, never through
# $(...): note() mutates the shared $notes, and that mutation would be
# lost if this ran in a command-substitution subshell.
grant_label() {
    GRANT_LABEL=ungranted
    [ -n "$1" ] || return
    err=$(mktemp)
    if cite=$(sh "$SCRIPT_DIR/grant.sh" --dir "$DIR" --action "$1" 2>"$err") && [ -n "$cite" ]; then
        GRANT_LABEL="granted ($cite)"
    elif [ -s "$err" ]; then
        # grant.sh's own message already starts "note: "; note() adds its
        # own "note " prefix, so strip grant.sh's to avoid "note note: ".
        note "$(command cat "$err" | sed 's/^note: //')"
    fi
    command rm -f "$err"
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

# The transcripts are read before the branches, so each branch line knows
# whether the worker pushed it; command lines still print after the branch
# lines.
commands=""
worker_pushes=""
unread=""
[ -n "$sid" ] || unread=yes

if [ -n "$sid" ]; then
    set -- "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl
    if [ ! -f "$1" ]; then
        note "no transcript for session $sid under $CLAUDE_CONFIG_DIR/projects, so its commands were not read"
        unread=yes
    fi
    for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl "$CLAUDE_CONFIG_DIR"/projects/*/"$sid"/subagents/*.jsonl; do
        [ -f "$t" ] || continue
        if ! rows=$(calls "$t"); then
            note "transcript $t could not be read, so its commands were not read"
            unread=yes
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
                ops=$(printf '%s' "$row" | jq -r .ops)
                status=$(printf '%s' "$row" | jq -r .status)
                rest=$(printf '%s' "$row" | jq -r .rest)
                action=$(action_for "$cmd" "$ops")
                grant_label "$action"
                commands="${commands}command $status $GRANT_LABEL: $rest
"
                if { [ "$status" = succeeded ] || [ "$status" = "no result" ]; } && [ "$action" = push ]; then
                    worker_pushes="$worker_pushes$(push_targets "$cmd" "$(printf '%s' "$row" | jq -r .pushed)")
"
                fi
            fi
        done
        set +f
        IFS=$oldIFS
    done
fi

if commits=$(git -C "$DIR" rev-list "$START..HEAD" 2>/dev/null); then
    # Filtered on the full name: origin/HEAD's short name is just `origin`.
    branches=$(for c in $commits; do
        git -C "$DIR" for-each-ref --contains "$c" --format='%(refname)' refs/remotes
    done | grep -v '/HEAD$' | sed 's|^refs/remotes/||' | sort -u)
    pushed=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-pushed 2>/dev/null)
    for b in $branches; do
        if [ -f "$pushed" ] && awk -v id="$ID" -v b="$b" '$1 == id && $2 == b { found = 1 } END { exit !found }' "$pushed"; then
            add "branch $b pushed by the supervisor on the maintainer's approval: holds the worker's commits"
            continue
        fi
        if [ -z "$unread" ] && ! printf '%s\n' "$worker_pushes" | grep -qxF -e '*' -e "${b#*/}"; then
            add "branch $b pushed by someone else: holds the worker's commits"
            continue
        fi
        grant_label push
        add "branch $b $GRANT_LABEL: holds the worker's commits"
    done
else
    note "git rev-list $START..HEAD failed in $DIR, so remote branches were not read"
fi

actions="$actions$commands"

printf '%s%s' "$actions" "$notes"
[ -n "$actions$notes" ] || echo none
