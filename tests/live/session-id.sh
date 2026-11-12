# session-id.sh -- sourced by the live tests that start `claude --bg`.
#
# bg_session_id <output>: prints the session id from the `backgrounded · <id>`
# line in `claude --bg`'s output, or nothing when it holds none. Reads the
# line as supervise's launch.sh does: colour codes stripped first (with
# FORCE_COLOR set the id is coloured even with no terminal), and a
# ` · <name>` tail allowed, which a named session prints. A change to how
# launch.sh reads the line goes here too; tests/live-session-id.test.sh
# checks the two patterns match.
bg_session_id() {
    session_id_esc=$(printf '\033')
    printf '%s\n' "$1" | sed "s/$session_id_esc\[[0-9;]*m//g" |
        sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)\( · .*\)\{0,1\}$/\1/p' | head -n 1
}
