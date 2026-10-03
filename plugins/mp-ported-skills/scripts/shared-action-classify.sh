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
# caller sets three variables first: classify_git_cmd, the git that
# resolves an alias from git config (a wrapper passes the real git here, so
# the lookup does not run the wrapper again); classify_base, the directory
# the command runs in; and classify_text, the text a GraphQL mutation is
# looked for in. classify_git also sets classify_dir, the repo the command
# acts on: classify_base, moved by each `-C <dir>` as git moves. A grant is
# looked up there, so a grant in one checkout does not cover a push from
# another. Scratch variables start with _c so they do not clobber the
# caller's.

classify_git() {
    classify_dir=${classify_base:-.}
    while [ $# -gt 0 ]; do
        case "$1" in
        -c)
            # An alias defined inline: `git -c alias.p=push p`.
            case "${2:-}" in alias.*push*) matched="git push (alias)"; return 0 ;; esac
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            ;;
        -C)
            case "${2:-}" in
            /*) classify_dir=$2 ;;
            '') ;;
            *) classify_dir="$classify_dir/$2" ;;
            esac
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            ;;
        -*) shift ;;
        *) break ;;
        esac
    done
    _csub=${1:-}
    if [ "$_csub" = push ] || [ "$_csub" = send-pack ]; then
        matched="git push"
    elif [ "$_csub" = subtree ] && [ "${2:-}" = push ]; then
        matched="git subtree push"
    elif [ -n "$_csub" ]; then
        # An alias from git config, read in the repo the command acts on.
        case "$("${classify_git_cmd:-git}" -C "$classify_dir" config --get "alias.$_csub" 2>/dev/null)" in
        *push*) matched="git push (alias $_csub)" ;;
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
    issue/comment) matched="gh issue comment" ;;
    issue/create | issue/new) matched="gh issue create" ;;
    api/*)
        # A write through the REST or GraphQL API reaches the same
        # actions: a POST, PUT, PATCH or DELETE on pulls, issues, merges,
        # contents or the git data API, or a GraphQL mutation. gh sends POST
        # by default once a field or input is given. A POST to an issue's
        # comments, or to a repo's issues, is named as the issue comment or
        # new issue it makes, so the grant for that action covers it (#110):
        # only when that path, matched whole, is the one word not taken by
        # a method or field flag. Any other word -- a second path, a
        # header's value -- leaves it a plain gh api write, never granted.
        shift
        _cmethod="" _cfields="" _ctarget="" _cgraphql="" _cissue="" _cwords=0
        while [ $# -gt 0 ]; do
            case "$1" in
            -X | --method) _cmethod=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
            -X* ) _cmethod=${1#-X}; shift; continue ;;
            --method=*) _cmethod=${1#--method=}; shift; continue ;;
            -f | -F | --field | --raw-field | --input) _cfields=yes; if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
            -f* | -F* | --field=* | --raw-field=* | --input=*) _cfields=yes; shift; continue ;;
            -*) shift; continue ;;
            esac
            _cwords=$((_cwords + 1))
            case "$1" in
            graphql) _cgraphql=yes ;;
            *pulls* | *issues* | *merges* | *contents* | */git/*)
                _ctarget=yes
                if printf '%s\n' "$1" | grep -Eqx '/?repos/[^/]+/[^/]+/issues/[0-9]+/comments/?'; then
                    _cissue=comment
                elif printf '%s\n' "$1" | grep -Eqx '/?repos/[^/]+/[^/]+/issues/?'; then
                    _cissue=create
                fi
                ;;
            esac
            shift
        done
        [ "$_cwords" -eq 1 ] || _cissue=""
        _cmethod=$(printf '%s' "$_cmethod" | tr '[:lower:]' '[:upper:]')
        [ -n "$_cmethod" ] || { [ -n "$_cfields" ] && _cmethod=POST; } || _cmethod=GET
        if [ -n "$_cgraphql" ]; then
            case "${classify_text:-}" in *mutation*) matched="gh api graphql mutation" ;; esac
        elif [ -n "$_ctarget" ] && [ "$_cmethod" = POST ] && [ -n "$_cissue" ]; then
            matched="gh api POST (issue $_cissue)"
        elif [ -n "$_ctarget" ] && [ "$_cmethod" != GET ]; then
            matched="gh api $_cmethod"
        fi
        ;;
    esac
}

# The action a grant names for a matched form, or nothing for a form no
# grant covers: the piped-into-a-shell fallback and the other gh api forms,
# which do not say which action they reach. The two gh api POSTs above that
# name an issue comment or a new issue map to that action (#110).
grant_action() { # <matched>
    case "$1" in
    "git push (piped"* | "gh (piped"*) ;;
    "git push"* | "git subtree push"* | "git send-pack"*) echo push ;;
    "gh pr create"*) echo pr-create ;;
    "gh pr merge"*) echo pr-merge ;;
    "gh issue close"*) echo issue-close ;;
    "gh issue comment"* | "gh api POST (issue comment)") echo issue-comment ;;
    "gh issue create"* | "gh api POST (issue create)") echo issue-create ;;
    esac
}
