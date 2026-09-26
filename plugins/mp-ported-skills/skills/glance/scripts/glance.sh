#!/bin/sh
# glance.sh -- print this session's zone reading, or why there is none.
#
# Usage: glance.sh [<project-dir> [<session-id>]]
#
# Prints the reading as status-line.sh --zone does ("41% of zone"), or one
# line naming why there is none: no session id, no jq, no status line in
# this profile, or no record yet. The project dir defaults to the working
# directory, and the session id to CLAUDE_CODE_SESSION_ID, which Claude Code
# exports to the shell.
#
# Runs the plugin's own status-line.sh --zone, never the profile's copy: a
# copy installed from an older release has no --zone and would print nothing,
# which would read as "no reading yet". The profile's copy is checked only
# for whether the status line is installed. Always exits 0.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sid=${2:-${CLAUDE_CODE_SESSION_ID:-}}
if [ -z "$sid" ]; then
    echo "No reading: this session's id is not available."
    exit 0
fi
# --zone prints nothing without jq, which would read as "no reading yet".
if ! command -v jq >/dev/null 2>&1; then
    echo "No reading: jq is not installed, and the status line needs it."
    exit 0
fi

zone=$(sh "$here/../../../scripts/status-line.sh" --zone "${1:-$PWD}" "$sid" </dev/null)
if [ -n "$zone" ]; then
    printf '%s\n' "$zone"
elif [ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh" ]; then
    echo "No reading: this profile has no status line. /setup-mp-ported-skills turns one on."
else
    echo "No reading yet: the status line writes one after this session's first response in a terminal."
fi
exit 0
