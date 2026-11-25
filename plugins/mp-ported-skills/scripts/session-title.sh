#!/bin/sh
# session-title.sh -- SessionStart hook: title the session
# `[branch » ][workstream » ]<repo> (<tag>) » <host>` when the profile has
# session titles on (MP_SESSION_TITLE=1 in its env settings). This is the
# format the maintainer's shell wrapper names a session in with -n, so a
# session reads the same however it was started.
#
# - branch: the cwd's branch, left out on main or master; `detached` when
#   HEAD is detached; left out outside git.
# - workstream: the name after `workstream:` in the first 10 lines of the
#   repo's .state/ACTIVE.md (else .claude/ACTIVE.md), quotes dropped, read as
#   status-line-base.sh reads it so the title and status line agree. Left out
#   when there is none or it reads `none`. A persona
#   (CLAUDE_SESSION_PERSONA) goes before it as `persona@workstream`, or stands
#   alone when there is no workstream.
# - repo: the git top-level of the session's cwd, or the folder itself
#   outside a repo.
# - tag: session_tag (session-tag.sh): the first line of
#   $CLAUDE_CONFIG_DIR/session-tag, or the profile's name.
#
# Remote Control may push the title to claude.ai/code and the Claude app on
# the first user message; in some project folders it keeps its own generated
# name instead. Fires on startup, clear and fork only (hooks.json's matcher,
# checked again here), so a /rename survives resume and compact. Prints
# nothing, and exits 0, whenever it sets no title. Reads the SessionStart
# payload on stdin, which Claude Code closes; run by hand, pipe one in.
#
# A session the maintainer's shell wrapper started already has a title: the
# wrapper passes -n and sets CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX in the
# same launch, so with the variable set the hook sets none. Sessions started
# without the wrapper, such as new ones from the Claude app, get this title.

[ "${MP_SESSION_TITLE:-}" = 1 ] || exit 0
[ -z "${CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
helper="$(dirname -- "$0")/session-tag.sh"
[ -f "$helper" ] || exit 0
. "$helper"
input=$(cat)
source=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null) || source=""
case $source in startup|clear|fork) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
[ -n "$cwd" ] || cwd=$PWD

branch=""
if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch=""
    case $branch in
        main|master) branch="" ;;
        "") branch=detached ;;
    esac
else
    top=$cwd
fi
repo=$(basename "$top")

work=""
active="$top/.state/ACTIVE.md"
[ -f "$active" ] || active="$top/.claude/ACTIVE.md"
if [ -f "$active" ]; then
    work=$(head -n 10 "$active" 2>/dev/null | sed -n 's/^workstream:[[:space:]]*//p' | head -n 1 \
        | tr -d '"' | sed 's/[[:space:]]*$//') || work=""
    [ "$work" = none ] && work=""
fi
persona=${CLAUDE_SESSION_PERSONA:-}
if [ -n "$persona" ]; then
    work="$persona${work:+@$work}"
fi

host=$(hostname -s 2>/dev/null) || host=""
[ -n "$host" ] || { host=$(uname -n); host=${host%%.*}; }
tag=$(session_tag "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")

t="$repo ($tag) » $host"
[ -z "$work" ] || t="$work » $t"
[ -z "$branch" ] || t="$branch » $t"
jq -cn --arg t "$t" '{hookSpecificOutput: {hookEventName: "SessionStart", sessionTitle: $t}}'
