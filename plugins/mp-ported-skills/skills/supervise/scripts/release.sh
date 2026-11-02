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
# marker names it on its `distribution` line, and the launch record
# (marker.sh, #164) once DIR's marker is gone. Before removing DIR's marker
# this writes that line to ID's launch record, so a later resume.sh or
# push.sh holds the repo the launch checked, not what origin names by then.
# With neither a `distribution` line nor a record, the repo is read with
# distribution.sh, and a `note` line says so when DIR's marker is there, as
# one from before the line existed. Its marker is removed first when it names ID, and
# left, with an error, when it names another worker, as DIR's is.
#
# Usage:
#   release.sh --dir DIR --id ID
#
# Prints any `note` line, then `released ID`, or `no marker in DIR`, then
# `released ID in DIST` when the Distribution repo's marker was removed.
# Exits 0 released or no marker; 1 not released.

set -u
. "$(dirname -- "$0")/marker.sh"

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

marker=$(marker_path "$DIR" 2>/dev/null) ||
    fail "$DIR is not a git checkout"
if [ -f "$marker" ]; then
    held=$(marker_holder "$marker")
    [ "$held" = "$ID" ] || fail "the marker in $DIR names worker $held, not $ID; left in place"
fi
record=$(marker_record_path "$DIR" "$ID")
if dist=$(marker_launch_dist "$DIR" "$ID"); then
    if [ -f "$marker" ]; then
        printf 'distribution%s\n' "${dist:+ $dist}" >"$record" ||
            echo "note the launch record $record was not written, so a resume of $ID after this release reads its Distribution repo from origin"
    fi
else
    # With no marker either, nothing of the launch is left to keep: the read
    # only finds a Distribution repo marker left behind.
    dist=$(sh "$(dirname -- "$0")/distribution.sh" --dir "$DIR" </dev/null 2>/dev/null)
    [ ! -f "$marker" ] ||
        echo "note no Distribution repo was recorded at $ID's launch, so it was read from origin: ${dist:-none}"
fi
dist_released=""
if [ -n "$dist" ] && dist_marker=$(marker_path "$dist" 2>/dev/null) &&
    [ -f "$dist_marker" ]; then
    dist_held=$(marker_holder "$dist_marker")
    [ "$dist_held" = "$ID" ] ||
        fail "the marker in Distribution repo $dist names worker $dist_held, not $ID; left in place"
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
