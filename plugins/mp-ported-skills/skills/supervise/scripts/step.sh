#!/bin/sh
# step.sh -- the step /supervise may launch in a Project, from resuming's
# state.sh.
#
# Runs state.sh in the Project's folder and reads its `next:` line. Prints
# `implement #N` when that step is /implement of a ready-for-agent ticket and
# nothing else is in flight: case 2, or case 1 when its only work in flight is
# an in-motion parent whose next child is ready-for-agent. When the step is
# refused only because it carries unpushed commits that a supervised run of
# the ticket accounts for, state.sh prints `continue: #N from <sha>`, and
# step.sh prints `continue #N from <sha>`: the supervisor launches a
# continuation from that start (#214). When unpushed commits no run accounts
# for are all that refuses it, state.sh prints `push: #N after ...`, and
# step.sh prints `push then implement #N`: the supervisor asks the
# maintainer to push them before it launches #N (#223). Otherwise prints
# `stop: ` and the `next:` line, for the supervisor to report. A folder in a
# linked git worktree stops first, with main-checkout.sh's reason in place of
# the `next:` line. Writes nothing.
#
# Usage:
#   step.sh DIR          run state.sh in DIR
#   step.sh --from FILE  read a saved state.sh report instead

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
state="$SCRIPT_DIR/../../resuming/scripts/state.sh"
. "$SCRIPT_DIR/accept.sh"

case "${1:-}" in
    --from)
        [ -f "${2:-}" ] || { printf 'Error: no such file: %s\n' "${2:-}" >&2; exit 1; }
        report=$(command cat "$2") ;;
    --help)
        printf 'Usage: step.sh DIR | step.sh --from FILE\n'
        printf 'Prints "implement #N", "continue #N from SHA", "push then implement #N",\n'
        printf 'or "stop: " and state.sh'\''s next: line.\n'
        exit 0 ;;
    '')
        printf 'Usage: step.sh DIR | step.sh --from FILE\n' >&2
        exit 1 ;;
    *)
        [ -d "$1" ] || { printf 'Error: not a directory: %s\n' "$1" >&2; exit 1; }
        # A linked worktree stops here, named as one (#79), before state.sh
        # would call its branch work in flight.
        linked=$(sh "$SCRIPT_DIR/main-checkout.sh" "$1" </dev/null) || { echo "stop: $linked"; exit 0; }
        report=$(sh "$state" "$1" </dev/null) ;;
esac

line=$(printf '%s\n' "$report" | sed -n 's/^next: //p' | head -n 1)
if [ -z "$line" ]; then
    echo "stop: state.sh printed no next: line"
    exit 0
fi

# Which steps it takes is accept.sh's, shared with state.sh's supervise:
# offer (#115).
n=$(accept_step "$line")
cont=$(printf '%s\n' "$report" | sed -n 's/^continue: \(#[0-9][0-9]* from [0-9a-f]\{40\}\)$/\1/p' | head -n 1)
push=$(printf '%s\n' "$report" | sed -n 's/^push: #\([0-9][0-9]*\) after [0-9][0-9]* unpushed commits; .*/\1/p' | head -n 1)
if [ -n "$n" ]; then
    echo "implement #$n"
elif [ -n "$cont" ]; then
    echo "continue $cont"
elif [ -n "$push" ]; then
    echo "push then implement #$push"
else
    echo "stop: next: $line"
fi
