# shared-action-classify.sh -- sourced, not run: name the shared action a
# git or gh argument list reaches (#66).
#
# deny-shared-actions.sh calls these on the words it scanned out of a Bash
# command's text; worker-bin/git and worker-bin/gh call them on the real
# argv a process was started with, which reaches inside scripts the hook
# cannot see. One parser for both keeps the refused forms the same.
#
#   classify_git <args after "git">   sets matched to "git push", ...
#   classify_gh <args after "gh">     sets matched to "gh pr create", ...
#
# Both leave matched empty when the arguments reach no shared action. The
# caller sets two variables first: classify_git_cmd, the git that resolves
# an alias from git config (a wrapper passes the real git here, so the
# lookup does not run the wrapper again), and classify_text, the text a
# GraphQL mutation is looked for in.

classify_git() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -c)
            # An alias defined inline: `git -c alias.p=push p`.
            case "${2:-}" in alias.*push*) matched="git push (alias)"; return 0 ;; esac
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            ;;
        -C) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) break ;;
        esac
    done
    sub=${1:-}
    if [ "$sub" = push ] || [ "$sub" = send-pack ]; then
        matched="git push"
    elif [ "$sub" = subtree ] && [ "${2:-}" = push ]; then
        matched="git subtree push"
    elif [ -n "$sub" ]; then
        # An alias from git config, read in the working directory, where
        # the command runs.
        case "$("${classify_git_cmd:-git}" config --get "alias.$sub" 2>/dev/null)" in
        *push*) matched="git push (alias $sub)" ;;
        esac
    fi
}

classify_gh() {
    # A repo given before the subcommand: `gh -R o/r pr create`.
    while [ $# -gt 0 ]; do
        case "$1" in
        -R | --repo) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        --repo=* | -R?*) shift ;;
        *) break ;;
        esac
    done
    case "${1:-}/${2:-}" in
    pr/create) matched="gh pr create" ;;
    pr/merge) matched="gh pr merge" ;;
    issue/close) matched="gh issue close" ;;
    api/*)
        # A write through the REST or GraphQL API reaches the same
        # actions: a POST, PUT, PATCH or DELETE on pulls, issues, merges,
        # contents or the git data API, or a GraphQL mutation. gh sends POST
        # by default once a field or input is given.
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
            *pulls* | *issues* | *merges* | *contents* | */git/*) target=yes; shift ;;
            *) shift ;;
            esac
        done
        method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
        [ -n "$method" ] || { [ -n "$fields" ] && method=POST; } || method=GET
        if [ -n "$graphql" ]; then
            case "${classify_text:-}" in *mutation*) matched="gh api graphql mutation" ;; esac
        elif [ -n "$target" ] && [ "$method" != GET ]; then
            matched="gh api $method"
        fi
        ;;
    esac
}

# The action a grant names for a matched form, or nothing for a form no
# grant covers: the gh api forms and the piped-into-a-shell fallback, which
# do not say which of the four actions they reach.
grant_action() { # <matched>
    case "$1" in
    "git push (piped"* | "gh (piped"*) ;;
    "git push"* | "git subtree push"* | "git send-pack"*) echo push ;;
    "gh pr create"*) echo pr-create ;;
    "gh pr merge"*) echo pr-merge ;;
    "gh issue close"*) echo issue-close ;;
    esac
}
