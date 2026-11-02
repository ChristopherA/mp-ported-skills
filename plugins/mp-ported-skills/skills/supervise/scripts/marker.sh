#!/bin/sh
# marker.sh -- the checkout's worker marker, for the supervise scripts to
# source (#137).
#
# launch.sh and resume.sh write a supervised worker's id to the marker on
# its first line, and while it is there the read-only hook
# (scripts/supervise-read-only.sh) holds an attended session read-only in
# the checkout. In a Project with a Distribution repo (#125) a second line
# names the other repo: `distribution <path>` in the Project's marker,
# `project <path>` in the Distribution repo's. A Project with none has a bare
# `distribution` line (#164), so that a marker from before that line existed,
# with no `distribution` line at all, can be told apart from one whose launch
# found no Distribution repo.
#
# The launch record (#164) keeps the marker's `distribution` line once the
# marker is gone: release.sh writes it, as
# `git rev-parse --git-path mp-supervise-launch-<id>`, before it removes the
# Project's marker, so a later resume.sh or push.sh holds the Distribution
# repo the launch checked rather than reading origin again.
#
# Usage:
#   . "$(dirname -- "$0")/marker.sh"
#   marker=$(marker_path "$DIR")
#
# marker_path DIR prints the absolute path of DIR's marker, whether or not
# it exists, and fails, with git's error on stderr, when DIR is not in a git
# checkout. A caller that reports the failure itself sends that stderr to
# /dev/null at the call.
#
# marker_holder FILE prints the worker id on FILE's first line.
#
# marker_field FILE KEY prints the value of FILE's first `KEY <value>` line,
# empty for a bare `KEY` line, and exits 1 when FILE has no such line.
#
# marker_line KEY [VALUE] prints a `KEY VALUE` line, or a bare `KEY` line
# for an empty VALUE: the form marker_field reads.
#
# marker_write FILE ID KEY [VALUE] writes a marker naming worker ID, with
# one marker_line after it, and fails when FILE cannot be written.
#
# marker_record_path DIR ID prints the absolute path of worker ID's launch
# record in DIR, whether or not it exists, and fails as marker_path does.
#
# marker_launch_dist DIR ID prints the Distribution repo worker ID's launch
# checked, empty for none: from DIR's marker while it names ID, or else from
# ID's launch record. Exits 1 when neither holds a `distribution` line.

marker_path() {
    git -C "$1" rev-parse --path-format=absolute --git-path mp-supervise-worker
}

marker_holder() {
    head -n 1 "$1"
}

marker_field() {
    awk -v k="$2" '
        $0 == k { found = 1; exit }
        index($0, k " ") == 1 { v = substr($0, length(k) + 2); found = 1; exit }
        END { if (!found) exit 1; print v }' "$1"
}

marker_line() {
    printf '%s%s\n' "$1" "${2:+ $2}"
}

marker_write() {
    { printf '%s\n' "$2"; marker_line "$3" "${4:-}"; } >"$1"
}

marker_record_path() {
    git -C "$1" rev-parse --path-format=absolute --git-path "mp-supervise-launch-$2"
}

marker_launch_dist() {
    marker_file=$(marker_path "$1" 2>/dev/null) || return 1
    if [ -f "$marker_file" ] && [ "$(marker_holder "$marker_file")" = "$2" ] &&
        marker_field "$marker_file" distribution; then
        return 0
    fi
    marker_record=$(marker_record_path "$1" "$2" 2>/dev/null) || return 1
    [ -f "$marker_record" ] && marker_field "$marker_record" distribution
}
