#!/bin/sh
# session-title.test.sh -- tests for the SessionStart hook that sets the
# session title.
#
# Runs the command string from hooks.json, as Claude Code does, with a
# SessionStart payload on stdin: each source, the opt-in on and off, and a
# working directory at a repo's top, in its subdirectory and outside git.
# Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/session-title.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# The title hook is the SessionStart entry whose command runs session-title.sh.
entry='.hooks.SessionStart[] | select(.hooks[0].command | test("session-title"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

repo="$work/myrepo"
git init -q "$repo"
mkdir -p "$repo/sub/dir"
export CLAUDE_CONFIG_DIR="$work/.claude-testprof"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"
unset MP_SESSION_TITLE 2>/dev/null || true
host=$(hostname -s)

title() { # <source> <cwd>: the title the hook sets, with titles on
    printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s","session_id":"s1"}' "$1" "$2" \
        | MP_SESSION_TITLE=1 sh -c "$hook_cmd" \
        | jq -r '.hookSpecificOutput.sessionTitle // empty'
}

check "startup: project · profile · host" "myrepo · testprof · $host" "$(title startup "$repo")"
check "clear: titled" "myrepo · testprof · $host" "$(title clear "$repo")"
check "fork: titled" "myrepo · testprof · $host" "$(title fork "$repo")"
check "subdirectory: the repo's name" "myrepo · testprof · $host" "$(title startup "$repo/sub/dir")"
outside="$work/plainfolder"; mkdir -p "$outside"
check "outside git: the folder's name" "plainfolder · testprof · $host" \
    "$(GIT_CEILING_DIRECTORIES="$work" title startup "$outside")"
check "default profile" "myrepo · default · $host" "$(CLAUDE_CONFIG_DIR="$HOME/.claude" title startup "$repo")"

# No title, and no output at all, so a /rename survives.
check "resume: no title" "" "$(title resume "$repo")"
check "compact: no title" "" "$(title compact "$repo")"
out=$(printf '{"source":"startup","cwd":"%s"}' "$repo" | sh -c "$hook_cmd"); rc=$?
check "opt-in unset: no output" "" "$out"
check "opt-in unset: exit 0" "0" "$rc"
check "opt-in not 1: no output" "" \
    "$(printf '{"source":"startup","cwd":"%s"}' "$repo" | MP_SESSION_TITLE=yes sh -c "$hook_cmd")"

# The title and the status line name the host and profile the same way, so
# the two agree on screen. The status line's line 1 with titles off starts
# "<host> · <profile>".
sl=$(printf '{"workspace":{"project_dir":"%s"},"context_window":{"used_percentage":4,"context_window_size":1000000}}' "$repo" \
    | sh "$CLAUDE_PLUGIN_ROOT/scripts/status-line.sh" | sed -n 1p)
t=$(title startup "$repo")      # <project> · <profile> · <host>
t=${t#* · }; t_profile=${t% · *}; t_host=${t#* · }
check "host and profile match the status line" "${sl%% » *}" "$t_host · $t_profile"

# The matcher Claude Code applies before the script's own check.
check "matcher: startup, clear and fork only" "startup|clear|fork" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

echo "session-title: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
