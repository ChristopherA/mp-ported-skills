#!/bin/sh
# release.sh -- remove a supervised worker's marker from its checkout, once
# the worker is stopped or removed (#76).
#
# launch.sh and resume.sh write the worker's id to the marker
# `git rev-parse --git-path mp-supervise-worker` in the checkout, and while
# it is there the read-only hook (scripts/supervise-read-only.sh) refuses an
# attended session's edits and state-changing git commands in it. This
# removes the marker when it names ID, and leaves one naming another worker
# in place.
#
# A Project with a Distribution repo (#125) has a marker there too. DIR's
# marker names it on a `distribution <path>` line; without one, the repo is
# read with distribution.sh. Its marker is removed first when it names ID,
# and left when it names another worker.
#
# Usage:
#   release.sh --dir DIR --id ID
#
# Prints `released ID`, or `no marker in DIR`, then `released ID in DIST`
# when the Distribution repo's marker was removed. Exits 0 released or no
# marker; 1 not released.

set -u

DIR=""
ID=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) need_value "$@"; DIR="$2"; shift 2 ;;
        --id)  need_value "$@"; ID="$2"; shift 2 ;;
        --help)
            printf 'Usage: release.sh --dir DIR --id ID\n'
            printf 'Removes the worker'\''s marker from the checkout. Outputs: released ID, or no marker in DIR\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)

marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) ||
    fail "$DIR is not a git checkout"
dist=""
if [ -f "$marker" ]; then
    held=$(head -n 1 "$marker")
    [ "$held" = "$ID" ] || fail "the marker in $DIR names worker $held, not $ID; left in place"
    dist=$(sed -n 's/^distribution //p' "$marker")
fi
[ -n "$dist" ] || dist=$(sh "$(dirname -- "$0")/distribution.sh" --dir "$DIR" </dev/null 2>/dev/null)
dist_released=""
if [ -n "$dist" ] && dist_marker=$(git -C "$dist" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null) &&
    [ -f "$dist_marker" ] && [ "$(head -n 1 "$dist_marker")" = "$ID" ]; then
    command rm -f "$dist_marker" || fail "could not remove $dist_marker"
    dist_released=1
fi
if [ -f "$marker" ]; then
    command rm -f "$marker" || fail "could not remove $marker"
    echo "released $ID"
else
    echo "no marker in $DIR"
fi
[ -z "$dist_released" ] || echo "released $ID in $dist"
