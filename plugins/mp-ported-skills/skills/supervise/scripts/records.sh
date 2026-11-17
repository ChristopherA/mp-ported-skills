#!/bin/sh
# records.sh -- where the supervisor's records in a checkout's git folder
# are, and push.sh's record line, for the supervise scripts to source
# (#211).
#
# The records are mp-supervise-pushed (push.sh), mp-supervise-posted
# (post.sh, close.sh) and mp-supervise-watched (watch.sh), each written
# with --dir the Project folder. records_path resolves a record in the main
# git folder of the repo holding the folder it is given, the same file
# `git rev-parse --git-path <name>` names in the Project folder. So a reader
# given a worker's cwd in a linked worktree, which has a git folder of its
# own, finds the Project folder's record, not none (#182).
#
# push.sh appends one line to mp-supervise-pushed per push:
#   <key> <upstream> <old> <new> <time>
# and, for a checked push (#188), after the time:
#   ` checked-push`, a tab, the grant's citation, a tab, the check lines
#   joined by `; `
# <key> is the worker's session id for a worker's push, or `pre-launch`
# for a push /supervise makes before its first launch (#223): an opaque
# key, matched whole. <upstream> is the remote branch, as `origin/main`, or
# `distribution:origin/main` for a Distribution repo's push. A line from
# before push.sh wrote a time has four fields.
#
# Usage:
#   . "$(dirname -- "$0")/records.sh"
#   path=$(records_path FOLDER NAME)     # status 1 when FOLDER is in no repo
#   records_push_write FILE KEY UPSTREAM OLD NEW TIME [CITATION CHECKS]
#                                        # appends the line; the write's status
#   lines=$(records_push_lines FILE KEY) # KEY's lines; none for no file
#   line=$(records_push_last LINES UPSTREAM)
#                                        # the last of LINES for UPSTREAM
#   records_push_read LINE               # sets records_push_id, _upstream,
#                                        # _old, _new, _time, _mark (empty or
#                                        # checked-push), _citation, _checks
# Error text is the caller's.

records_tab=$(printf '\t')

# records_path <folder> <name>: the record's absolute path.
records_path() {
    records_common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [ -n "$records_common" ] || return 1
    printf '%s/%s\n' "$records_common" "$2"
}

# records_push_write <file> <key> <upstream> <old> <new> <time> [<citation> <checks>]:
# append one line; with a citation and checks, a checked push's. A tab or
# newline in either is written as a space, so the line keeps its layout.
records_push_write() {
    records_push_suffix=""
    if [ $# -ge 8 ]; then
        records_push_suffix=$(printf ' checked-push\t%s\t%s' "$(printf '%s' "$7" | tr '\t\n' '  ')" \
            "$(printf '%s' "$8" | tr '\t\n' '  ')")
    fi
    printf '%s %s %s %s %s%s\n' "$2" "$3" "$4" "$5" "$6" "$records_push_suffix" >>"$1"
}

# records_push_lines <file> <key>: the file's lines whose first field is
# <key>, in order. No file, or an empty path, has none.
records_push_lines() {
    [ -n "$1" ] && [ -f "$1" ] || return 0
    records_key=$2 awk '$1 == ENVIRON["records_key"]' "$1"
}

# records_push_read <line>: set the line's fields, as the header names them.
records_push_read() {
    records_push_head=${1%%"$records_tab"*}
    records_push_citation=""
    records_push_checks=""
    case $1 in
        (*"$records_tab"*)
            records_push_rest=${1#*"$records_tab"}
            records_push_citation=${records_push_rest%%"$records_tab"*}
            case $records_push_rest in
                (*"$records_tab"*) records_push_checks=${records_push_rest#*"$records_tab"} ;;
            esac ;;
    esac
    IFS=' ' read -r records_push_id records_push_upstream records_push_old records_push_new \
        records_push_time records_push_mark records_push_more <<EOF_RECORDS_LINE
$records_push_head
EOF_RECORDS_LINE
    [ "$records_push_mark" = checked-push ] || records_push_mark=""
}

# records_push_last <lines> <upstream>: the last of the lines whose
# upstream is <upstream>, or nothing. Run it in $( ) and read the line it
# prints with records_push_read.
records_push_last() {
    records_push_found=""
    while IFS= read -r records_push_line; do
        [ -n "$records_push_line" ] || continue
        records_push_read "$records_push_line"
        [ "$records_push_upstream" != "$2" ] || records_push_found=$records_push_line
    done <<EOF_RECORDS_LINES
$1
EOF_RECORDS_LINES
    [ -z "$records_push_found" ] || printf '%s\n' "$records_push_found"
}
