#!/bin/sh
# session-title.sh -- SessionStart hook: title the session
# "<project> · <profile> · <host>" when the profile has session titles on
# (MP_SESSION_TITLE=1 in its env settings).
#
# Remote Control pushes the title to claude.ai/code and the Claude app on the
# first user message. Project comes first and host last because
# claude.ai/code lists sessions flat and cuts long titles off at the end.
#
# The project is the git top-level of the session's cwd, or the folder itself
# outside a repo; the profile is named after the config home, as the status
# line names it. Fires on startup, clear and fork only (hooks.json's matcher,
# checked again here), so a /rename survives resume and compact. Prints
# nothing, and exits 0, whenever it sets no title. Reads the SessionStart
# payload on stdin, which Claude Code closes; run by hand, pipe one in.

[ "${MP_SESSION_TITLE:-}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
source=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null) || source=""
case $source in startup|clear|fork) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
[ -n "$cwd" ] || cwd=$PWD
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=$cwd
project=$(basename "$top")
host=$(hostname -s 2>/dev/null) || host=""
[ -n "$host" ] || { host=$(uname -n); host=${host%%.*}; }
profile=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
profile=${profile#.claude-}
[ "$profile" = ".claude" ] && profile=default
jq -cn --arg t "$project · $profile · $host" '{hookSpecificOutput: {hookEventName: "SessionStart", sessionTitle: $t}}'
