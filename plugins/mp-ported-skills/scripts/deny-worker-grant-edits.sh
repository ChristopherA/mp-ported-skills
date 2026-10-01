#!/bin/sh
# deny-worker-grant-edits.sh -- PreToolUse hook: refuse a background
# worker's own edit to the grant file or the profile directory (#58).
#
# A standing grant is only trustworthy if a worker cannot grant itself one:
# deny-shared-actions.sh reads docs/agents/supervision.md from the default
# branch as committed on origin, never the working tree, which keeps an
# uncommitted or unpushed edit from taking effect, but a worker could still
# edit the committed copy heading into its next commit, or edit the
# profile's own files under $CLAUDE_CONFIG_DIR (rules, settings, hooks)
# that this session, or a future one, reads. This hook refuses an Edit,
# Write or NotebookEdit whose target is docs/agents/supervision.md in the
# checkout the session is working in, or any path under $CLAUDE_CONFIG_DIR,
# in an unattended, auto-mode session -- a /supervise worker, or any other
# background session launched the same way. The maintainer's own
# interactive session, whatever its permission mode, is never in scope.
#
# Detection is CLAUDE_CODE_SESSION_ATTENDED and permission_mode, the same
# two signals deny-shared-actions.sh uses (docs/adr/0004): both must hold.
#
# Known gap: this hook sees only Edit, Write and NotebookEdit, not a file
# written from Bash (`sed -i`, `cp`, `>`, `tee`), which gets through, the
# same gap supervise-read-only.sh accepts for the attended side of this
# checkout.
#
# Reads the PreToolUse payload on stdin. Prints a deny decision and exits 0
# when the call is refused; otherwise prints nothing and exits 0. A missing
# jq or an unreadable payload lets the call through.

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

mode=$(field .permission_mode)
[ "$mode" = auto ] || exit 0

tool=$(field .tool_name)
case "$tool" in
    Edit | Write | NotebookEdit) ;;
    *) exit 0 ;;
esac

path=$(field '.tool_input.file_path // .tool_input.notebook_path')
[ -n "$path" ] || exit 0
cwd=$(field .cwd)
[ -n "$cwd" ] || cwd=$(pwd)

# resolve <path> <base>: the path made absolute against the base folder.
resolve() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        '~') printf '%s' "$HOME" ;;
        '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s/%s' "$2" "$1" ;;
    esac
}

abs=$(resolve "$path" "$cwd")

refuse() {
    jq -cn --arg reason "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

# The grant file, found from the checkout the edit lands in (the file's own
# folder, walked up to one that exists, since Write may target a path that
# is not there yet).
dir=$(dirname -- "$abs")
while [ ! -d "$dir" ] && [ "$dir" != / ]; do dir=$(dirname -- "$dir"); done
if toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    [ "$abs" = "$toplevel/docs/agents/supervision.md" ] &&
        refuse "A background session in auto mode cannot edit docs/agents/supervision.md on its own (#58): a worker that could grant itself a standing grant would make the grant meaningless. Leave this to the maintainer's own interactive session."
fi

# The profile directory, resolved the same way CLAUDE_CONFIG_DIR names it,
# so a trailing slash or a relative value does not defeat the prefix check.
cfg=${CLAUDE_CONFIG_DIR:-}
if [ -n "$cfg" ]; then
    cfg=$(resolve "$cfg" "$HOME")
    cfg=${cfg%/}
    case "$abs" in
        "$cfg" | "$cfg"/*)
            refuse "A background session in auto mode cannot edit its own profile directory ($cfg) on its own (#58): that is where this session's rules, settings and hooks live, and a worker that could change them could change what gates it. Leave this to the maintainer's own interactive session." ;;
    esac
fi

exit 0
