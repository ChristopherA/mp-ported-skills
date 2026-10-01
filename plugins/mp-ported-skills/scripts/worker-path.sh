#!/bin/sh
# worker-path.sh -- SessionStart hook: in a background session, put the
# git and gh wrappers in scripts/worker-bin first on the PATH every later
# Bash command runs with (#66).
#
# deny-shared-actions.sh sees only a Bash command's text, so a script that
# pushes gets past it. The wrappers see the real argv of every git and gh
# that a command, or anything it starts, runs by name, and refuse a shared
# action no standing grant covers (worker-gate.sh).
#
# Claude Code sources CLAUDE_ENV_FILE before each Bash command
# (https://code.claude.com/docs/en/hooks.md). The gate is the same
# CLAUDE_CODE_SESSION_ATTENDED=0 deny-shared-actions.sh reads, absent read
# as attended; SessionStart's input carries no permission_mode, so this
# runs in any unattended session, auto mode or not. Runs on every source,
# since a resume or compact may start with a fresh env file, and writes its
# line once per file.

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
bin=$(CDPATH= cd -- "$(dirname -- "$0")/worker-bin" && pwd -P) || exit 0
line="export PATH='$bin':\"\$PATH\""
grep -qxF -- "$line" "$CLAUDE_ENV_FILE" 2>/dev/null || printf '%s\n' "$line" >>"$CLAUDE_ENV_FILE"
exit 0
