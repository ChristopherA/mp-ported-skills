#!/bin/sh
# marker.sh -- the checkout's worker marker, for the supervise scripts to
# source (#137).
#
# launch.sh and resume.sh write a supervised worker's id to the marker on
# its first line, and while it is there the read-only hook
# (scripts/supervise-read-only.sh) holds an attended session read-only in
# the checkout. In a Project with a Distribution repo (#125) a second line
# names the other repo: `distribution <path>` in the Project's marker,
# `project <path>` in the Distribution repo's.
#
# Usage:
#   . "$(dirname -- "$0")/marker.sh"
#   marker=$(marker_path "$DIR")
#
# marker_path DIR prints the absolute path of DIR's marker, whether or not
# it exists, and fails, with git's error on stderr, when DIR is not in a git
# checkout. A caller that reports the failure itself sends that stderr to
# /dev/null at the call.

marker_path() {
    git -C "$1" rev-parse --path-format=absolute --git-path mp-supervise-worker
}
