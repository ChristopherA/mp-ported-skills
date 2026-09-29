#!/bin/sh
# step.sh -- the step /supervise may launch in a Project, from resuming's
# state.sh.
#
# Runs state.sh in the Project's folder and reads its `next:` line. Prints
# `implement #N` when that step is /implement of a ready-for-agent ticket and
# nothing else is in flight: case 2, or case 1 when its only work in flight is
# an in-motion parent whose next child is ready-for-agent. Otherwise prints
# `stop: ` and the `next:` line, for the supervisor to report. Writes nothing.
#
# Usage:
#   step.sh DIR          run state.sh in DIR
#   step.sh --from FILE  read a saved state.sh report instead

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
state="$SCRIPT_DIR/../../resuming/scripts/state.sh"

case "${1:-}" in
    --from)
        [ -f "${2:-}" ] || { printf 'Error: no such file: %s\n' "${2:-}" >&2; exit 1; }
        report=$(command cat "$2") ;;
    --help)
        printf 'Usage: step.sh DIR | step.sh --from FILE\n'
        printf 'Prints "implement #N", or "stop: " and state.sh'\''s next: line.\n'
        exit 0 ;;
    '')
        printf 'Usage: step.sh DIR | step.sh --from FILE\n' >&2
        exit 1 ;;
    *)
        [ -d "$1" ] || { printf 'Error: not a directory: %s\n' "$1" >&2; exit 1; }
        report=$(sh "$state" "$1" </dev/null) ;;
esac

line=$(printf '%s\n' "$report" | sed -n 's/^next: //p' | head -n 1)
if [ -z "$line" ]; then
    echo "stop: state.sh printed no next: line"
    exit 0
fi

# Case 2 names the ticket first. In case 1, an in-motion ticket must be the
# only work in flight (git's items come before it), and the next child's
# parentheses name /implement only for the ready-for-agent label.
n=$(printf '%s\n' "$line" | sed -n \
    -e 's/^2 \/implement #\([0-9][0-9]*\) .*/\1/p' \
    -e 's/^1 work in flight: in motion #[0-9][0-9]* [^;]*; next child #\([0-9][0-9]*\) ([^,)]*, \/implement #\1, .*/\1/p')
if [ -n "$n" ]; then
    echo "implement #$n"
else
    echo "stop: next: $line"
fi
