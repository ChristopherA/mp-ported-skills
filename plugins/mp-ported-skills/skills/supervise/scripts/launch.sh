#!/bin/sh
# launch.sh -- start /implement #N as a background session in a Project, and
# confirm the session got what it was launched with.
#
# Runs `claude --bg --model MODEL [--effort LEVEL] --disallowedTools EnterWorktree
# --settings '{"worktree":{"bgIsolation":"none"}}' --append-system-prompt
# GRANTS --name NAME --permission-mode auto '/mattpocock-skills:implement #N'` in DIR with
# CLAUDE_CONFIG_DIR set explicitly, so the session runs under this profile
# whatever the shell would pick for DIR. Then reads the job's state.json,
# which the background service writes under that config dir, and checks that
# the session runs under the same config dir, in DIR itself (not a worktree),
# in auto mode, without EnterWorktree, with the background worktree guard
# off, with its grants text, under NAME, and at LEVEL when one was given. A session that fails a check is stopped.
# Prints the session's short id.
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
# An environment variable meant for the worker goes in an "env" block in
# --settings, never in the shell before `claude --bg`: the background service
# starts the session, so a variable set on the launching command does not
# reach it or its hooks. Checked live (#62): a SessionStart hook in the worker
# recorded a variable set before `claude --bg` as unset, and one passed as
# --settings '{"env":{...}}' as 1.
#
# The worker is told its Project's standing grants (#88) in an
# --append-system-prompt: each shared action grant.sh finds granted on the
# default branch as committed on origin (never DIR's working tree or local
# commits), that a granted one goes ahead without asking, and that any other
# ends its turn on one `Waiting on:` line naming it, which watch.sh's `needs`
# line can carry. Without it, workers asked before every push, as /implement
# and the maintainer's rules say, and the run stalled at blocked with a grant
# in place. Checked live with 2.1.286: a `claude --bg` session given
# --append-system-prompt replied with a codeword only that text held, and its
# job's respawnFlags began with the flag and its text, so it can be confirmed.
#
# Usage:
#   launch.sh --dir DIR --ticket N [--model MODEL] [--effort LEVEL]
#
# MODEL defaults to claude-sonnet-5 and must support auto mode, so a Haiku
# model is refused. LEVEL is one of claude's effort levels (low, medium,
# high, xhigh, max); without it the session runs at the model's default.
# The job's respawnFlags record --effort, so it can be confirmed: checked
# live with 2.1.286, a `claude --bg --model claude-opus-5-5 --effort medium`
# job's flags read ["--model","claude-opus-5-5","--effort","medium", ...]. MP_SUPERVISE_WAIT: seconds to wait for the job's
# state.json (default 20).
#
# The worker is named `worker <project> #N: <ticket title>` with --name,
# cut to 80 characters, so `claude agents` and the Claude app tell workers
# apart (#103): without it, Claude Code named every worker from its first
# prompt, the same for every ticket. The app adds the machine's name, so the
# name leaves it out. The title comes from `gh issue view` in DIR; when that
# fails, the name is `worker <project> #N` and a note says so. Checked
# live with 2.1.288: a `claude --bg --name` session's SessionStart title hook
# (MP_SESSION_TITLE) wrote its own title first, then the name was written
# over it, and it stayed the last custom-title in the transcript; the job's
# state.json recorded the name in .name and --name in respawnFlags, so it can
# be confirmed; a stop and a flagless `claude --bg --resume`, as resume.sh
# runs, woke the session "with its saved options (..., --name)" and kept the
# name, in .name and in `claude agents`. The hook also fires on /clear and
# fork; whether it then replaces the name is unchecked. The `backgrounded`
# line then ends ` · <name>`, and with FORCE_COLOR set its id is colored, so
# both are read past.
#
# Before launching, it checks that DIR is a git checkout on its default
# branch with a clean tree and no other live background session in it
# (#76). Once the session passes its checks, it writes the session's id to
# the marker `git rev-parse --git-path mp-supervise-worker`, which keeps an
# attended session read-only in the checkout (scripts/supervise-read-only.sh)
# until release.sh removes it.
#
# Exits 0 launched and confirmed; 1 not launched; 2 launched, failed a check
# and stopped.

set -u

DIR=""
TICKET=""
MODEL="claude-sonnet-5"
EFFORT=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    need_value "$@"; DIR="$2"; shift 2 ;;
        --ticket) need_value "$@"; TICKET="$2"; shift 2 ;;
        --model)  need_value "$@"; MODEL="$2"; shift 2 ;;
        --effort) need_value "$@"; EFFORT="$2"; shift 2 ;;
        --help)
            printf 'Usage: launch.sh --dir DIR --ticket N [--model MODEL] [--effort LEVEL]\n'
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
case $EFFORT in
    '' | low | medium | high | xhigh | max) ;;
    *) fail "--effort is low, medium, high, xhigh or max, not '$EFFORT'" ;;
esac
GUARD_OFF='{"worktree":{"bgIsolation":"none"}}'
CONFIG="${CLAUDE_CONFIG_DIR:-}"
[ -n "$CONFIG" ] || fail "CLAUDE_CONFIG_DIR is not set, so the session's profile cannot be pinned"
[ -d "$CONFIG" ] || fail "CLAUDE_CONFIG_DIR is not a directory: $CONFIG"
CONFIG=$(CDPATH= cd -- "$CONFIG" && pwd -P)
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)

set -- "$CONFIG"/plugins/cache/*/mattpocock-skills/*/skills/*/implement/SKILL.md
[ -f "$1" ] || fail "mattpocock-skills:implement is not installed under $CONFIG/plugins/cache; install mattpocock-skills first"

# The entry check (#76): the checkout is on its default branch, its tree is
# clean, and no other background session is live in it, so the worker
# starts where its commits belong and alone. The default branch is found as
# resuming's state.sh finds it.
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "$DIR is not a git checkout; not launched"
status=$(git -C "$DIR" status --porcelain) || fail "git status failed in $DIR, so its tree is unconfirmed; not launched"
dirty=$(printf '%s' "$status" | grep -c '^')
if [ "$dirty" -gt 0 ]; then
    [ "$dirty" = 1 ] && paths=path || paths=paths
    fail "$DIR has uncommitted changes ($dirty $paths); commit or clear them before launching a worker there; not launched"
fi
branch=$(git -C "$DIR" symbolic-ref --short -q HEAD || echo "(detached)")
default=$(git -C "$DIR" symbolic-ref --short -q refs/remotes/origin/HEAD)
default=${default#origin/}
if [ -z "$default" ]; then
    for b in main master; do
        git -C "$DIR" show-ref -q --verify "refs/heads/$b" && { default=$b; break; }
    done
fi
default=${default:-main}
[ "$branch" = "$default" ] || fail "$DIR is on $branch, not the default branch $default; not launched"
list=$(CLAUDE_CONFIG_DIR="$CONFIG" claude agents --json --all </dev/null 2>/dev/null) ||
    fail "claude agents --json --all failed, so other sessions in $DIR are unknown; not launched"
# A row is live unless it is stopped, or done with no pid: a finished worker
# shows done with no pid before and after claude stop. Any other state,
# unknown or missing included, counts as live. resume.sh uses the same rule.
others=$(printf '%s' "$list" | jq -er --arg d "$DIR" '
    [.[] | select(.kind == "background" and .cwd == $d and .state != "stopped"
                  and (.state != "done" or .pid != null))
     | "\(.id) (\(.state // "unknown"))"] | join(", ")' 2>/dev/null) ||
    fail "claude agents --json --all printed no list jq could read, so other sessions in $DIR are unknown; not launched"
[ -z "$others" ] || fail "another live background session in $DIR: $others; not launched"
# The marker the read-only hook reads. One left by a worker that is no
# longer live (the check above found none) is stale and is replaced below.
marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker)

# The standing grants, each as grant.sh cites it, from its source alone.
# grant.sh exits 1 both for "not granted" and for an error, so its stderr
# tells them apart: an error stops the launch rather than reading as no
# grant, and a note (a grant committed only locally) is passed on.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
errs=$(mktemp) || fail "mktemp failed, so the grants cannot be read; not launched"
granted=""
for action in push pr-create pr-merge issue-close; do
    cited=$(sh "$SCRIPT_DIR/grant.sh" --dir "$DIR" --action "$action" </dev/null 2>"$errs") &&
        granted="$granted
- $cited"
    if grep -q '^Error' "$errs"; then
        printf 'grant.sh: %s\n' "$(command cat "$errs")" >&2
        command rm -f "$errs"
        fail "grant.sh failed for $action, so the worker's grants are unknown; not launched"
    fi
    command cat "$errs" >&2
done
command rm -f "$errs"
if [ -n "$granted" ]; then
    GRANTS="You are a supervised worker, launched by /supervise. This Project's standing grants, from docs/agents/supervision.md as committed on origin/$default (push is git push; pr-create, pr-merge and issue-close are gh pr create, gh pr merge and gh issue close):$granted
A shared action one of these grants covers goes ahead without asking: when /implement reaches it, take it, and do not end your turn to ask first."
else
    GRANTS="You are a supervised worker, launched by /supervise. This Project grants no shared action: docs/agents/supervision.md, as committed on origin/$default, holds no standing grant."
fi
GRANTS="$GRANTS
A shared action no grant covers (git push, gh pr create, gh pr merge, gh issue close) is not yours to take: do not take it or try it. Finish and commit the rest of the work, then end your turn with one line naming the action you wait on, as \`Waiting on: git push origin $default\`."

# The worker's name (#103), in characters, not bytes, whatever the locale.
top=$(git -C "$DIR" rev-parse --show-toplevel)
NAME="worker ${top##*/} #$TICKET"
NAME_MAX=80
if title=$(cd "$DIR" && gh issue view "$TICKET" --json title --jq .title </dev/null 2>&1); then
    [ -z "$title" ] || NAME="$NAME: $title"
else
    printf "note: gh issue view %s failed (%s), so the worker's name leaves out the ticket's title\n" \
        "$TICKET" "$(printf '%s\n' "$title" | head -n 1)" >&2
fi
if [ "$(printf '%s' "$NAME" | LC_ALL=en_US.UTF-8 wc -m)" -gt "$NAME_MAX" ]; then
    NAME="$(printf '%s' "$NAME" | LC_ALL=en_US.UTF-8 cut -c1-$((NAME_MAX - 3)) | sed 's/ *$//')..."
fi

set -- --model "$MODEL"
[ -z "$EFFORT" ] || set -- "$@" --effort "$EFFORT"
out=$(cd "$DIR" && CLAUDE_CONFIG_DIR="$CONFIG" claude --bg "$@" \
    --disallowedTools EnterWorktree --settings "$GUARD_OFF" \
    --append-system-prompt "$GRANTS" --name "$NAME" --permission-mode auto \
    "/mattpocock-skills:implement #$TICKET" </dev/null 2>&1)
esc=$(printf '\033')
id=$(printf '%s\n' "$out" | sed "s/$esc\[[0-9;]*m//g" |
    sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)\( · .*\)\{0,1\}$/\1/p' | head -n 1)
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
jq -e --arg g "$GRANTS" '.respawnFlags as $f | [range(0; ($f | length) - 1)]
        | any(. as $i | $f[$i] == "--append-system-prompt" and $f[$i + 1] == $g)' "$job" >/dev/null ||
    reject "was not told its Project's grants: its flags hold no --append-system-prompt with them (its flags: $(jq -r '.respawnFlags // [] | join(" ")' "$job"))"
got=$(jq -r '.name // "(none recorded)"' "$job")
[ "$got" = "$NAME" ] || reject "is named '$got', not '$NAME'"
if [ -n "$EFFORT" ]; then
    jq -e --arg e "$EFFORT" '.respawnFlags as $f | [range(0; ($f | length) - 1)]
            | any(. as $i | $f[$i] == "--effort" and $f[$i + 1] == $e)' "$job" >/dev/null ||
        reject "does not run at effort $EFFORT (its flags: $(jq -r '.respawnFlags // [] | join(" ")' "$job"))"
fi

echo "$id" >"$marker" || reject "could not write the marker $marker, so this checkout is not held read-only"
echo "$id"
