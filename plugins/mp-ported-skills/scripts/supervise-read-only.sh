#!/bin/sh
# supervise-read-only.sh -- PreToolUse hook: keep an attended session
# read-only in a checkout a supervised worker holds (#76).
#
# /supervise's launch.sh writes a marker naming the worker's id at
# `git rev-parse --git-path mp-supervise-worker` in the Project's checkout,
# and its release.sh removes it once the worker is stopped or removed. While
# the marker is there, this hook refuses, in an attended session, a file edit
# (Edit, Write, NotebookEdit) whose target lies in that checkout, and a Bash
# command that runs git commit, merge, rebase, checkout, switch, reset or
# stash (other than `stash list` and `stash show`) there. The supervisor and
# the worker share one working tree when /supervise runs from inside the
# Project, and from a parent folder the supervisor could still edit it.
# Reads, gh and the supervise scripts still run.
#
# A Project's Distribution repo (#125) carries the same marker while its
# worker runs, so the hook holds it too; that marker's `project <path>` line
# names the folder the refusal tells the session to release.
#
# The checkout is the one git finds from the edited file's nearest existing
# folder, or, for Bash, from the session's cwd as changed by `cd` and
# `git -C` in the command. A linked worktree is a checkout of its own, with
# its own marker path.
#
# Detection: a background worker has CLAUDE_CODE_SESSION_ATTENDED=0 in its
# own process env (see deny-shared-actions.sh); every other session,
# including one where the variable is unset, is attended, so the worker
# itself is never refused.
#
# The command scan splits on separators, parens and backticks, drops quotes
# and backslashes, and skips VAR=value, shell keywords, env, command,
# builtin, exec, time, nohup, nice, timeout, xargs, eval and `sh -c`, as
# deny-shared-actions.sh does. It guards against a slip, not a determined
# session: a file written from Bash (`>`, `sed -i`, `cp`), a git command
# that names its checkout with `--git-dir` or `--work-tree`, one built from
# variables, and a script that runs git all get through.
#
# Reads the PreToolUse payload on stdin. Prints a deny decision and exits 0
# when the call is refused; otherwise prints nothing and exits 0. A missing
# jq or an unreadable payload lets the call through.

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
tool=$(field .tool_name)
cwd=$(field .cwd)
[ -n "$cwd" ] || cwd=$(pwd)

# resolve <path> <base>: the path made absolute against the base folder.
resolve() {
    case $1 in
        /*) printf '%s' "$1" ;;
        '~') printf '%s' "$HOME" ;;
        '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s/%s' "$2" "$1" ;;
    esac
}

# held <folder>: when a worker's marker is in the folder's checkout, set
# worker and checkout and succeed.
held() {
    marker=$(git -C "$1" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) || return 1
    [ -s "$marker" ] || return 1
    worker=$(head -n 1 "$marker")
    checkout=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || checkout=$1
    # A Distribution repo's marker names its Project folder, which is where
    # release.sh clears both (#125).
    release_dir=$(sed -n 's/^project //p' "$marker")
    [ -n "$release_dir" ] || release_dir=$checkout
    return 0
}

refuse() {
    jq -cn --arg reason "Background worker $worker holds the checkout $checkout, so this session stays read-only there until it stops (#76): no file edits and no git commit, merge, rebase, checkout, switch, reset or stash. Open the worker with \`claude attach $worker\`. If it has stopped, clear its marker: sh '${CLAUDE_PLUGIN_ROOT:-<plugin>}/skills/supervise/scripts/release.sh' --dir '$release_dir' --id $worker" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

case $tool in
    Edit | Write | NotebookEdit)
        path=$(field '.tool_input.file_path // .tool_input.notebook_path')
        [ -n "$path" ] || exit 0
        dir=$(dirname -- "$(resolve "$path" "$cwd")")
        while [ ! -d "$dir" ] && [ "$dir" != / ]; do dir=$(dirname -- "$dir"); done
        held "$dir" && refuse
        exit 0 ;;
    Bash) ;;
    *) exit 0 ;;
esac

cmd=$(field .tool_input.command)
case $cmd in *git*) ;; *) exit 0 ;; esac

split=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||[;&|()`])/\n/g')
dir=$cwd
oldIFS=$IFS
IFS='
'
set -f
for seg in $split; do
    seg=$(printf '%s' "$seg" | tr -d "\"'\\\\")
    IFS=$oldIFS
    # shellcheck disable=SC2086
    set -- $seg
    IFS='
'
    # Skip words that run what follows them.
    while [ $# -gt 0 ]; do
        case $1 in
            [A-Za-z_]*=*) shift; continue ;;
            '{' | '!' | if | then | else | elif | do | while | until) shift; continue ;;
        esac
        case ${1##*/} in
            env)
                shift
                while [ $# -gt 0 ]; do
                    case $1 in
                        -u | -C | -P) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                        -* | [A-Za-z_]*=*) shift ;;
                        *) break ;;
                    esac
                done ;;
            command | builtin | exec | time | nohup | eval)
                shift
                while [ $# -gt 0 ]; do
                    case $1 in -*) shift ;; *) break ;; esac
                done ;;
            nice | timeout | gtimeout)
                shift
                while [ $# -gt 0 ]; do
                    case $1 in
                        -n | -s | -k) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                        -* | [0-9]*) shift ;;
                        *) break ;;
                    esac
                done ;;
            xargs)
                shift
                while [ $# -gt 0 ]; do
                    case $1 in
                        -I | -n | -P | -L | -s | -d | -E | -a) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                        -*) shift ;;
                        *) break ;;
                    esac
                done ;;
            sh | bash | zsh | dash | ksh)
                if [ "${2:-}" = -c ] || [ "${2:-}" = -lc ]; then shift 2; else break; fi ;;
            *) break ;;
        esac
    done
    [ $# -gt 0 ] || continue
    case ${1##*/} in
        cd)
            if [ $# -ge 2 ]; then dir=$(resolve "$2" "$dir"); else dir=$HOME; fi ;;
        git)
            shift
            at=$dir
            while [ $# -gt 0 ]; do
                case $1 in
                    -C) [ $# -ge 2 ] || break; at=$(resolve "$2" "$at"); shift 2 ;;
                    -c) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                    -*) shift ;;
                    *) break ;;
                esac
            done
            case ${1:-} in
                commit | merge | rebase | checkout | switch | reset) ;;
                stash) case ${2:-} in list | show) continue ;; esac ;;
                *) continue ;;
            esac
            held "$at" && { set +f; IFS=$oldIFS; refuse; } ;;
    esac
done
exit 0
