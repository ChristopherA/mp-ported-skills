#!/bin/sh
# deny-shared-actions.sh -- live check that the shared-action deny hook
# fires in a real background session.
#
# Starts `claude --bg --permission-mode auto` in this checkout, with this
# checkout's plugin loaded by --plugin-dir, and asks it to run
# `git push --dry-run` and then print CLAUDE_CODE_SESSION_ATTENDED. Finds
# the session's transcript by a token in its prompt, and checks that the
# push was refused with the hook's reason. `--dry-run` publishes nothing
# even if the hook lets it through. It lives apart from tests/*.test.sh
# because it needs `claude`, a trusted folder, and a model call; without
# `claude` it prints SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not).
#
# Usage: sh tests/live/deny-shared-actions.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

if ! command -v claude >/dev/null 2>&1; then
    echo "deny-shared-actions live: SKIP (claude is not on PATH)"
    exit 0
fi

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

token="deny-live-$$-$(date +%s)"
prompt="Test $token. Run exactly these two Bash commands, one at a time, and nothing else: first \`git push --dry-run\`, then \`echo attended=\$CLAUDE_CODE_SESSION_ATTENDED\`. If the first is refused, do not retry it in any form. Then stop."

set -- --bg --permission-mode auto --plugin-dir "$root/plugins/mp-ported-skills"
[ -n "${MP_LIVE_MODEL:-}" ] && set -- "$@" --model "$MP_LIVE_MODEL"
out=$(cd "$root" && claude "$@" "$prompt" </dev/null 2>&1)
id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)$/\1/p' | head -n 1)
if [ -z "$id" ]; then
    printf 'FAIL launch: claude --bg printed no session id:\n%s\n' "$out"
    exit 1
fi

# Wait for the second command's output, which means the first has been
# decided.
transcript=""
seen=""
waited=0
while [ "$waited" -lt "${MP_LIVE_WAIT:-180}" ]; do
    transcript=$(grep -rl --include='*.jsonl' "$token" "$config/projects" </dev/null 2>/dev/null | head -n 1)
    if [ -n "$transcript" ] && grep -q 'attended=[0-9]' "$transcript" </dev/null; then
        seen=yes
        break
    fi
    sleep 3
    waited=$((waited + 3))
done

check "transcript found and both commands ran" yes "$seen"
if [ -n "$transcript" ]; then
    check "the session is unattended" 1 \
        "$(grep -c 'attended=0' "$transcript" </dev/null | sed 's/^[1-9][0-9]*$/1/')"
    check "git push --dry-run refused with the hook's reason" 1 \
        "$(grep -c "cannot run 'git push' on its own" "$transcript" </dev/null | sed 's/^[1-9][0-9]*$/1/')"
fi

claude stop "$id" </dev/null >/dev/null 2>&1
claude rm "$id" </dev/null >/dev/null 2>&1

echo "deny-shared-actions live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
