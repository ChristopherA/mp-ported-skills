#!/bin/sh
# deny-shared-actions.sh -- PreToolUse hook: refuse a shared action a
# background worker reaches on its own, unless a standing grant covers it
# (#58, #66).
#
# A Claude Code background session (`claude --bg`) launched in auto mode --
# /supervise's workers, or any other unattended auto-mode session -- must
# not push, open a PR, or close an issue by itself: main has no branch
# protection, and the auto-mode classifier only makes a judgment call, not a
# rule. This hook refuses a Bash command that runs `git push`,
# `gh pr create`, `gh pr merge`, `gh issue close`, or a `gh api` write that
# reaches the same actions, and points the worker at the supervisor and
# docs/agents/supervision.md (#58) as the route to a shared action -- unless
# `grant.sh` finds a standing grant for that same action on the committed
# default branch, in which case this hook lets the command through. A `git
# push` whose destination grant.sh cannot name (one of the gh api forms, or
# a command piped into a shell) is never granted: a grant covers a form this
# hook can tell apart from the others, and those cannot be told apart from
# each other, so they stay refused on purpose.
#
# Detection: Claude Code sets CLAUDE_CODE_SESSION_ATTENDED=0 in a
# background session's own process env (seen in CLI 2.1.284 by reading
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
# The scan splits the command on separators, parens and backticks, drops
# quotes and backslashes, and skips words that run what follows them:
# VAR=value, shell keywords, env, command, builtin, exec, time, nohup,
# nice, timeout, xargs, eval and `sh -c` (bash, zsh and the rest too),
# and checks the whole command when it pipes into a shell. It matches the
# program by basename, so `/usr/bin/git push` counts, treats
# `git send-pack` and `git subtree push` as pushes, and resolves a git
# alias given with `-c alias.X=...` or found in git config.
# It does not parse quoting, so a separator inside a quoted string splits
# too: `git commit -m "a; git push"` is refused. In an unattended session
# that false refusal costs a detour through the supervisor, where a miss
# would publish.
#
# Known gaps: a command built from variables (`g=git; $g push`), a
# wrapper not listed above (`sudo`, `find -exec`), and a GraphQL mutation
# read from a file. The hook sees only the command text, never what a
# script it names goes on to run, so `sh some-script.sh` that pushes gets
# past this hook whatever it contains. worker-path.sh's git and gh wrappers
# cover that case, and the variable and find -exec ones, by the real
# arguments (docs/adr/0006).
#
# Reads the PreToolUse payload on stdin. Prints a deny decision and exits 0
# when the command matches one of the refused forms; otherwise prints
# nothing and exits 0.

# Like a missing variable, a missing jq or a payload jq cannot read lets the
# command through: this hook is a backstop, not the deciding layer.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

mode=$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null) || mode=""
[ "$mode" = auto ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || tool=""
[ "$tool" = Bash ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
[ -n "$cwd" ] || cwd=$(pwd)
[ -n "$cmd" ] || exit 0

# Split on command separators, subshell/substitution parens and backticks,
# so each segment starts with the command actually run there. Quoting is
# not parsed: a separator inside a quoted string also splits, which can
# over-refuse but never hides a command.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/shared-action-classify.sh"
classify_git_cmd=git
classify_text=$cmd

split=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||[;&|()`])/\n/g')

matched=""
piped=""
oldIFS=$IFS
IFS='
'
set -f
for seg in $split; do
    [ -n "$matched" ] && break
    # Drop quotes and backslashes, so `"git" push`, `\git push` and the
    # quoted body of `sh -c "git push"` read as plain words.
    seg=$(printf '%s' "$seg" | tr -d "\"'\\\\")
    # Restore whitespace splitting to tokenize this one line into words;
    # the newline-only IFS above is only for the `for` line split itself.
    IFS=$oldIFS
    # shellcheck disable=SC2086
    set -- $seg
    IFS='
'
    # Skip words that run what follows them: VAR=value assignments, shell
    # keywords, and wrappers such as env, command, xargs and `sh -c`, each
    # past its own flags. Repeats until a word names the program itself.
    while [ $# -gt 0 ]; do
        case "$1" in
        [A-Za-z_]*=*) shift; continue ;;
        '{' | '!' | if | then | else | elif | do | while | until) shift; continue ;;
        esac
        case "${1##*/}" in
        env)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -u | -C | -P) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -*) shift ;;
                [A-Za-z_]*=*) shift ;;
                *) break ;;
                esac
            done
            ;;
        command | builtin | exec | time | nohup | eval)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -a) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -*) shift ;;
                *) break ;;
                esac
            done
            ;;
        nice | timeout | gtimeout)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -n | -s | -k) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -*) shift ;;
                [0-9]*) shift ;;
                *) break ;;
                esac
            done
            ;;
        xargs)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -I | -n | -P | -L | -s | -d | -E | -a) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -*) shift ;;
                *) break ;;
                esac
            done
            ;;
        sh | bash | zsh | dash | ksh)
            # `-c` and a here-string run their argument as a command; a
            # shell with no argument reads its commands from a pipe, checked
            # below against the whole command; `sh script.sh` runs a file
            # this hook cannot see into.
            shell_c=""
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                --*) shift ;;
                -*c*) shell_c=yes; shift ;;
                -*) shift ;;
                '<<<') shell_c=yes; shift; break ;;
                *) break ;;
                esac
            done
            if [ -z "$shell_c" ]; then
                [ $# -gt 0 ] || piped=yes
                set --
            fi
            ;;
        *) break ;;
        esac
    done
    [ $# -gt 0 ] || continue
    case "${1##*/}" in
    git-push | git-send-pack) matched="git push" ;;
    git)
        shift
        classify_git "$@"
        ;;
    gh)
        shift
        classify_gh "$@"
        ;;
    esac
done
set +f
IFS=$oldIFS

# A shell reading commands from a pipe (`echo git push | sh`) runs text
# this scan saw only as another command's arguments, so check the whole
# command for the words of a refused form.
if [ -z "$matched" ] && [ -n "$piped" ]; then
    words=$(printf '%s' "$cmd" | tr -c 'A-Za-z0-9_-' '\n')
    has() { printf '%s\n' "$words" | grep -qx -- "$1"; }
    if has git && has push; then
        matched="git push (piped into a shell)"
    elif has gh && { { has pr && { has create || has merge; }; } || { has issue && has close; }; }; then
        matched="gh (piped into a shell)"
    fi
fi

[ -n "$matched" ] || exit 0

# A standing grant lets this exact form through. Only a form grant.sh can
# name maps to an action; the gh api forms and the piped-into-a-shell
# fallback stay refused, since a grant names an action, not an arbitrary
# command. MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS, set by actions.sh's own
# probe of whether a past command matches a refused form at all, skips this
# so a grant added since cannot make that probe stop naming it -- the
# variable can only ever make this hook refuse more, never less.
action=""
[ -n "${MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS:-}" ] || action=$(grant_action "$matched")
if [ -n "$action" ]; then
    grant_sh="${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}/skills/supervise/scripts/grant.sh"
    if [ -f "$grant_sh" ] && sh "$grant_sh" --dir "$cwd" --action "$action" >/dev/null 2>&1; then
        exit 0
    fi
fi

jq -cn --arg reason "A background session in auto mode cannot run '$matched' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
