#!/bin/sh
# worker-gate.sh -- run git or gh for a background session, refusing a
# shared action no standing grant covers (#66).
#
# worker-bin/git and worker-bin/gh call this as `worker-gate.sh <git|gh>
# <args>`; worker-path.sh puts them first on an unattended session's PATH.
# This is the argv-level half of deny-shared-actions.sh: the hook reads a
# Bash command's text, this reads the arguments git or gh was actually
# started with, so a push inside a script, behind a variable or under
# `find -exec` is caught too. Both classify with shared-action-classify.sh
# and ask skills/supervise/scripts/grant.sh about the same actions.
#
# Outside an unattended session (CLAUDE_CODE_SESSION_ATTENDED other than 0,
# or unset) it runs the real program untouched. A refusal prints the reason
# on stderr and exits 1, without running the real program.
#
# Known gaps: a program run by its full path (`/usr/bin/git push`) or with
# PATH reset never reaches a wrapper, and nor does a write made without git
# or gh at all (curl with a token).

prog=$1
shift
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# The real program: the first on PATH outside any worker-bin folder, this
# copy's or another plugin copy's (an install beside a --plugin-dir).
real=""
oldIFS=$IFS
IFS=:
for d in $PATH; do
    case "$d" in '' | */worker-bin | */worker-bin/) continue ;; esac
    [ -x "$d/$prog" ] && [ ! -d "$d/$prog" ] || continue
    real="$d/$prog"
    break
done
IFS=$oldIFS
if [ -z "$real" ]; then
    printf '%s: not found on PATH past %s\n' "$prog" "$here/worker-bin" >&2
    exit 127
fi

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exec "$real" "$@"

. "$here/shared-action-classify.sh"
matched=""
classify_git_cmd=$real
classify_base=$PWD
classify_text="$*"
classify_session=$PWD
classify_distribution_sh="$here/../skills/supervise/scripts/distribution.sh"
case "$prog" in
git) classify_git "$@" ;;
gh) classify_gh "$@" ;;
esac
[ -n "$matched" ] || exec "$real" "$@"
classify_distribution

action=$(grant_action "$matched")
# A grant is read from the repo the command acts on: `git -C <dir>`'s, or
# the working directory; for a push in a Distribution repo, its Project's
# (#141).
grant_dir=$PWD
case "$matched" in git*) grant_dir=$classify_dir ;; esac
if [ -n "$action" ] && sh "$here/../skills/supervise/scripts/grant.sh" --dir "$grant_dir" --action "$action" >/dev/null 2>&1; then
    exec "$real" "$@"
fi

printf "%s\n" "A background session cannot run '$matched' on its own (#66), from a script or otherwise: main has no branch protection. Route this through a standing grant in docs/agents/supervision.md (#58), driven by the supervisor, or leave it for the maintainer's own interactive session." >&2
exit 1
