#!/bin/sh
# install-statusline.test.sh -- tests for the status line and its installer.
#
# Render mode against captured-shape JSON payloads, --context and --zone
# against the record the wrapper writes, with that record's format pinned,
# and install.sh against scratch profile directories: statusLine absent,
# present and the same, present and different, plus a behind, a newer
# (downgrade-guarded) and a locally modified installed copy, and a run from
# a plugin-cache copy outside git whose commit comes from
# installed_plugins.json. Touches no real profile and nothing under /tmp
# outside its own mktemp directory.
#
# Usage: sh tests/install-statusline.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skill="$root/plugins/mp-ported-skills/skills/install-statusline/scripts"
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
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
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
has "absent: created" "+ scripts/status-line.sh  created" "$out"
has "absent: statusLine set" "+ statusLine  none set; set to: $sl_cmd" "$out"
has "absent: wrote all three" "wrote $prof/scripts/{status-line.sh,status-line-base.sh,status-line.source}" "$out"
check "absent: no would in a real run" "0" "$(printf '%s\n' "$out" | grep -c would)"
check "absent: statusLine set" "$sl_cmd" "$(jq -r .statusLine.command "$prof/settings.json")"
check "absent: stamp names both files" "2" "$(grep -cE '^status-line(-base)?\.sh [0-9a-f]{64}$' "$prof/scripts/status-line.source")"
check "base copied unmodified" "" "$(cmp "$scripts/status-line-base.sh" "$prof/scripts/status-line-base.sh")"

# statusLine present and the same: a re-run is a no-op
out=$(inst --dry-run); rc=$?
check "same: dry run exits 0" "0" "$rc"
has "same: in sync" "= statusLine  runs this copy" "$out"
out=$(inst); check "same: real run exits 0" "0" "$?"
has "same: nothing written" "In sync. Nothing written." "$out"

# A stale stamp over in-sync files: an update that changed neither script.
st="$prof/scripts/status-line.source"
sed 's/^plugin: mp-ported-skills .*/plugin: mp-ported-skills 0.0.1/; s/^commit: .*/commit: 0000000/' "$st" > "$work/stamp" && command mv -f "$work/stamp" "$st"
out=$(inst --dry-run); rc=$?
check "stale stamp: dry run exits 1" "1" "$rc"
has "stale stamp: reported" "~ scripts/status-line.source  names 0.0.1 (0000000); would restamp" "$out"
check "stale stamp: dry run leaves it" "plugin: mp-ported-skills 0.0.1" "$(sed -n 1p "$st")"
base_before=$(ls -i "$prof/scripts/status-line-base.sh")
out=$(inst); check "stale stamp: real run exits 0" "0" "$?"
has "stale stamp: restamped" "~ scripts/status-line.source  names 0.0.1 (0000000); restamped" "$out"
has "stale stamp: wrote the stamp only" "wrote $prof/scripts/status-line.source" "$out"
check "stale stamp: in-sync script not rewritten" "$base_before" "$(ls -i "$prof/scripts/status-line-base.sh")"
check "stale stamp: version rewritten" \
    "plugin: mp-ported-skills $(jq -r .version "$root/plugins/mp-ported-skills/.claude-plugin/plugin.json")" "$(sed -n 1p "$st")"
check "stale stamp: commit rewritten" "commit: $(git -C "$root" rev-parse --short HEAD)" "$(sed -n 2p "$st")"
out=$(inst --dry-run); check "stale stamp: then in sync" "0" "$?"
command rm -f "$st"
out=$(inst --dry-run)
has "missing stamp: reported" "~ scripts/status-line.source  missing; would stamp" "$out"
out=$(inst)
has "missing stamp: stamped" "~ scripts/status-line.source  missing; stamped" "$out"
check "missing stamp: written" "2" "$(grep -cE '^status-line(-base)?\.sh [0-9a-f]{64}$' "$st")"

# Only statusLine changed: the in-sync scripts and current stamp are left alone.
jq '.statusLine.command = "echo other"' "$prof/settings.json" > "$work/s" && command mv -f "$work/s" "$prof/settings.json"
st_before=$(cat "$st")
out=$(inst --replace-statusline); check "statusLine only: exits 0" "0" "$?"
check "statusLine only: no scripts written" "0" "$(printf '%s\n' "$out" | grep -c ' wrote ')"
check "statusLine only: stamp untouched" "$st_before" "$(cat "$st")"
check "statusLine only: now ours" "$sl_cmd" "$(jq -r .statusLine.command "$prof/settings.json")"

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
has "different: refused run keeps the plan tense" "+ scripts/status-line.sh  would create" "$out"
check "different: settings untouched" "echo other" "$(jq -r .statusLine.command "$prof/settings.json")"
check "different: no scripts written" "no" "$([ -d "$prof/scripts" ] && echo yes || echo no)"
out=$(inst --replace-statusline); rc=$?
check "different: replaced with flag" "0" "$rc"
check "different: now ours" "$sl_cmd" "$(jq -r .statusLine.command "$prof/settings.json")"
check "different: other keys kept" "opus 1" "$(jq -r '"\(.model) \(.env.A)"' "$prof/settings.json")"
check "different: backup kept" "echo other" "$(jq -r .statusLine.command "$prof/settings.json.pre-install-statusline")"

# behind: an unedited earlier install
printf '# an earlier release\n' > "$prof/scripts/status-line.sh"
old=$(sha "$prof/scripts/status-line.sh")
sed "s/^status-line.sh .*/status-line.sh $old/" "$prof/scripts/status-line.source" > "$work/stamp" && command mv -f "$work/stamp" "$prof/scripts/status-line.source"
out=$(inst --dry-run)
has "behind: reported" "~ scripts/status-line.sh  behind" "$out"
out=$(inst); check "behind: updates without --force" "0" "$?"
has "behind: updated" "~ scripts/status-line.sh  behind: an earlier install, unedited; updated" "$out"
has "behind: wrote the changed script and stamp" "wrote $prof/scripts/{status-line.sh,status-line.source}" "$out"
check "behind: now current" "" "$(cmp "$scripts/status-line.sh" "$prof/scripts/status-line.sh")"

# newer: an unedited install from a later release than this source. Its hash
# matches the stamp just as "behind" does; only the versions tell them apart.
st="$prof/scripts/status-line.source"
setstamp() { # <version>
    printf '# a release other than this one\n' > "$prof/scripts/status-line.sh"
    sed "s/^plugin: mp-ported-skills .*/plugin: mp-ported-skills $1/; s/^status-line.sh .*/status-line.sh $(sha "$prof/scripts/status-line.sh")/" "$st" > "$work/stamp" && command mv -f "$work/stamp" "$st"
}
this=$(jq -r .version "$root/plugins/mp-ported-skills/.claude-plugin/plugin.json")
setstamp 99.0.0
out=$(inst --dry-run)
has "newer: reported" "! scripts/status-line.sh  installed 99.0.0 is newer than this $this; needs --force" "$out"
out=$(inst); rc=$?
check "newer: refuses" "1" "$rc"
check "newer: file kept" "# a release other than this one" "$(cat "$prof/scripts/status-line.sh")"
out=$(inst --force); check "newer: --force replaces" "0" "$?"
check "newer: now this release" "" "$(cmp "$scripts/status-line.sh" "$prof/scripts/status-line.sh")"
setstamp 0.0.9
out=$(inst --dry-run)
has "older stamp: still behind" "~ scripts/status-line.sh  behind" "$out"
# Versions compare by number, not as strings: prefixing the minor field with
# a 1 makes it numerically later (2 -> 12) but, from 0.2 on, a string earlier.
later=$(printf '%s' "$this" | awk -F. '{ $2 = "1" $2; print }' OFS=.)
setstamp "$later"
out=$(inst --dry-run)
has "newer: minor compared as a number" "! scripts/status-line.sh  installed $later is newer" "$out"
# Back to this release before the modified case.
out=$(inst --force)

# locally modified: edited after install
printf '# local edit\n' >> "$prof/scripts/status-line.sh"
out=$(inst --dry-run)
has "modified: reported" "! scripts/status-line.sh  modified" "$out"
out=$(inst); rc=$?
check "modified: refuses" "1" "$rc"
check "modified: edit kept" "# local edit" "$(tail -1 "$prof/scripts/status-line.sh")"
out=$(inst --force); check "modified: --force replaces" "0" "$?"
has "modified: real --force run reports the replace" "! scripts/status-line.sh  modified since install, or unknown origin; --force replaces it" "$out"
check "modified: no would in a real --force run" "0" "$(printf '%s\n' "$out" | grep -c would)"
check "modified: now current" "" "$(cmp "$scripts/status-line.sh" "$prof/scripts/status-line.sh")"

# From the plugin cache: no git checkout, so the commit comes from the running
# profile's installed_plugins.json, looked up by install path. CLAUDE_CONFIG_DIR
# (the running profile) and --config-dir (the install target) differ, so a
# lookup under --config-dir finds no record.
cache="$work/cache/mp-ported-skills/$this"
mkdir -p "$(dirname "$cache")"
command cp -R "$root/plugins/mp-ported-skills" "$cache"
running="$work/.claude-running"; mkdir -p "$running/plugins"
cinst() { # <installPath in the record>; installs into $prof
    jq -n --arg p "$1" --arg v "$this" \
        '{plugins: {"mp-ported-skills@mp-ported-skills": [{installPath: $p, version: $v, gitCommitSha: "abcdef0123456789abcdef0123456789abcdef01"}]}}' \
        > "$running/plugins/installed_plugins.json"
    GIT_CEILING_DIRECTORIES="$work" CLAUDE_CONFIG_DIR="$running" \
        sh "$cache/skills/install-statusline/scripts/install.sh" --config-dir "$prof" </dev/null
}
check "cache: copy is outside git" "no" \
    "$(GIT_CEILING_DIRECTORIES="$work" git -C "$cache" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"
prof="$work/prof-cache-match"; mkdir -p "$prof"
out=$(cinst "$cache"); check "cache match: install exits 0" "0" "$?"
check "cache match: commit from the record" "commit: abcdef0" "$(sed -n 2p "$prof/scripts/status-line.source")"
prof="$work/prof-cache-miss"; mkdir -p "$prof"
out=$(cinst "$work/cache/elsewhere"); check "cache miss: install exits 0" "0" "$?"
check "cache miss: commit unknown" "commit: unknown" "$(sed -n 2p "$prof/scripts/status-line.source")"

# Environment errors
out=$(sh "$skill/install.sh" --config-dir "$work/nope" </dev/null 2>&1); check "missing profile: exit 2" "2" "$?"
prof="$work/prof-bad"; mkdir -p "$prof"; printf '{not json' > "$prof/settings.json"
out=$(inst 2>&1); check "invalid settings: exit 2" "2" "$?"
has "invalid settings: report printed before the error" "+ scripts/status-line.sh  would create" "$out"
out=$(sh "$skill/install.sh" --bogus </dev/null 2>&1); check "bad flag: exit 2" "2" "$?"

echo "install-statusline: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
