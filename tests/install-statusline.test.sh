#!/bin/sh
# install-statusline.test.sh -- tests for the install-statusline skill's scripts.
#
# Render mode against captured-shape JSON payloads, --context against the
# record the base writes, and install.sh against scratch profile directories:
# statusLine absent, present and the same, present and different, plus a
# behind and a locally modified installed copy. Touches no real profile and
# nothing under /tmp outside its own mktemp directory.
#
# Usage: sh tests/install-statusline.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skill="$root/plugins/mp-ported-skills/skills/install-statusline/scripts"
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
unset MP_SMART_ZONE_K CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true

payload() { # <used_pct> <size> [session]
    printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"session_id":"%s","context_window":{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":%s},"cost":{"total_cost_usd":0}}' \
        "$proj" "${3:-s1}" "$1" "$((100 - $1))" "$2"
}
host=$(hostname -s)

# --- render ---------------------------------------------------------------
out=$(payload 4 1000000 | sh "$skill/status-line.sh")
check "line 1" "$host · testprof » proj » feature-x" "$(printf '%s\n' "$out" | sed -n 1p)"
check "line 2 green" "[Opus] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
has "green escape" "$(printf '\033[0;32m')" "$out"

out=$(payload 12 1000000 | sh "$skill/status-line.sh")
has "yellow at 120k" "$(printf '\033[0;33m')80%" "$out"
out=$(payload 10 1000000 | sh "$skill/status-line.sh")
has "green at 66%" "$(printf '\033[0;32m')66%" "$out"
out=$(payload 10 1000000 | jq -c '.context_window.total_input_tokens = 100500' | sh "$skill/status-line.sh")
has "yellow from 67%" "$(printf '\033[0;33m')67%" "$out"
out=$(payload 15 1000000 | sh "$skill/status-line.sh")
has "yellow at exactly 100%" "$(printf '\033[0;33m')100%" "$out"
out=$(payload 20 1000000 | sh "$skill/status-line.sh")
has "red past the zone" "$(printf '\033[0;31m')133%" "$out"
out=$(payload 20 1000000 | MP_SMART_ZONE_K=300 sh "$skill/status-line.sh")
check "zone override" "[Opus] 66% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
out=$(payload 20 1000000 | MP_SMART_ZONE_K=abc sh "$skill/status-line.sh")
check "bad zone falls back" "[Opus] 133% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 19 1000000 | jq -c '.effort = {level: "medium"} | .context_window.total_input_tokens = 187654')
out=$(printf '%s' "$p" | sh "$skill/status-line.sh")
check "effort and exact tokens" "[Opus | medium] 125% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 4 1000000 | jq -c '.effort = {level: "high"} | del(.model)')
out=$(printf '%s' "$p" | sh "$skill/status-line.sh")
check "effort without a model name" "[high] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
p=$(payload 4 1000000 | jq -c '.context_window.total_input_tokens = 0')
out=$(printf '%s' "$p" | sh "$skill/status-line.sh")
check "zero exact tokens falls back" "[Opus] 26% of zone" "$(printf '%s\n' "$out" | sed -n 2p | plain)"
out=$(payload 0 1000000 | sh "$skill/status-line.sh")
check "no usage yet: empty line 2" "" "$(printf '%s\n' "$out" | sed -n 2p)"
out=$(printf '' | sh "$skill/status-line.sh")
check "empty stdin: nothing" "" "$out"
out=$(payload 4 1000000 | CLAUDE_CONFIG_DIR="$HOME/.claude" sh "$skill/status-line.sh" | sed -n 1p)
check "default profile name" "$host · default » proj » feature-x" "$out"

# --- --context ------------------------------------------------------------
command rm -f "$WORKSTREAM_KIT_CONTEXT_DIR"/*
payload 6 1000000 ctx1 | sh "$skill/status-line.sh" >/dev/null
check "--context reads the record" \
    "context: 60k tokens, 40% of a 150k smart zone, 94% of window remaining" \
    "$(sh "$skill/status-line.sh" --context "$proj/" </dev/null)"
# Backdate ctx1 so "newest" does not hang on two writes in one second.
r="$WORKSTREAM_KIT_CONTEXT_DIR/claude-ctx1-context.json"
jq '.updated = "2000-01-01T00:00:00Z"' "$r" > "$r.new" && command mv -f "$r.new" "$r"
payload 3 1000000 ctx2 | sh "$skill/status-line.sh" >/dev/null
check "--context newest for the dir" \
    "context: 30k tokens, 20% of a 150k smart zone, 97% of window remaining" \
    "$(sh "$skill/status-line.sh" --context "$proj" </dev/null)"
check "--context by session" \
    "context: 60k tokens, 40% of a 150k smart zone, 94% of window remaining" \
    "$(sh "$skill/status-line.sh" --context "$proj" ctx1 </dev/null)"
check "--context unknown session: nothing" "" "$(sh "$skill/status-line.sh" --context "$proj" nosuch </dev/null)"
check "--context empty session: newest" \
    "context: 30k tokens, 20% of a 150k smart zone, 97% of window remaining" \
    "$(sh "$skill/status-line.sh" --context "$proj" "" </dev/null)"
check "--context other dir: nothing" "" "$(sh "$skill/status-line.sh" --context "$work/elsewhere" </dev/null)"
sh "$skill/status-line.sh" --context >/dev/null 2>&1 </dev/null
check "--context without dir: usage exit" "2" "$?"

# --- install.sh -----------------------------------------------------------
inst() { sh "$skill/install.sh" --config-dir "$prof" "$@" </dev/null; }
sl_cmd='sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh"'

# statusLine absent (no settings.json at all)
prof="$work/prof-absent"; mkdir -p "$prof"
out=$(inst --dry-run); rc=$?
check "absent: dry run exits 1" "1" "$rc"
has "absent: would create" "+ scripts/status-line.sh" "$out"
has "absent: would set statusLine" "+ statusLine" "$out"
check "absent: dry run writes nothing" "" "$(ls -A "$prof")"
out=$(inst); rc=$?
check "absent: install exits 0" "0" "$rc"
check "absent: statusLine set" "$sl_cmd" "$(jq -r .statusLine.command "$prof/settings.json")"
check "absent: stamp names both files" "2" "$(grep -cE '^status-line(-base)?\.sh [0-9a-f]{64}$' "$prof/scripts/status-line.source")"
check "base copied unmodified" "" "$(cmp "$skill/status-line-base.sh" "$prof/scripts/status-line-base.sh")"

# statusLine present and the same: a re-run is a no-op
out=$(inst --dry-run); rc=$?
check "same: dry run exits 0" "0" "$rc"
has "same: in sync" "= statusLine  runs this copy" "$out"
out=$(inst); check "same: real run exits 0" "0" "$?"
has "same: nothing written" "In sync. Nothing written." "$out"

# The installed command renders, and its --context reads.
out=$(payload 7 1000000 inst1 | CLAUDE_CONFIG_DIR="$prof" sh -c "$(jq -r .statusLine.command "$prof/settings.json")" | plain)
check "installed command renders" "[Opus] 46% of zone" "$(printf '%s\n' "$out" | sed -n 2p)"
check "installed command names its profile" "$host · prof-absent » proj » feature-x" "$(printf '%s\n' "$out" | sed -n 1p)"

# The command follows CLAUDE_CONFIG_DIR at run time: settings copied into
# another profile run that profile's copy, not the one installed from.
prof2="$work/.claude-copied"; mkdir -p "$prof2/scripts"
command cp "$prof/settings.json" "$prof2/settings.json"
printf '#!/bin/sh\necho copied-profile-script\n' > "$prof2/scripts/status-line.sh"
out=$(payload 7 1000000 inst1 | CLAUDE_CONFIG_DIR="$prof2" sh -c "$(jq -r .statusLine.command "$prof2/settings.json")")
check "command follows CLAUDE_CONFIG_DIR" "copied-profile-script" "$out"
check "installed --context" "context: 70k tokens, 46% of a 150k smart zone, 93% of window remaining" \
    "$(sh "$prof/scripts/status-line.sh" --context "$proj" </dev/null)"

# statusLine present and different
prof="$work/prof-diff"; mkdir -p "$prof"
printf '{"model":"opus","statusLine":{"type":"command","command":"echo other"},"env":{"A":"1"}}\n' > "$prof/settings.json"
out=$(inst --dry-run); rc=$?
check "different: dry run exits 1" "1" "$rc"
has "different: shows current" "currently: echo other" "$out"
out=$(inst); rc=$?
check "different: refuses" "1" "$rc"
check "different: settings untouched" "echo other" "$(jq -r .statusLine.command "$prof/settings.json")"
check "different: no scripts written" "no" "$([ -d "$prof/scripts" ] && echo yes || echo no)"
out=$(inst --replace-statusline); rc=$?
check "different: replaced with flag" "0" "$rc"
check "different: now ours" "$sl_cmd" "$(jq -r .statusLine.command "$prof/settings.json")"
check "different: other keys kept" "opus 1" "$(jq -r '"\(.model) \(.env.A)"' "$prof/settings.json")"
check "different: backup kept" "echo other" "$(jq -r .statusLine.command "$prof/settings.json.pre-install-statusline")"

# behind: an unedited earlier install
printf '# an earlier release\n' > "$prof/scripts/status-line.sh"
if command -v shasum >/dev/null 2>&1; then
    old=$(shasum -a 256 "$prof/scripts/status-line.sh" | cut -d' ' -f1)
else
    old=$(sha256sum "$prof/scripts/status-line.sh" | cut -d' ' -f1)
fi
sed "s/^status-line.sh .*/status-line.sh $old/" "$prof/scripts/status-line.source" > "$work/stamp" && command mv -f "$work/stamp" "$prof/scripts/status-line.source"
out=$(inst --dry-run)
has "behind: reported" "~ scripts/status-line.sh  behind" "$out"
out=$(inst); check "behind: updates without --force" "0" "$?"
check "behind: now current" "" "$(cmp "$skill/status-line.sh" "$prof/scripts/status-line.sh")"

# locally modified: edited after install
printf '# local edit\n' >> "$prof/scripts/status-line.sh"
out=$(inst --dry-run)
has "modified: reported" "! scripts/status-line.sh  modified" "$out"
out=$(inst); rc=$?
check "modified: refuses" "1" "$rc"
check "modified: edit kept" "# local edit" "$(tail -1 "$prof/scripts/status-line.sh")"
out=$(inst --force); check "modified: --force replaces" "0" "$?"
check "modified: now current" "" "$(cmp "$skill/status-line.sh" "$prof/scripts/status-line.sh")"

# Environment errors
out=$(sh "$skill/install.sh" --config-dir "$work/nope" </dev/null 2>&1); check "missing profile: exit 2" "2" "$?"
prof="$work/prof-bad"; mkdir -p "$prof"; printf '{not json' > "$prof/settings.json"
out=$(inst 2>&1); check "invalid settings: exit 2" "2" "$?"
out=$(sh "$skill/install.sh" --bogus </dev/null 2>&1); check "bad flag: exit 2" "2" "$?"

echo "install-statusline: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
