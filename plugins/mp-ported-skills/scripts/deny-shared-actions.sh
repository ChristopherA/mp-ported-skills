#!/bin/sh
# deny-shared-actions.sh -- PreToolUse hook: refuse a shared action a
# background worker reaches on its own (#66).
#
# A Claude Code background session (`claude --bg`) launched in auto mode --
# /supervise's workers, or any other unattended auto-mode session -- must
# not push, open a PR, or close an issue by itself: main has no branch
# protection, and the auto-mode classifier only makes a judgment call, not a
# rule. This hook refuses a Bash command that runs `git push` (any form,
# including `git -C <dir> push` and one inside a compound command),
# `gh pr create`, `gh pr merge` or `gh issue close`, and points the worker
# at the supervisor and docs/agents/supervision.md (#58) as the route to a
# shared action.
#
# Detection: Claude Code sets CLAUDE_CODE_SESSION_ATTENDED=0 in a
# background session's own process env (confirmed 2026-09-29 by reading
# `env` inside a live `claude --bg` session; undocumented, so this script
# reads its absence as attended -- fails open, not closed). The hook
# input's permission_mode field is documented
# (https://code.claude.com/docs/en/hooks.md). Both conditions -- unattended
# and auto mode -- must hold before this script looks at the command at
# all, so a maintainer's own interactive session, whatever its permission
# mode, is never in scope, and nor is an unattended session outside auto
# mode (it blocks on the first ordinary permission prompt instead, since it
# has nobody to answer).
#
# The scan sees through a leading VAR=value assignment and a leading `env`
# (with its own VAR=value and flag arguments), so `env FOO=bar git push`
# and `FOO=bar git push` are refused the same as a bare `git push`. It does
# NOT see through `sh -c '...'`, `eval '...'`, or any other interpreter
# indirection: this line-and-word splitter does not parse shell quoting, so
# the one argument that actually carries the nested command cannot be told
# apart from several unquoted words reliably enough to recurse into it
# without both false negatives (a quoted `git push` the splitter cuts in
# two) and false positives (a quoted string that only mentions `git push`
# in prose). That gap stays open; this hook is one backstop under the
# auto-mode classifier, not a sandbox.
#
# A script the supervisor runs to perform a granted push (#58) is a
# different Bash command from the ones matched here -- this hook sees only
# the literal command text, never what a script it names goes on to run --
# so that route stays open without special-casing it.
#
# Reads the PreToolUse payload on stdin. Prints a deny decision and exits 0
# when the command matches one of the refused forms; otherwise prints
# nothing and exits 0.

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

mode=$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null) || mode=""
[ "$mode" = auto ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || tool=""
[ "$tool" = Bash ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || exit 0

# Split on command separators and subshell/substitution parens, so each
# segment starts with the command actually run there.
split=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||[;&|()])/\n/g')

matched=""
oldIFS=$IFS
IFS='
'
set -f
for seg in $split; do
    [ -n "$matched" ] && break
    # Restore whitespace splitting to tokenize this one line into words;
    # the newline-only IFS above is only for the `for` line split itself.
    IFS=$oldIFS
    # shellcheck disable=SC2086
    set -- $seg
    IFS='
'
    # A leading VAR=value assignment (git and gh both take config this way)
    # is transparent to what runs after it.
    while [ $# -gt 0 ]; do
        case "$1" in
        [A-Za-z_]*=*) shift ;;
        *) break ;;
        esac
    done
    [ $# -gt 0 ] || continue
    # `env` is transparent too, past its own flags and VAR=value arguments.
    if [ "$1" = env ]; then
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
            -*) shift ;;
            [A-Za-z_]*=*) shift ;;
            *) break ;;
            esac
        done
        [ $# -gt 0 ] || continue
    fi
    case "$1" in
    git)
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
            -C | -c) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) break ;;
            esac
        done
        [ "${1:-}" = push ] && matched="git push"
        ;;
    gh)
        shift
        case "${1:-}/${2:-}" in
        pr/create) matched="gh pr create" ;;
        pr/merge) matched="gh pr merge" ;;
        issue/close) matched="gh issue close" ;;
        esac
        ;;
    esac
done
set +f
IFS=$oldIFS

[ -n "$matched" ] || exit 0

jq -cn --arg reason "A background session in auto mode cannot run '$matched' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
