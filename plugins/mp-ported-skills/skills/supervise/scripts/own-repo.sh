#!/bin/sh
# own-repo.sh -- sourced by launch.sh, push.sh and close.sh: whether a path
# names a repo of its own, at its top, as a Distribution repo must (#167).
# `git rev-parse --git-dir` succeeds in any folder inside a repo, so a plain
# folder there would pass it and every check after would read the repo
# around it. A symlinked or relative path to a repo's top passes.

# own_repo_top <dir>: prints dir resolved (pwd -P) when it is its repo's
# top; prints nothing and exits non-zero otherwise, a missing folder
# included.
own_repo_top() {
    own_repo_real=$(CDPATH= cd -- "$1" 2>/dev/null && pwd -P) || return 1
    [ "$(git -C "$own_repo_real" rev-parse --show-toplevel 2>/dev/null)" = "$own_repo_real" ] || return 1
    printf '%s\n' "$own_repo_real"
}
