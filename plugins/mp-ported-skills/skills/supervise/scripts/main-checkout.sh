#!/bin/sh
# main-checkout.sh -- check that a Project folder is in its repo's main
# checkout, not a linked git worktree (#79).
#
# A worker launched in a linked worktree commits to that worktree's branch,
# which nobody pushes, and launch.sh's folder checks pass it, since the
# worker's cwd matches the folder it was given. A supervisor lands in one
# without choosing to: a `claude remote-control --spawn worktree` server
# gives each session started from the Claude app its own worktree, so `.`
# resolves there. The folder is linked when its --git-dir differs from its
# --git-common-dir. Both are read with --path-format=absolute, since in a
# subfolder of the main checkout they print in different forms (an absolute
# path and ../.git) for the same folder.
#
# Usage:
#   main-checkout.sh DIR
#
# Exits 0, printing nothing, when DIR is in the main checkout or in no git
# repo (the callers check that themselves); 1, printing why, when it is in a
# linked worktree; 2 called without DIR.

set -u

DIR=${1:-}
[ -n "$DIR" ] || { printf 'Error: usage: main-checkout.sh DIR\n' >&2; exit 2; }
dirs=$(git -C "$DIR" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null) || exit 0
[ "$(printf '%s\n' "$dirs" | sed -n 1p)" != "$(printf '%s\n' "$dirs" | sed -n 2p)" ] || exit 0
top=$(git -C "$DIR" rev-parse --show-toplevel)
branch=$(git -C "$DIR" symbolic-ref --short -q HEAD || echo "(detached)")
main=$(git -C "$DIR" worktree list --porcelain | sed -n '1s/^worktree //p')
printf '%s is a linked git worktree on branch %s, not the main checkout %s; a worker there would commit to a branch nobody pushes, so run /supervise from %s\n' \
    "$top" "$branch" "$main" "$main"
exit 1
