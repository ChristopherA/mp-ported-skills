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

# classify_distribution: after classify_git matched a push, name it as a
# push in a Project's Distribution repo when classify_dir is one (#141).
# Such a push is the Project's to grant, as `distribution-push`, never
# `push`, and never by the Distribution repo's own supervision.md: matched
# gains ` in Distribution repo <path>` and classify_dir becomes the
# Project, where the caller looks the grant up. A repo is a Project's
# Distribution repo when distribution.sh, run on the Project, names it; the
# Project is looked for in the repo's worker marker (`project <path>`, which
# launch.sh writes) and in classify_session, the session's own folder. A
# marker only says where to look: distribution.sh reads the Project's
# origin, so a marker a worker rewrote cannot make another repo one. The
# caller sets classify_distribution_sh to distribution.sh's path and
# classify_session; with no distribution.sh this does nothing.
classify_distribution() {
    [ -f "${classify_distribution_sh:-}" ] || return 0
    case "$matched" in "git push"* | "git subtree push"*) ;; *) return 0 ;; esac
    _ctop=$("${classify_git_cmd:-git}" -C "$classify_dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    _ctop=$(CDPATH= cd -- "$_ctop" 2>/dev/null && pwd -P) || return 0
    _cmarker=$("${classify_git_cmd:-git}" -C "$_ctop" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null)
    _cproj=""
    [ ! -f "$_cmarker" ] || _cproj=$(sed -n 's/^project //p' "$_cmarker" | head -n 1)
    for _cp in "$_cproj" "${classify_session:-}"; do
        [ -n "$_cp" ] && [ -d "$_cp" ] || continue
        _cp=$(CDPATH= cd -- "$_cp" && pwd -P) || continue
        _cptop=$("${classify_git_cmd:-git}" -C "$_cp" rev-parse --show-toplevel 2>/dev/null) || continue
        [ "$_cptop" != "$_ctop" ] || continue
        if [ "$(sh "$classify_distribution_sh" --dir "$_cp" </dev/null 2>/dev/null)" = "$_ctop" ]; then
            matched="$matched in Distribution repo $_ctop"
            classify_dir=$_cp
            return 0
        fi
    done
}

# gh_words <args after "gh">: sets gh_sub and gh_act to the subcommand and
# its action, passing over a repo flag (-R <repo>, -R=<repo>, -R<repo>,
# --repo <repo>, --repo=<repo>) wherever gh takes one: before the
# subcommand, between it and its action, or after the action (#119).
# gh_pre is the count of words before the subcommand. actions.sh reads gh
# commands with it too.
gh_words() {
    gh_sub="" gh_act="" gh_pre=0
    while [ $# -gt 0 ] && [ -z "$gh_act" ]; do
        case "$1" in
        -R | --repo)
            [ -n "$gh_sub" ] || gh_pre=$((gh_pre + ($# >= 2 ? 2 : 1)))
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            continue
            ;;
        --repo=* | -R?*) [ -n "$gh_sub" ] || gh_pre=$((gh_pre + 1)); shift; continue ;;
        esac
        if [ -z "$gh_sub" ]; then gh_sub=$1; else gh_act=$1; fi
        shift
    done
}

classify_gh() {
    gh_words "$@"
    case "$gh_sub/$gh_act" in
    pr/create | pr/new) matched="gh pr create" ;;
    pr/merge) matched="gh pr merge" ;;
    issue/close) matched="gh issue close" ;;
    issue/comment)
        # The comment grant posts a new comment only (#113). Editing or
        # deleting the last one is named apart, so no grant covers it. Any
        # word that is the flag counts, even one gh would read as a body;
        # the first one found names the form, and both are refused. Every
        # word is looked at, the ones before the action included, since a
        # repo flag may stand between the subcommand and its action.
        matched="gh issue comment"
        for _carg in "$@"; do
            case "$_carg" in
            --edit-last | --edit-last=*) matched="gh issue comment (edit)"; break ;;
            --delete-last | --delete-last=*) matched="gh issue comment (delete)"; break ;;
            esac
        done
        ;;
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
        # header's value -- leaves it a plain gh api write, never granted,
        # as is a PATCH or DELETE of a comment (#113). A GraphQL mutation is
        # never granted either, addComment and createIssue included; ADR
        # 0005 says why. The words after `api` are the request.
        shift $((gh_pre + 1))
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
# which do not say which action they reach, and an issue comment's edit or
# delete (#113). The two gh api POSTs above that name an issue comment or a
# new issue map to that action (#110).
grant_action() { # <matched>
    case "$1" in
    "git push (piped"* | "gh (piped"*) ;;
    *" in Distribution repo "*) echo distribution-push ;;
    "git push"* | "git subtree push"* | "git send-pack"*) echo push ;;
    "gh pr create"*) echo pr-create ;;
    "gh pr merge"*) echo pr-merge ;;
    "gh issue close"*) echo issue-close ;;
    "gh issue comment" | "gh api POST (issue comment)") echo issue-comment ;;
    "gh issue create"* | "gh api POST (issue create)") echo issue-create ;;
    esac
}
