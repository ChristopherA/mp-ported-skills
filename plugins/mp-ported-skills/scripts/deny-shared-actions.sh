#!/bin/sh
# deny-shared-actions.sh -- PreToolUse hook: refuse a shared action a
# background worker reaches on its own (#66).
#
# A Claude Code background session (`claude --bg`) launched in auto mode --
# /supervise's workers, or any other unattended auto-mode session -- must
# not push, open a PR, or close an issue by itself: main has no branch
# protection, and the auto-mode classifier only makes a judgment call, not a
# rule. This hook refuses a Bash command that runs `git push`,
# `gh pr create`, `gh pr merge`, `gh issue close`, or a `gh api` write that
# reaches the same actions, and points the worker at the supervisor and
# docs/agents/supervision.md (#58) as the route to a shared action.
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
# nice, timeout, xargs, eval and `sh -c` (bash, zsh and the rest too). It
# matches the program by basename, so `/usr/bin/git push` counts, and
# resolves a git alias given with `-c alias.X=...` or found in git config.
# It does not parse quoting, so a separator inside a quoted string splits
# too: `git commit -m "a; git push"` is refused. In an unattended session
# that false refusal costs a detour through the supervisor, where a miss
# would publish.
#
# The hook sees only the command text, never what a script it names goes
# on to run, so `sh some-script.sh` that pushes gets through. Narrowing
# that to #58's grant script waits on #58 (docs/adr/0004).
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

# Split on command separators, subshell/substitution parens and backticks,
# so each segment starts with the command actually run there. Quoting is
# not parsed: a separator inside a quoted string also splits, which can
# over-refuse but never hides a command.
split=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||[;&|()`])/\n/g')

matched=""
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
            # Only `-c` runs its argument as a command; `sh script.sh` runs
            # a file this hook cannot see into.
            shell_c=""
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                --*) shift ;;
                -*c*) shell_c=yes; shift ;;
                -*) shift ;;
                *) break ;;
                esac
            done
            [ -n "$shell_c" ] || set --
            ;;
        *) break ;;
        esac
    done
    [ $# -gt 0 ] || continue
    case "${1##*/}" in
    git)
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
            -c)
                # An alias defined inline: `git -c alias.p=push p`.
                case "${2:-}" in alias.*push*) matched="git push (alias)" ;; esac
                if [ $# -ge 2 ]; then shift 2; else shift; fi
                ;;
            -C) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) break ;;
            esac
        done
        [ -n "$matched" ] && break
        sub=${1:-}
        if [ "$sub" = push ]; then
            matched="git push"
        elif [ -n "$sub" ]; then
            # An alias from git config, read in the session's working
            # directory, where the command runs.
            case "$(git config --get "alias.$sub" 2>/dev/null)" in
            *push*) matched="git push (alias $sub)" ;;
            esac
        fi
        ;;
    gh)
        shift
        case "${1:-}/${2:-}" in
        pr/create) matched="gh pr create" ;;
        pr/merge) matched="gh pr merge" ;;
        issue/close) matched="gh issue close" ;;
        api/*)
            # A write through the REST or GraphQL API reaches the same
            # actions: a POST, PUT, PATCH or DELETE on pulls, issues, merges
            # or git refs, or a GraphQL mutation. gh sends POST by default
            # once a field or input is given.
            shift
            method="" fields="" target="" graphql=""
            while [ $# -gt 0 ]; do
                case "$1" in
                -X | --method) method=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -X* ) method=${1#-X}; shift ;;
                --method=*) method=${1#--method=}; shift ;;
                -f | -F | --field | --raw-field | --input) fields=yes; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                -f* | -F* | --field=* | --raw-field=* | --input=*) fields=yes; shift ;;
                graphql) graphql=yes; shift ;;
                *pulls* | *issues* | *merges* | *git/refs*) target=yes; shift ;;
                *) shift ;;
                esac
            done
            method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
            [ -n "$method" ] || { [ -n "$fields" ] && method=POST; } || method=GET
            if [ -n "$graphql" ]; then
                case "$cmd" in *mutation*) matched="gh api graphql mutation" ;; esac
            elif [ -n "$target" ] && [ "$method" != GET ]; then
                matched="gh api $method"
            fi
            ;;
        esac
        ;;
    esac
done
set +f
IFS=$oldIFS

[ -n "$matched" ] || exit 0

jq -cn --arg reason "A background session in auto mode cannot run '$matched' on its own (#66): main has no branch protection, and the auto-mode classifier makes a judgment call here, not a rule. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
