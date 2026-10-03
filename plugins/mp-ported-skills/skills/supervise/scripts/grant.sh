#!/bin/sh
# grant.sh -- whether a shared action has a standing grant (#58).
#
# Reads docs/agents/supervision.md from the default branch as committed on
# its remote-tracking ref, `origin/<default>` (never DIR's working tree,
# index, or local branch tip): a worker commits directly on the default
# branch in DIR (ADR 0003), so a fake grant it commits locally is ignored
# until something pushes it, and deny-shared-actions.sh is what stops the
# worker from being the one to do that. With no such ref -- no origin, or
# the default branch never pushed -- every action is ungranted; that is the
# safe default, not an error.
#
# The file's "## Grants" section holds one bullet per line:
#   - <action>
#   - <action>: <note>
# <action> is push, pr-create, pr-merge, issue-close, issue-comment or
# issue-create. The first match
# wins; its whole bullet text (action, and the note if any) is the citation.
#
# Usage:
#   grant.sh --dir DIR --action <push|pr-create|pr-merge|issue-close|issue-comment|issue-create>
#
# Prints the citation and exits 0 when granted. Exits 1 with nothing on
# stdout when not: no file at that ref, no "## Grants" section, or no
# matching bullet. When the working tree or current branch holds a grant for
# the same action that the committed ref does not, prints a note on stderr
# naming it as ignored -- a worker's own commit, or one not yet pushed.

set -u

DIR=""
ACTION=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    need_value "$@"; DIR="$2"; shift 2 ;;
        --action) need_value "$@"; ACTION="$2"; shift 2 ;;
        --help)
            printf 'Usage: grant.sh --dir DIR --action <push|pr-create|pr-merge|issue-close|issue-comment|issue-create>\n'
            printf 'Prints the citation and exits 0 when the action is granted on the committed default branch; exits 1 otherwise.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
case "$ACTION" in
    push | pr-create | pr-merge | issue-close | issue-comment | issue-create) ;;
    *) fail "--action must be push, pr-create, pr-merge, issue-close, issue-comment or issue-create, not '$ACTION'" ;;
esac
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $DIR"

# grants_in <content>: the "## Grants" bullets, one per line, with the
# leading "- " stripped.
grants_in() {
    printf '%s\n' "$1" | sed -n '/^## Grants/,/^## /{/^## /d; s/^- *//p;}'
}

# matching <content>: the first bullet whose action matches, or empty.
matching() {
    grants_in "$1" | while IFS= read -r line; do
        case "$line" in
            "$ACTION" | "$ACTION":*) printf '%s\n' "$line"; break ;;
        esac
    done
}

default=$(git -C "$DIR" symbolic-ref --short -q refs/remotes/origin/HEAD)
default=${default#origin/}
if [ -z "$default" ]; then
    for b in main master; do
        git -C "$DIR" show-ref -q --verify "refs/heads/$b" && { default=$b; break; }
    done
fi
default=${default:-main}

committed=""
have_committed=0
if content=$(git -C "$DIR" show "origin/$default:docs/agents/supervision.md" 2>/dev/null); then
    committed=$content
    have_committed=1
fi

cited=""
if [ "$have_committed" -eq 1 ]; then
    cited=$(matching "$committed")
fi

if [ -n "$cited" ]; then
    printf '%s\n' "$cited"
    exit 0
fi

# Not granted on the committed ref. Note a grant that exists only on the
# working tree or the current branch's local tip, which a worker can reach
# without pushing.
local_content=""
if [ -f "$DIR/docs/agents/supervision.md" ]; then
    local_content=$(command cat "$DIR/docs/agents/supervision.md")
fi
local_cited=$(matching "$local_content")
if [ -n "$local_cited" ]; then
    printf 'note: docs/agents/supervision.md grants %s on the working tree or current branch, not on the committed origin/%s; ignored\n' "$ACTION" "$default" >&2
fi

exit 1
