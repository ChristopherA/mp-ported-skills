#!/bin/sh
# session-title.test.sh -- tests for the SessionStart hook that sets the
# session title, `[branch » ][workstream » ]<repo> (<tag>) » <host>`.
#
# Runs the command string from hooks.json, as Claude Code does, with a
# SessionStart payload on stdin: each source, the opt-in on and off, a
# working directory at a repo's top, in its subdirectory and outside git,
# the branch on main, master, another branch and detached, the workstream
# present, absent and `none`, a persona with and without one, and the tag
# file present, empty and absent. Touches nothing outside its own mktemp
# directory.
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

# Every variable the hook reads, set or unset here, so the result does not
# depend on the session running the test.
unset MP_SESSION_TITLE CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX CLAUDE_SESSION_PERSONA 2>/dev/null || true
export CLAUDE_CONFIG_DIR="$work/.claude-testprof"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"
host=$(hostname -s)

repo="$work/myrepo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
mkdir -p "$repo/sub/dir"

title() { # <source> <cwd>: the title the hook sets, with titles on
    printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s","session_id":"s1"}' "$1" "$2" \
        | MP_SESSION_TITLE=1 sh -c "$hook_cmd" \
        | jq -r '.hookSpecificOutput.sessionTitle // empty'
}

check "startup: repo (tag) » host" "myrepo (testprof) » $host" "$(title startup "$repo")"
check "clear: titled" "myrepo (testprof) » $host" "$(title clear "$repo")"
check "fork: titled" "myrepo (testprof) » $host" "$(title fork "$repo")"
check "subdirectory: the repo's name" "myrepo (testprof) » $host" "$(title startup "$repo/sub/dir")"
outside="$work/plainfolder"; mkdir -p "$outside"
check "outside git: the folder's name, no branch" "plainfolder (testprof) » $host" \
    "$(GIT_CEILING_DIRECTORIES="$work" title startup "$outside")"
check "default profile" "myrepo (default) » $host" "$(CLAUDE_CONFIG_DIR="$HOME/.claude" title startup "$repo")"
check "profile without the .claude- prefix" "myrepo (config) » $host" \
    "$(mkdir -p "$work/config"; CLAUDE_CONFIG_DIR="$work/config" title startup "$repo")"

# The branch: left out on main or master, named otherwise, detached flagged.
git -C "$repo" checkout -q -b feature/x
check "branch: another branch goes first" "feature/x » myrepo (testprof) » $host" "$(title startup "$repo")"
git -C "$repo" checkout -q -b master
check "branch: master is left out" "myrepo (testprof) » $host" "$(title startup "$repo")"
git -C "$repo" checkout -q --detach
check "branch: detached HEAD" "detached » myrepo (testprof) » $host" "$(title startup "$repo")"
git -C "$repo" checkout -q main

# The workstream, from .state/ACTIVE.md.
mkdir -p "$repo/.state"
printf '# Active\nworkstream: zone-work\nphase: 2\n' >"$repo/.state/ACTIVE.md"
check "workstream: before the repo" "zone-work » myrepo (testprof) » $host" "$(title startup "$repo")"
check "workstream: read from a subdirectory too" "zone-work » myrepo (testprof) » $host" "$(title startup "$repo/sub/dir")"
git -C "$repo" checkout -q feature/x
check "workstream: branch first, then workstream" "feature/x » zone-work » myrepo (testprof) » $host" "$(title startup "$repo")"
git -C "$repo" checkout -q main
printf 'workstream: "quoted"\n' >"$repo/.state/ACTIVE.md"
check "workstream: quotes dropped" "quoted » myrepo (testprof) » $host" "$(title startup "$repo")"
printf 'workstream: none\n' >"$repo/.state/ACTIVE.md"
check "workstream: none leaves the slot out" "myrepo (testprof) » $host" "$(title startup "$repo")"
printf '# Active\nphase: 2\n' >"$repo/.state/ACTIVE.md"
check "workstream: no line leaves the slot out" "myrepo (testprof) » $host" "$(title startup "$repo")"
printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nworkstream: late\n' >"$repo/.state/ACTIVE.md"
check "workstream: past line 10 is not read, as the status line" "myrepo (testprof) » $host" "$(title startup "$repo")"
command rm -f "$repo/.state/ACTIVE.md"
mkdir -p "$repo/.claude"; printf 'workstream: old-home\n' >"$repo/.claude/ACTIVE.md"
check "workstream: .claude/ACTIVE.md when .state has none" "old-home » myrepo (testprof) » $host" "$(title startup "$repo")"
command rm -rf "$repo/.claude"
check "workstream: no file leaves the slot out" "myrepo (testprof) » $host" "$(title startup "$repo")"

# The persona: before the workstream as persona@workstream, or alone.
check "persona: alone with no workstream" "pete » myrepo (testprof) » $host" \
    "$(export CLAUDE_SESSION_PERSONA=pete; title startup "$repo")"
printf 'workstream: zone-work\n' >"$repo/.state/ACTIVE.md"
check "persona: persona@workstream" "pete@zone-work » myrepo (testprof) » $host" \
    "$(export CLAUDE_SESSION_PERSONA=pete; title startup "$repo")"
check "persona: empty is no persona" "zone-work » myrepo (testprof) » $host" \
    "$(export CLAUDE_SESSION_PERSONA=; title startup "$repo")"
command rm -f "$repo/.state/ACTIVE.md"

# The tag: the session-tag file's first line overrides the profile's name.
printf 'mp\nsecond line\n' >"$CLAUDE_CONFIG_DIR/session-tag"
check "tag: the file's first line" "myrepo (mp) » $host" "$(title startup "$repo")"
printf '  mp  \n' >"$CLAUDE_CONFIG_DIR/session-tag"
check "tag: spaces around it trimmed" "myrepo (mp) » $host" "$(title startup "$repo")"
: >"$CLAUDE_CONFIG_DIR/session-tag"
check "tag: an empty file falls back to the profile" "myrepo (testprof) » $host" "$(title startup "$repo")"
printf '\nmp\n' >"$CLAUDE_CONFIG_DIR/session-tag"
check "tag: an empty first line falls back to the profile" "myrepo (testprof) » $host" "$(title startup "$repo")"
command rm -f "$CLAUDE_CONFIG_DIR/session-tag"

# No title, and no output at all, so a /rename survives.
check "resume: no title" "" "$(title resume "$repo")"
check "compact: no title" "" "$(title compact "$repo")"
out=$(printf '{"source":"startup","cwd":"%s"}' "$repo" | sh -c "$hook_cmd"); rc=$?
check "opt-in unset: no output" "" "$out"
check "opt-in unset: exit 0" "0" "$rc"
check "opt-in not 1: no output" "" \
    "$(printf '{"source":"startup","cwd":"%s"}' "$repo" | MP_SESSION_TITLE=yes sh -c "$hook_cmd")"

# The shell wrapper titled the session with -n and set the prefix variable:
# no title, so the wrapper's stays.
out=$(printf '{"source":"startup","cwd":"%s"}' "$repo" \
    | MP_SESSION_TITLE=1 CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX=host-myrepo sh -c "$hook_cmd"); rc=$?
check "wrapper-named: no output" "" "$out"
check "wrapper-named: exit 0" "0" "$rc"

# A plugin copy missing the tag helper sets no title and still exits 0.
mkdir -p "$work/nohelper/scripts"
command cp -f "$CLAUDE_PLUGIN_ROOT/scripts/session-title.sh" "$work/nohelper/scripts/"
out=$(printf '{"source":"startup","cwd":"%s"}' "$repo" \
    | (export MP_SESSION_TITLE=1 CLAUDE_PLUGIN_ROOT="$work/nohelper"; sh -c "$hook_cmd" 2>&1)); rc=$?
check "no tag helper: no output" "" "$out"
check "no tag helper: exit 0" "0" "$rc"

# The title and the status line name the host and profile the same way, so
# the two agree on screen. The status line's line 1 with titles off starts
# "<host> · <profile>".
sl=$(printf '{"workspace":{"project_dir":"%s"},"context_window":{"used_percentage":4,"context_window_size":1000000}}' "$repo" \
    | sh "$CLAUDE_PLUGIN_ROOT/scripts/status-line.sh" | sed -n 1p)
t=$(title startup "$repo")      # <repo> (<tag>) » <host>
t_host=${t##* » }; t_tag=${t##*(}; t_tag=${t_tag%%)*}
check "host and profile match the status line" "${sl%% » *}" "$t_host · $t_tag"
# With a tag file, both show its tag.
printf 'mp\n' >"$CLAUDE_CONFIG_DIR/session-tag"
sl=$(printf '{"workspace":{"project_dir":"%s"},"context_window":{"used_percentage":4,"context_window_size":1000000}}' "$repo" \
    | sh "$CLAUDE_PLUGIN_ROOT/scripts/status-line.sh" | sed -n 1p)
t=$(title startup "$repo")
t_host=${t##* » }; t_tag=${t##*(}; t_tag=${t_tag%%)*}
check "tag file: the tag is the file's" "mp" "$t_tag"
check "tag file: host and profile match the status line" "${sl%% » *}" "$t_host · $t_tag"
command rm -f "$CLAUDE_CONFIG_DIR/session-tag"

# The matcher Claude Code applies before the script's own check.
check "matcher: startup, clear and fork only" "startup|clear|fork" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

echo "session-title: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
