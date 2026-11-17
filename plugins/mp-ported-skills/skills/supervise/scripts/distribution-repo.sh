#!/bin/sh
# distribution-repo.sh -- sourced by launch.sh, push.sh and resuming's
# state.sh: the checks on a Distribution repo's path and the read of its
# state (#209), and launch.sh's read of whether the profile trusts it (#268), one copy, so /next cannot offer a /supervise that the launch
# then refuses. Each caller reads the path itself (distribution.sh: the
# launch and the push from origin's docs/agents/distribution-repo.md, the
# readout from the working tree's) and words each reason its own way. The
# caller sources own-repo.sh first.

# distribution_check <path> <project top>: exits 0, printing nothing, when
# path is a repo's top (own_repo_top), in its main checkout, and not the
# repo whose top (resolved, as rev-parse --show-toplevel prints it) is
# <project top>. Otherwise exits 1 and prints one reason, the first that
# holds: missing, not-top, linked-worktree or own-repo.
distribution_check() {
    [ -d "$1" ] || { echo missing; return 1; }
    distribution_top=$(own_repo_top "$1") || { echo not-top; return 1; }
    # A linked worktree's --git-dir differs from its --git-common-dir
    # (main-checkout.sh, #79).
    distribution_dirs=$(git -C "$distribution_top" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null) ||
        { echo not-top; return 1; }
    [ "$(printf '%s\n' "$distribution_dirs" | sed -n 1p)" = "$(printf '%s\n' "$distribution_dirs" | sed -n 2p)" ] ||
        { echo linked-worktree; return 1; }
    [ "$distribution_top" != "$2" ] || { echo own-repo; return 1; }
}

# distribution_state <dir>: <dir>'s branch ("(detached)" when none), its
# default branch (origin's HEAD, else a local main or master, else main),
# its uncommitted paths and the commits on HEAD no remote holds (0 with no
# remote), in distribution_branch, distribution_default, distribution_dirty
# and distribution_unpushed. Exits 1, with distribution_dirty 0, when git
# status fails. Used for the Project's own repo too.
distribution_state() {
    distribution_branch=$(git -C "$1" symbolic-ref --short -q HEAD || echo "(detached)")
    distribution_default=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD)
    distribution_default=${distribution_default#origin/}
    if [ -z "$distribution_default" ]; then
        for distribution_b in main master; do
            git -C "$1" show-ref -q --verify "refs/heads/$distribution_b" && { distribution_default=$distribution_b; break; }
        done
    fi
    distribution_default=${distribution_default:-main}
    distribution_unpushed=0
    if git -C "$1" remote | grep -q .; then
        distribution_unpushed=$(git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    fi
    distribution_dirty=0
    distribution_status=$(git -C "$1" status --porcelain) || return 1
    distribution_dirty=$(printf '%s' "$distribution_status" | grep -c '^')
    return 0
}

# distribution_trusted <path> <.claude.json>: whether the profile's
# .claude.json records the trust prompt as accepted for the repo at <path>,
# as `claude --bg --add-dir <path>` requires (#268). Claude Code records
# trust per folder in .projects["<path>"].hasTrustDialogAccepted and, for a
# folder inside a repo, looks no higher than the repo's top, so a trusted
# folder above the repo does not cover it (read from Claude Code 2.1.326).
# <path> is the resolved path distribution.sh prints, the one --add-dir
# passes. Exits 0 trusted, 1 not (a missing file trusts nothing), 2 jq
# could not read it (not JSON, .projects not an object, or no jq).
distribution_trusted() {
    [ -e "$2" ] || return 1
    jq -e --arg p "$1" '.projects[$p].hasTrustDialogAccepted == true' "$2" >/dev/null 2>&1
    case $? in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}
