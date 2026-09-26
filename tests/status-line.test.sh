#!/bin/sh
# status-line.test.sh -- tests for the status line: render mode, --context
# and --zone.
#
# Render mode against captured-shape JSON payloads, with session titles off
# and on (line 1 against scratch repos on and off their default branch,
# detached, with a workstream and a persona), and --context and --zone
# against the record the wrapper writes, with that record's format pinned.
# Copying the status line into a profile is tested in
# status-line-copy.test.sh and setup-mp-ported-skills.test.sh. Touches no
# real profile and nothing under /tmp outside its own mktemp directory.
#
# Usage: sh tests/status-line.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/scripts"
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
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
has() { # <name> <needle> <haystack>
    case $3 in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "$3" ;; esac
}

# A project with a branch, and a record directory of its own.
proj="$work/proj"
mkdir -p "$proj"
git -C "$proj" init -q -b feature-x
export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx"
mkdir -p "$WORKSTREAM_KIT_CONTEXT_DIR"
export CLAUDE_CONFIG_DIR="$work/.claude-testprof"
mkdir -p "$CLAUDE_CONFIG_DIR"
unset MP_SMART_ZONE_K MP_SESSION_TITLE CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true

payload() { # <used_pct> <size> [session]
    printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"session_id":"%s","context_window":{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":%s},"cost":{"total_cost_usd":0}}' \
        "$proj" "${3:-s1}" "$1" "$((100 - $1))" "$2"
}
host=$(hostname -s)

# --- render ---------------------------------------------------------------
out=$(payload 4 1000000 | sh "$scripts/status-line.sh")
check "line 1" "$host · testprof » proj » feature-x" "$(printf '%s\n' "$out" | sed -n 1p)"
check "line 2 green" "[Opus] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
has "green escape" "$(printf '\033[0;32m')" "$out"

out=$(payload 12 1000000 | sh "$scripts/status-line.sh")
has "green at 120k" "$(printf '\033[0;32m')80%" "$out"
out=$(payload 15 1000000 | sh "$scripts/status-line.sh")
has "green at exactly 100%" "$(printf '\033[0;32m')100%" "$out"
out=$(payload 15 1000000 | jq -c '.context_window.total_input_tokens = 151500' | sh "$scripts/status-line.sh")
has "yellow from 101%" "$(printf '\033[0;33m')101%" "$out"
out=$(payload 20 1000000 | sh "$scripts/status-line.sh")
has "yellow at 133%" "$(printf '\033[0;33m')133%" "$out"
out=$(payload 30 1000000 | jq -c '.context_window.total_input_tokens = 298500' | sh "$scripts/status-line.sh")
has "yellow at 199%" "$(printf '\033[0;33m')199%" "$out"
out=$(payload 30 1000000 | sh "$scripts/status-line.sh")
has "red from 200%" "$(printf '\033[0;31m')200%" "$out"
out=$(payload 20 1000000 | MP_SMART_ZONE_K=300 sh "$scripts/status-line.sh")
check "zone override" "[Opus] 66% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
out=$(payload 20 1000000 | MP_SMART_ZONE_K=abc sh "$scripts/status-line.sh")
check "bad zone falls back" "[Opus] 133% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 19 1000000 | jq -c '.effort = {level: "medium"} | .context_window.total_input_tokens = 187654')
out=$(printf '%s' "$p" | sh "$scripts/status-line.sh")
check "effort and exact tokens" "[Opus|medium] 125% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 4 1000000 | jq -c '.effort = {level: "high"} | del(.model)')
out=$(printf '%s' "$p" | sh "$scripts/status-line.sh")
check "effort without a model name" "[high] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 4 1000000 | jq -c '.context_window.total_input_tokens = 0')
out=$(printf '%s' "$p" | sh "$scripts/status-line.sh")
check "zero exact tokens falls back" "[Opus] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
out=$(payload 0 1000000 | sh "$scripts/status-line.sh")
check "no usage yet: empty line 2" "" "$(printf '%s\n' "$out" | sed -n 2p)"
out=$(printf '' | sh "$scripts/status-line.sh")
check "empty stdin: nothing" "" "$out"
out=$(payload 4 1000000 | CLAUDE_CONFIG_DIR="$HOME/.claude" sh "$scripts/status-line.sh" | sed -n 1p)
check "default profile name" "$host · default » proj » feature-x" "$out"

# --- line 1 with session titles on ----------------------------------------
# A repo whose default branch is main, as origin/HEAD says.
tproj="$work/tproj"
git init -q --bare -b main "$work/origin.git"
git init -q -b main "$tproj"
git -C "$tproj" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$tproj" remote add origin "$work/origin.git"
git -C "$tproj" push -q origin main 2>/dev/null
git -C "$tproj" remote set-head origin main >/dev/null
titled() { # <dir> [<jq filter on the payload>]: render with titles on
    printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"session_id":"t1","context_window":{"used_percentage":4,"remaining_percentage":96,"context_window_size":1000000},"cost":{"total_cost_usd":0}}' "$1" \
        | jq -c "${2:-.}" | MP_SESSION_TITLE=1 sh "$scripts/status-line.sh" | plain
}
check "titles: default branch, no line 1" "[Opus] 26% of zone" "$(titled "$tproj")"
check "titles: persona" "agent: reviewer" "$(titled "$tproj" '.agent = {name: "reviewer"}' | sed -n 1p)"
git -C "$tproj" checkout -q -b prototype/foo
check "titles: another branch" "prototype/foo" "$(titled "$tproj" | sed -n 1p)"
check "titles: branch and persona" "prototype/foo » agent: reviewer" \
    "$(titled "$tproj" '.agent = {name: "reviewer"}' | sed -n 1p)"
mkdir -p "$tproj/.state"; printf 'workstream: ws1\n' > "$tproj/.state/ACTIVE.md"
check "titles: branch and workstream" "prototype/foo » ws1" "$(titled "$tproj" | sed -n 1p)"
git -C "$tproj" checkout -q main
check "titles: workstream on the default branch" "ws1" "$(titled "$tproj" | sed -n 1p)"
command rm -rf "$tproj/.state"
sha=$(git -C "$tproj" rev-parse --short HEAD)
git -C "$tproj" checkout -q --detach
check "titles: detached HEAD" "detached $sha" "$(titled "$tproj" | sed -n 1p)"
git -C "$tproj" checkout -q main
# No origin/HEAD: the default is init.defaultBranch.
lproj="$work/lproj"
git init -q -b trunk "$lproj"; git -C "$lproj" config init.defaultBranch trunk
check "titles: init.defaultBranch is the default" "[Opus] 26% of zone" "$(titled "$lproj")"
# Outside git: nothing to show, and the project name must not leak.
nproj="$work/nproj"; mkdir -p "$nproj"
check "titles: outside git, no line 1" "[Opus] 26% of zone" "$(titled "$nproj")"
out=$(titled "$tproj" '.context_window.used_percentage = 0')
check "titles: no usage yet, one empty line" "1 " "$(printf '%s\n' "$out" | wc -l | tr -d ' ') $out"
check "titles off: line 1 unchanged" "$host · testprof » tproj » main" \
    "$(printf '{"workspace":{"project_dir":"%s"},"context_window":{"used_percentage":4,"context_window_size":1000000}}' "$tproj" \
        | sh "$scripts/status-line.sh" | sed -n 1p)"
# Without jq the base can read nothing, and says so; that must still show.
nojq="$work/nojq-sl"; mkdir -p "$nojq"
for t in sh cat sed dirname basename hostname git head grep tr; do ln -s "$(command -v $t)" "$nojq/$t"; done
check "titles, no jq: the base's notice shows" "jq required" \
    "$(printf '{"workspace":{"project_dir":"%s"}}' "$tproj" | PATH="$nojq" MP_SESSION_TITLE=1 sh "$scripts/status-line.sh" | sed -n 1p)"

# --- --context ------------------------------------------------------------
command rm -f "$WORKSTREAM_KIT_CONTEXT_DIR"/*
payload 6 1000000 ctx1 | sh "$scripts/status-line.sh" >/dev/null
check "--context reads the record" \
    "context: 60k tokens, 40% of a 150k smart zone, 94% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj/" </dev/null)"
# Backdate ctx1 so "newest" does not hang on two writes in one second.
r="$WORKSTREAM_KIT_CONTEXT_DIR/claude-ctx1-zone.json"
jq '.updated = "2000-01-01T00:00:00Z"' "$r" > "$r.new" && command mv -f "$r.new" "$r"
payload 3 1000000 ctx2 | sh "$scripts/status-line.sh" >/dev/null
check "--context newest for the dir" \
    "context: 30k tokens, 20% of a 150k smart zone, 97% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj" </dev/null)"
check "--context by session" \
    "context: 60k tokens, 40% of a 150k smart zone, 94% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj" ctx1 </dev/null)"
check "--context unknown session: nothing" "" "$(sh "$scripts/status-line.sh" --context "$proj" nosuch </dev/null)"
check "--context empty session: newest" \
    "context: 30k tokens, 20% of a 150k smart zone, 97% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj" "" </dev/null)"
check "--context other dir: nothing" "" "$(sh "$scripts/status-line.sh" --context "$work/elsewhere" </dev/null)"
sh "$scripts/status-line.sh" --context >/dev/null 2>&1 </dev/null
check "--context without dir: usage exit" "2" "$?"
# Exact tokens: 68,000 in a 1M window whose whole-percent share reads 6%.
payload 6 1000000 ctx3 | jq -c '.context_window.total_input_tokens = 68000' | sh "$scripts/status-line.sh" >/dev/null
check "--context exact tokens" \
    "context: 68k tokens, 45% of a 150k smart zone, 94% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj" ctx3 </dev/null)"
check "--context matches line 2" "[Opus] 45% of zone" \
    "$(payload 6 1000000 ctx3 | jq -c '.context_window.total_input_tokens = 68000' | sh "$scripts/status-line.sh" | sed -n 2p | plain)"
check "--context leaves the base record alone" "6" \
    "$(jq -r '100 - .remaining_pct' "$WORKSTREAM_KIT_CONTEXT_DIR/claude-ctx3-context.json")"
payload 0 1000000 ctx4 | sh "$scripts/status-line.sh" >/dev/null
check "no usage yet: no record" "no" "$([ -f "$WORKSTREAM_KIT_CONTEXT_DIR/claude-ctx4-zone.json" ] && echo yes || echo no)"

# --- --zone ---------------------------------------------------------------
check "--zone reads the session's record" "45% of zone" "$(sh "$scripts/status-line.sh" --zone "$proj" ctx3 </dev/null)"
check "titles: --context unchanged" "context: 68k tokens, 45% of a 150k smart zone, 94% of window remaining" \
    "$(MP_SESSION_TITLE=1 sh "$scripts/status-line.sh" --context "$proj" ctx3 </dev/null)"
out=$(sh "$scripts/status-line.sh" --zone "$proj" nosuch </dev/null); rc=$?
check "--zone unknown session: nothing" "" "$out"
check "--zone unknown session: exit 0" "0" "$rc"
sh "$scripts/status-line.sh" --zone "$proj" >/dev/null 2>&1 </dev/null
check "--zone without session: usage exit" "2" "$?"
check "--zone threshold override" "22% of zone" \
    "$(MP_SMART_ZONE_K=300 sh "$scripts/status-line.sh" --zone "$proj" ctx3 </dev/null)"

# The record format, pinned on both sides. The profile's installed copy
# writes the record and the plugin's copy may read it, so a change to the
# writer's keys or types, or to what the readers expect, must fail here.
check "record: the writer's keys and types" \
    "project_dir:string remaining_pct:number session_id:string tokens:number updated:string" \
    "$(jq -r 'to_entries | sort_by(.key) | map("\(.key):\(.value | type)") | join(" ")' "$WORKSTREAM_KIT_CONTEXT_DIR/claude-ctx3-zone.json")"
printf '{"session_id":"pin1","project_dir":"%s","tokens":61500,"remaining_pct":88,"updated":"2026-01-01T00:00:00Z"}\n' "$proj" \
    > "$WORKSTREAM_KIT_CONTEXT_DIR/claude-pin1-zone.json"
check "record: --zone reads a written-by-hand record" "41% of zone" \
    "$(sh "$scripts/status-line.sh" --zone "$proj" pin1 </dev/null)"
check "record: --context reads the same record" \
    "context: 61k tokens, 41% of a 150k smart zone, 88% of window remaining" \
    "$(sh "$scripts/status-line.sh" --context "$proj" pin1 </dev/null)"

echo "status-line: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
