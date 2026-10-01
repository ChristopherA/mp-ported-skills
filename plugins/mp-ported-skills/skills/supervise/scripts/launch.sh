#!/bin/sh
# launch.sh -- start /implement #N as a background session in a Project, and
# confirm the session got what it was launched with.
#
# Runs `claude --bg --model MODEL --disallowedTools EnterWorktree
# --settings '{"worktree":{"bgIsolation":"none"}}' --permission-mode auto
# '/mattpocock-skills:implement #N'` in DIR with
# CLAUDE_CONFIG_DIR set explicitly, so the session runs under this profile
# whatever the shell would pick for DIR. Then reads the job's state.json,
# which the background service writes under that config dir, and checks that
# the session runs under the same config dir, in DIR itself (not a worktree),
# in auto mode, without EnterWorktree, and with the background worktree
# guard off. A session that fails a check is stopped. Prints the session's
# short id.
#
# EnterWorktree is denied because /implement workers called it on their own,
# after launch, and committed on a worktree branch nobody pushed. The deny
# reaches a background session. Checked live with Claude Code 2.1.285: two
# `claude --bg --model claude-sonnet-5 [--disallowedTools EnterWorktree]
# --permission-mode auto` sessions, each told to call ToolSearch with
# "select:EnterWorktree". With the flag it returned "No matching deferred
# tools found"; without it, the EnterWorktree schema. The flagged job's
# respawnFlags began ["--disallowedTools","EnterWorktree", ...]. The flag
# takes a list, so it comes before another option, never right before the
# prompt, which it would swallow as a tool name.
#
# The guard is off because, from Claude Code 2.1.286, the background service
# refuses a session's edits in the shared checkout until it isolates in a
# worktree, and a worker denied EnterWorktree made one with `git worktree add`
# from Bash instead, keeping its cwd in DIR (#83). Checked live with 2.1.286:
# three such sessions in scratch repos, each told to create and commit a file.
# With no setting the first Write was refused and the session committed in a
# worktree it made; with --settings '{"worktree":{"bgIsolation":"none"}}', or
# the same in the repo's .claude/settings.local.json, it wrote and committed
# on main in the folder. --settings is used because it leaves the Project's
# files alone and the job's respawnFlags record it, so it can be confirmed.
#
# Usage:
#   launch.sh --dir DIR --ticket N [--model MODEL]
#
# MODEL defaults to claude-sonnet-5 and must support auto mode, so a Haiku
# model is refused. MP_SUPERVISE_WAIT: seconds to wait for the job's
# state.json (default 20).
#
# Exits 0 launched and confirmed; 1 not launched; 2 launched, failed a check
# and stopped.

set -u

DIR=""
TICKET=""
MODEL="claude-sonnet-5"

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    need_value "$@"; DIR="$2"; shift 2 ;;
        --ticket) need_value "$@"; TICKET="$2"; shift 2 ;;
        --model)  need_value "$@"; MODEL="$2"; shift 2 ;;
        --help)
            printf 'Usage: launch.sh --dir DIR --ticket N [--model MODEL]\n'
            printf 'Starts /mattpocock-skills:implement #N as a background session in DIR. Outputs: its short id\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -d "$DIR" ] || fail "not a directory: $DIR"
case $TICKET in
    '' | *[!0-9]*) fail "--ticket needs an issue number, not '$TICKET'" ;;
esac
case $MODEL in
    *haiku*) fail "$MODEL has no auto mode, so its session would stop at the first permission prompt; use a model that supports auto mode" ;;
esac
GUARD_OFF='{"worktree":{"bgIsolation":"none"}}'
CONFIG="${CLAUDE_CONFIG_DIR:-}"
[ -n "$CONFIG" ] || fail "CLAUDE_CONFIG_DIR is not set, so the session's profile cannot be pinned"
[ -d "$CONFIG" ] || fail "CLAUDE_CONFIG_DIR is not a directory: $CONFIG"
CONFIG=$(CDPATH= cd -- "$CONFIG" && pwd -P)
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)

set -- "$CONFIG"/plugins/cache/*/mattpocock-skills/*/skills/*/implement/SKILL.md
[ -f "$1" ] || fail "mattpocock-skills:implement is not installed under $CONFIG/plugins/cache; install mattpocock-skills first"

out=$(cd "$DIR" && CLAUDE_CONFIG_DIR="$CONFIG" claude --bg --model "$MODEL" \
    --disallowedTools EnterWorktree --settings "$GUARD_OFF" --permission-mode auto \
    "/mattpocock-skills:implement #$TICKET" </dev/null 2>&1)
id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)$/\1/p' | head -n 1)
if [ -z "$id" ]; then
    printf 'Error: claude --bg printed no session id:\n%s\n' "$out" >&2
    exit 1
fi

# A session that fails a check is stopped, not removed, so its transcript
# stays for reading.
reject_as() {
    CLAUDE_CONFIG_DIR="$CONFIG" claude stop "$id" </dev/null >/dev/null 2>&1
    printf 'Error: %s; stopped it\n' "$1" >&2
    exit 2
}
reject() { reject_as "session $id $1"; }

job="$CONFIG/jobs/$id/state.json"
wait=${MP_SUPERVISE_WAIT:-20}
waited=0
until jq -e .cwd "$job" >/dev/null 2>&1; do
    [ "$waited" -lt "$wait" ] ||
        reject_as "no job state for session $id under $CONFIG/jobs after ${wait}s, so its profile is unconfirmed"
    sleep 1
    waited=$((waited + 1))
done

got=$(jq -r '.providerEnv.CLAUDE_CONFIG_DIR // "(none recorded)"' "$job")
[ "$got" = "$CONFIG" ] || reject "runs under config $got, not $CONFIG"
tree=$(jq -r '.worktreePath // empty' "$job")
[ -z "$tree" ] || reject "was placed in worktree $tree, not $DIR"
got=$(jq -r .cwd "$job")
[ "$got" = "$DIR" ] || reject "runs in $got, not $DIR"
jq -e '.respawnFlags as $f | [range(0; ($f | length) - 1)]
        | any(. as $i | $f[$i] == "--permission-mode" and $f[$i + 1] == "auto")' "$job" >/dev/null ||
    reject "is not in auto mode (its flags: $(jq -r '.respawnFlags // [] | join(" ")' "$job"))"
jq -e '.respawnFlags as $f | [range(0; ($f | length) - 1)]
        | any(. as $i | $f[$i] == "--disallowedTools"
              and ($f[$i + 1] | split("[, ]+"; null) | index("EnterWorktree")) != null)' "$job" >/dev/null ||
    reject "can enter a worktree: EnterWorktree is not in its disallowed tools (its flags: $(jq -r '.respawnFlags // [] | join(" ")' "$job"))"
jq -e '.respawnFlags as $f | [range(0; ($f | length) - 1)]
        | any(. as $i | $f[$i] == "--settings"
              and (($f[$i + 1] | try fromjson catch null) | .worktree.bgIsolation? == "none"))' "$job" >/dev/null ||
    reject "has the background worktree guard on, so its edits in $DIR would be refused: bgIsolation none is not in its settings (its flags: $(jq -r '.respawnFlags // [] | join(" ")' "$job"))"

echo "$id"
