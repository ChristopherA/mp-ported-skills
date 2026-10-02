#!/bin/sh
# supervise-resume.sh -- live check that supervise's resume.sh sends a
# follow-up into the same background session, with its earlier turns in
# context.
#
# Starts `claude --bg --permission-mode auto` in a scratch folder inside this
# checkout, so no other session shares its cwd. The folder needs no trust
# step: on Claude Code 2.1.286 a --bg launch in a new folder inside the
# trusted checkout started with no `Workspace not trusted` error. It tells it
# a codeword, waits for its turn to end with watch.sh, then asks for the
# codeword through resume.sh and waits again. Checks that resume.sh woke the
# original (no copy), and that the answer is in the job's original
# transcript. Removes the session, its marker in this checkout and the
# folder. It needs `claude` and two
# model calls; without `claude` it prints SKIP and exits 0.
#
# Set MP_LIVE_MODEL to choose the model; it must support auto mode (Haiku
# 4.5 does not). Default claude-sonnet-5.
#
# Usage: sh tests/live/supervise-resume.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
: "${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR must be set, as watch.sh and resume.sh read it}"

if ! command -v claude >/dev/null 2>&1; then
    echo "supervise-resume live: SKIP (claude is not on PATH)"
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

scratch="$root/.live-resume-$$"
mkdir -p "$scratch"
token="resume-live-$$-$(date +%s)"
word="heliotrope$$"

out=$(cd "$scratch" && claude --bg --model "${MP_LIVE_MODEL:-claude-sonnet-5}" --permission-mode auto \
    "Test $token. Remember this codeword: $word. Use no tools. Reply with only OK." </dev/null 2>&1)
id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f][0-9a-f]*\)$/\1/p' | head -n 1)
if [ -z "$id" ]; then
    printf 'FAIL launch: claude --bg printed no session id:\n%s\n' "$out"
    command rm -rf "$scratch"
    exit 1
fi
echo "launched $id"
cleanup() {
    claude stop "$id" </dev/null >/dev/null 2>&1
    claude rm "$id" </dev/null >/dev/null 2>&1
    # resume.sh writes the worker's marker in the repo holding the scratch
    # folder, which is this checkout; release it so this checkout is not
    # left read-only.
    sh "$scripts/release.sh" --dir "$scratch" --id "$id" </dev/null >/dev/null 2>&1
    command rm -rf "$scratch"
}

first=$(sh "$scripts/watch.sh" --id "$id" --dir "$scratch" --interval 5 --timeout 300 </dev/null)
check "the first turn ends" done "$(printf '%s\n' "$first" | head -n 1)"

resumed=$(sh "$scripts/resume.sh" --id "$id" --dir "$scratch" \
    --prompt "Test $token. What was the codeword? Reply with only the codeword." </dev/null)
rc=$?
echo "$resumed"
check "resume.sh exits 0" 0 "$rc"
check "resume.sh woke the original, with no copy" "resumed $id" "$resumed"

second=$(sh "$scripts/watch.sh" --id "$id" --dir "$scratch" --interval 5 --timeout 300 </dev/null)
check "the follow-up turn ends" done "$(printf '%s\n' "$second" | head -n 1)"

sid=$(jq -r '.sessionId // empty' "$CLAUDE_CONFIG_DIR/jobs/$id/state.json" 2>/dev/null)
transcript=""
for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl; do
    [ -f "$t" ] && transcript=$t
done
check "the original transcript is found" yes "$([ -n "$transcript" ] && echo yes || echo no)"
if [ -n "$transcript" ]; then
    check "the follow-up prompt is in the original transcript" yes \
        "$(grep -q "Test $token. What was the codeword" "$transcript" </dev/null && echo yes || echo no)"
    answer=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | objects
        | select(.type == "text") | .text] | last // ""' "$transcript" 2>/dev/null)
    check "the follow-up answered from the earlier turn" yes \
        "$(printf '%s' "$answer" | grep -q "$word" && echo yes || echo no)"
fi

cleanup
echo "supervise-resume live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
