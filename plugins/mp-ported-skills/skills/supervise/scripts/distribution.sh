#!/bin/sh
# distribution.sh -- the Project's Distribution repo, when it names one
# (#125).
#
# A Project whose code is committed to a separate repo cloned beside it
# names that repo in docs/agents/distribution-repo.md, at its repo's top:
# one line giving its path, relative to that top or absolute. The worker
# still runs in the Project folder, so `gh` reads the Project's tracker, and
# edits and commits in the Distribution repo by path.
#
# Reads the file from the default branch as committed on its remote-tracking
# ref, `origin/<default>`, as grant.sh reads grants (docs/adr/0005): never
# DIR's working tree, index or local branch tip, so a worker cannot repoint
# it by committing a new path. With no such ref or no such file, the Project
# names no Distribution repo. When the working tree holds the file and the
# committed ref does not, prints a note on stderr naming it as ignored.
#
# With --working-tree, reads the working tree's copy instead, and prints no
# note: for resuming's state.sh (#142), which only reads, and whose readout
# names the repo a Project is working with now, committed or not.
#
# The path line is the first line that is not blank, not a heading (`#`),
# and not inside an HTML comment; a leading `- ` or `* ` and backticks
# around it are dropped.
#
# Usage:
#   distribution.sh --dir DIR [--working-tree]
#
# Prints the repo's absolute path (resolved when it exists, joined to the
# repo's top when it does not, so a caller can name it as missing) and exits
# 0; prints nothing and exits 0 when the Project names none. Exits 1 when the
# committed file holds no path line, or DIR is not a git checkout.

set -u

DIR=""
WORKING_TREE=0

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) need_value "$@"; DIR="$2"; shift 2 ;;
        --working-tree) WORKING_TREE=1; shift ;;
        --help)
            printf 'Usage: distribution.sh --dir DIR [--working-tree]\n'
            printf 'Prints the Distribution repo named in docs/agents/distribution-repo.md on origin, or nothing.\n'
            printf 'With --working-tree, reads the working tree copy instead.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $DIR"

FILE=docs/agents/distribution-repo.md

default=$(git -C "$DIR" symbolic-ref --short -q refs/remotes/origin/HEAD)
default=${default#origin/}
if [ -z "$default" ]; then
    for b in main master; do
        git -C "$DIR" show-ref -q --verify "refs/heads/$b" && { default=$b; break; }
    done
fi
default=${default:-main}

# The file sits at the repo's top, as supervision.md does, and a relative
# path is read from there.
top=$(git -C "$DIR" rev-parse --show-toplevel)
where="on origin/$default"
if [ "$WORKING_TREE" = 1 ]; then
    where="in the working tree"
    [ -f "$top/$FILE" ] || exit 0
    content=$(cat "$top/$FILE")
elif ! content=$(git -C "$DIR" show "origin/$default:$FILE" 2>/dev/null); then
    [ ! -f "$top/$FILE" ] ||
        printf 'note: %s is in the working tree or current branch, not on the committed origin/%s; ignored\n' "$FILE" "$default" >&2
    exit 0
fi

# A comment on one line is cut first: BSD sed looks for a range's end only
# on later lines, so the range alone would delete the path after it.
line=$(printf '%s\n' "$content" | sed -e 's/<!--.*-->//' -e '/<!--/,/-->/d' | sed -n '/^[[:space:]]*$/d; /^#/d; p' | head -n 1 |
    sed 's/^[[:space:]]*[-*][[:space:]]*//; s/^`//; s/`[[:space:]]*$//; s/[[:space:]]*$//')
[ -n "$line" ] || fail "$FILE $where names no path"

case $line in
    /*) path=$line ;;
    '~') path=$HOME ;;
    '~/'*) path="$HOME/${line#\~/}" ;;
    *) path="$top/$line" ;;
esac
if [ -d "$path" ]; then
    path=$(CDPATH= cd -- "$path" && pwd -P)
fi
printf '%s\n' "$path"
