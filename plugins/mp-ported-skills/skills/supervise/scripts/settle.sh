#!/bin/sh
# settle.sh -- stop a background session and wait until it has settled, for
# stop.sh and resume.sh to source (#137).
#
# Runs `claude stop ID`, then reads `claude agents --json --all` every
# INTERVAL seconds and hands each list, and ID, to VERDICT, a function that
# prints one word for the session: `pid` (its row shows a pid), `nopid` (it
# shows none), or any other word, which ends the wait with that word.
# Settled is the first of:
#   - VERDICT prints a word other than `pid` and `nopid`, such as
#     `stopped` or `gone`;
#   - the row has shown no pid for SETTLE seconds, which ends the wait with
#     `stopped`. `stopped` may never show (#77 saw it missing 30 seconds
#     after a stop that had finished), and a resume issued the moment the
#     pid went started a copy, while the same resume 47 seconds later woke
#     the original. A pid showing again starts the settle time over.
# A stop (either of the above ending with `stopped`) waits too until
# ROSTER, the daemon's roster file, no longer lists ID among its workers.
# The daemon lets the job go a moment after `claude agents` shows it
# stopped, and `claude --bg --resume` starts a copy while it still holds
# the job, "already running in the background" (#185). A roster jq cannot
# read, as mid-write, is read again; no roster file, or an empty ROSTER,
# means no daemon holds the job.
# The stop's own status is not read, since stopping a stopped session may
# fail; the wait is what decides.
#
# Usage:
#   . "$(dirname -- "$0")/settle.sh"
#   v=$(stop_and_settle ID SETTLE INTERVAL TIMEOUT VERDICT [ROSTER]) || fail "$v"
#
# On settling, prints the word that ended the wait and returns 0. When the
# list cannot be read, VERDICT fails, or TIMEOUT seconds pass, prints why
# and returns 1; the caller adds what it did not do.
#
# settle_row LIST ID is the plain VERDICT: `gone` when the list no longer
# holds the session, else `stopped`, `pid` or `nopid` from its row.

settle_row() {
    printf '%s' "$1" | jq -er --arg id "$2" '
        ([.[] | select(.kind == "background" and .id == $id)] | first) as $row
        | if $row == null then "gone"
          elif $row.state == "stopped" then "stopped"
          elif $row.pid == null then "nopid"
          else "pid" end' 2>/dev/null
}

# settle_held ROSTER ID: true while ROSTER lists ID among the daemon's
# workers, or cannot be read.
settle_held() {
    [ -n "$1" ] && [ -f "$1" ] || return 1
    jq -e --arg id "$2" '.workers | has($id) | not' "$1" >/dev/null 2>&1 && return 1
    return 0
}

stop_and_settle() {
    settle_id=$1 settle_for=$2 settle_every=$3 settle_limit=$4 settle_verdict=$5 settle_roster=${6:-}
    claude stop "$settle_id" </dev/null >/dev/null 2>&1
    settle_begin=$(date +%s)
    settle_since=""
    while :; do
        settle_list=$(claude agents --json --all </dev/null) || {
            echo "claude agents --json --all failed, so session $settle_id's state is unknown"
            return 1
        }
        settle_v=$("$settle_verdict" "$settle_list" "$settle_id") || {
            echo "claude agents --json --all printed no list jq could read, so session $settle_id's state is unknown"
            return 1
        }
        settle_now=$(date +%s)
        case $settle_v in
            pid) settle_since="" ;;
            nopid)
                [ -n "$settle_since" ] || settle_since=$settle_now
                [ $((settle_now - settle_since)) -lt "$settle_for" ] || settle_v=stopped ;;
        esac
        case $settle_v in
            pid | nopid) ;;
            stopped) settle_held "$settle_roster" "$settle_id" || { echo stopped; return 0; } ;;
            *) echo "$settle_v"; return 0 ;;
        esac
        [ $((settle_now - settle_begin)) -lt "$settle_limit" ] || {
            if [ "$settle_v" = stopped ]; then
                echo "session $settle_id was still in the daemon's roster ${settle_limit}s after claude stop"
            else
                echo "session $settle_id was not stopped ${settle_limit}s after claude stop"
            fi
            return 1
        }
        sleep "$settle_every"
    done
}
