# live.sh -- sourced by launch.sh, resume.sh and resuming's state.sh: which
# background sessions count as live in a checkout (#115). One rule, so
# /supervise and /next cannot disagree on it.
#
# A row is live unless it is stopped, or done with no pid: a finished worker
# shows done with no pid before and after claude stop. Any other state,
# unknown or missing included, counts as live.

# live_def: a jq def, `live`, true for a live background session's row. A
# caller with its own jq program puts it first: jq "$live_def ...".
live_def='def live: .kind == "background" and .state != "stopped" and (.state != "done" or .pid != null);'

# live_others <agents json> <dir>: the live background sessions whose cwd is
# dir, as `id (state)` joined by ", ", or nothing when there are none. Exits
# non-zero when jq cannot read the list.
live_others() {
    printf '%s' "$1" | jq -er --arg d "$2" "$live_def"'
        [.[] | select(live and .cwd == $d) | "\(.id) (\(.state // "unknown"))"] | join(", ")' 2>/dev/null
}
