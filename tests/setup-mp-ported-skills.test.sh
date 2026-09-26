#!/bin/sh
# setup-mp-ported-skills.test.sh -- tests for /setup-mp-ported-skills' script, which reports
# and turns on or off each profile feature: Remote Control, the status line
# and session titles.
#
# Runs setup.sh against scratch profile directories: the report for a fresh
# profile, each feature on and off, and an existing settings.json kept and
# backed up, its earliest state kept across several changes. The status line
# cases: the statusLine written renders and follows CLAUDE_CONFIG_DIR, another
# command's statusLine (replaced alone when the copy is in sync), an edited
# copy (on and off), a copy with no stamp, a behind copy, a newer copy left
# alone, and an off that leaves another command's statusLine in place. Also no jq, invalid JSON and
# bad usage, flags on a feature they do not apply to included. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/setup-mp-ported-skills.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plugin="$root/plugins/mp-ported-skills"
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT
# Plugin copies below sit outside any checkout, so their commit is unknown.
GIT_CEILING_DIRECTORIES="$work"
export GIT_CEILING_DIRECTORIES
export CLAUDE_CONFIG_DIR="$work/.claude-running"
mkdir -p "$CLAUDE_CONFIG_DIR"
# The status line reads these; a session that sets them must not change what renders.
unset MP_SMART_ZONE_K MP_SESSION_TITLE CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
has() { # <name> <needle> <haystack>
    case $3 in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "$3" ;; esac
}
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }

plugin_at() { # <version>: a plugin copy at that version; prints its root
    p="$work/plugin-$1"
    if [ ! -d "$p" ]; then
        command cp -R "$plugin" "$p"
        jq --arg v "$1" '.version = $v' "$plugin/.claude-plugin/plugin.json" > "$p/.claude-plugin/plugin.json"
    fi
    echo "$p"
}
v1=$(plugin_at 1.0.0)
v2=$(plugin_at 1.1.0)
printf '# changed in 1.1.0\n' >> "$v2/scripts/status-line.sh"

# setup <plugin-root> <profile> <args...>: run setup.sh; stdout and stderr in
# $out, exit status in $rc.
setup() {
    _p=$1 _c=$2; shift 2
    out=$(sh "$_p/skills/setup-mp-ported-skills/scripts/setup.sh" --config-dir "$_c" "$@" </dev/null 2>&1); rc=$?
}
feature() { # <name>: that feature's line from $out, its leading spaces cut
    printf '%s\n' "$out" | sed -n "s/^  $1  *//p"
}
sl_cmd='sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh"'
settings() { jq -c "$2" "$1/settings.json"; }
first_backup() { ls "$1"/settings.json.pre-setup-mp-ported-skills-* | head -1; }
backups() { ls "$1" | grep -c '^settings\.json\.pre-setup-mp-ported-skills-'; }

# --- report: a fresh profile ------------------------------------------------
p="$work/fresh"; mkdir -p "$p"
setup "$v1" "$p" report
check "fresh: exit 0" "0" "$rc"
check "fresh: remote-control off" "off" "$(feature remote-control)"
check "fresh: status-line off" "off" "$(feature status-line)"
check "fresh: titles off" "off" "$(feature titles)"
check "fresh: report writes nothing" "" "$(ls -A "$p")"

# --- remote control -----------------------------------------------------------
setup "$v1" "$p" remote-control on
check "remote-control on: exit 0" "0" "$rc"
check "remote-control on: set" "true" "$(settings "$p" .remoteControlAtStartup)"
setup "$v1" "$p" report
check "remote-control on: reported" "on" "$(feature remote-control)"
setup "$v1" "$p" remote-control on
check "remote-control on again: exit 0" "0" "$rc"
has "remote-control on again: already" "already on" "$out"
setup "$v1" "$p" remote-control off
check "remote-control off: exit 0" "0" "$rc"
check "remote-control off: key removed" "false" "$(settings "$p" 'has("remoteControlAtStartup")')"

# --- titles -------------------------------------------------------------------
setup "$v1" "$p" titles on
check "titles on: exit 0" "0" "$rc"
check "titles on: env set" '"1"' "$(settings "$p" .env.MP_SESSION_TITLE)"
setup "$v1" "$p" report
check "titles on: reported" "on" "$(feature titles)"
setup "$v1" "$p" titles off
check "titles off: exit 0" "0" "$rc"
check "titles off: env emptied away" "false" "$(settings "$p" 'has("env")')"

# An existing settings.json keeps its other keys, and is backed up first.
p="$work/existing"; mkdir -p "$p"
printf '{"model":"opus","env":{"FOO":"bar"}}\n' > "$p/settings.json"
before=$(sha < "$p/settings.json")
setup "$v1" "$p" titles on
check "existing: other keys kept" '{"model":"opus","env":{"FOO":"bar","MP_SESSION_TITLE":"1"}}' "$(settings "$p" .)"
check "existing: backed up" "$before" "$(sha < "$(first_backup "$p")")"
has "existing: says where" "backed up to $p/settings.json.pre-setup-mp-ported-skills-" "$out"
setup "$v1" "$p" titles off
check "existing: off keeps other env" '{"model":"opus","env":{"FOO":"bar"}}' "$(settings "$p" .)"
# Several changes in a row keep the state before the first.
setup "$v1" "$p" remote-control on
check "backups: the earliest survives" "$before" "$(sha < "$(first_backup "$p")")"
jq '.env.MP_SESSION_TITLE = "0"' "$p/settings.json" > "$p/s" && command mv -f "$p/s" "$p/settings.json"
setup "$v1" "$p" report
check "existing: titles set to 0 reads off" "off" "$(feature titles)"

# --- status line ----------------------------------------------------------------
p="$work/sl"; mkdir -p "$p"
setup "$v1" "$p" status-line on
check "sl on: exit 0" "0" "$rc"
check "sl on: statusLine set" "$sl_cmd" "$(jq -r .statusLine.command "$p/settings.json")"
check "sl on: copy made" "" "$(cmp "$v1/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"
check "sl on: base copied" "" "$(cmp "$v1/scripts/status-line-base.sh" "$p/scripts/status-line-base.sh" 2>&1)"
check "sl on: stamped" "plugin: mp-ported-skills 1.0.0" "$(sed -n 1p "$p/scripts/status-line.source")"
setup "$v1" "$p" report
check "sl on: reported" "on" "$(feature status-line)"
setup "$v1" "$p" status-line on
check "sl on again: exit 0" "0" "$rc"
has "sl on again: already" "already on" "$out"

# The statusLine written runs the profile's copy, and follows CLAUDE_CONFIG_DIR
# at run time: settings copied into another profile run that profile's copy.
sl_payload='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/nowhere"},"session_id":"s1","context_window":{"used_percentage":7,"remaining_percentage":93,"context_window_size":1000000}}'
run_sl() { # <profile>: render through the statusLine command in its settings
    printf '%s' "$sl_payload" | WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx" CLAUDE_CONFIG_DIR="$1" \
        sh -c "$(jq -r .statusLine.command "$1/settings.json")" | sed 's/\x1b\[[0-9;]*m//g'
}
mkdir -p "$work/ctx"
check "sl on: the command renders" "[Opus] 46% of zone" "$(run_sl "$p" | sed -n 2p)"
p2="$work/sl-copied"; mkdir -p "$p2/scripts"
command cp -f "$p/settings.json" "$p2/settings.json"
printf 'echo copied-profile-script\n' > "$p2/scripts/status-line.sh"
check "sl on: the command follows CLAUDE_CONFIG_DIR" "copied-profile-script" "$(run_sl "$p2")"

# Only statusLine differs: --replace-statusline sets it and leaves the in-sync
# copy and its stamp alone.
p3="$work/sl-only"; mkdir -p "$p3"
setup "$v1" "$p3" status-line on
jq '.statusLine.command = "my-line.sh"' "$p3/settings.json" > "$p3/s" && command mv -f "$p3/s" "$p3/settings.json"
stamp_before=$(cat "$p3/scripts/status-line.source")
copy_before=$(ls -i "$p3/scripts/status-line.sh")
setup "$v1" "$p3" status-line on --replace-statusline
check "sl only statusLine: exit 0" "0" "$rc"
check "sl only statusLine: set" "$sl_cmd" "$(jq -r .statusLine.command "$p3/settings.json")"
check "sl only statusLine: stamp untouched" "$stamp_before" "$(cat "$p3/scripts/status-line.source")"
check "sl only statusLine: copy not rewritten" "$copy_before" "$(ls -i "$p3/scripts/status-line.sh")"
check "sl only statusLine: reports no copy" "0" "$(printf '%s\n' "$out" | grep -c 'copied from')"

# A behind copy is reported as on, and turning on again updates it.
setup "$v2" "$p" report
check "sl behind: reported on" "on" "$(feature status-line)"
has "sl behind: says the hook updates it" "behind" "$out"
setup "$v2" "$p" status-line on
check "sl behind on: updated" "" "$(cmp "$v2/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"
check "sl behind on: restamped" "plugin: mp-ported-skills 1.1.0" "$(sed -n 1p "$p/scripts/status-line.source")"

# A newer copy is on, and an older plugin never downgrades it.
setup "$v1" "$p" status-line on
check "sl newer: exit 0" "0" "$rc"
check "sl newer: not downgraded" "" "$(cmp "$v2/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"
check "sl newer: stamp kept" "plugin: mp-ported-skills 1.1.0" "$(sed -n 1p "$p/scripts/status-line.source")"

# An edited copy reads as modified; on and off both refuse without --force.
printf '# local edit\n' >> "$p/scripts/status-line.sh"
edited=$(sha < "$p/scripts/status-line.sh")
setup "$v2" "$p" report
check "sl modified: reported" "modified" "$(feature status-line)"
has "sl modified: names the file" "scripts/status-line.sh" "$out"
setup "$v2" "$p" status-line on
check "sl modified on: refused" "1" "$rc"
has "sl modified on: needs --force" "--force" "$out"
check "sl modified on: edit kept" "$edited" "$(sha < "$p/scripts/status-line.sh")"
setup "$v2" "$p" status-line off
check "sl modified off: refused" "1" "$rc"
check "sl modified off: edit kept" "$edited" "$(sha < "$p/scripts/status-line.sh")"
check "sl modified off: statusLine kept" "$sl_cmd" "$(jq -r .statusLine.command "$p/settings.json")"
setup "$v2" "$p" status-line on --force
check "sl modified on --force: exit 0" "0" "$rc"
check "sl modified on --force: replaced" "" "$(cmp "$v2/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"

# Off removes statusLine, the copies and the stamp.
setup "$v2" "$p" status-line off
check "sl off: exit 0" "0" "$rc"
check "sl off: statusLine removed" "false" "$(settings "$p" 'has("statusLine")')"
check "sl off: copies and stamp removed" "" "$(ls -A "$p/scripts" 2>/dev/null)"
setup "$v2" "$p" report
check "sl off: reported" "off" "$(feature status-line)"
setup "$v2" "$p" status-line off
check "sl off again: exit 0" "0" "$rc"
has "sl off again: already" "already off" "$out"

# Another command's statusLine is replaced only with --replace-statusline.
p="$work/other"; mkdir -p "$p"
printf '{"statusLine":{"type":"command","command":"my-line.sh"}}\n' > "$p/settings.json"
setup "$v1" "$p" report
has "sl other: reported" "my-line.sh" "$out"
setup "$v1" "$p" status-line on
check "sl other on: refused" "1" "$rc"
has "sl other on: needs --replace-statusline" "--replace-statusline" "$out"
check "sl other on: nothing copied" "no" "$([ -e "$p/scripts" ] && echo yes || echo no)"
check "sl other on: statusLine kept" "my-line.sh" "$(jq -r .statusLine.command "$p/settings.json")"
setup "$v1" "$p" status-line on --replace-statusline
check "sl other --replace: exit 0" "0" "$rc"
check "sl other --replace: replaced" "$sl_cmd" "$(jq -r .statusLine.command "$p/settings.json")"
check "sl other --replace: backup holds the old one" "my-line.sh" \
    "$(jq -r .statusLine.command "$(first_backup "$p")")"

# A copy with no stamp is of unknown origin: the report shows it, and on
# replaces it only with --force.
p="$work/foreign"; mkdir -p "$p/scripts"; printf '# mine\n' > "$p/scripts/status-line.sh"
setup "$v1" "$p" report
check "sl foreign: reported off" "off" "$(feature status-line)"
has "sl foreign: named" "scripts/status-line.sh  present with no install stamp" "$out"
setup "$v1" "$p" status-line on
check "sl foreign on: refused" "1" "$rc"
check "sl foreign on: kept" "# mine" "$(cat "$p/scripts/status-line.sh")"
check "sl foreign on: no settings written" "no" "$([ -f "$p/settings.json" ] && echo yes || echo no)"
setup "$v1" "$p" status-line on --force
check "sl foreign --force: exit 0" "0" "$rc"
check "sl foreign --force: replaced" "" "$(cmp "$v1/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"

# Off with another command's statusLine removes our copy and leaves theirs.
p="$work/otheroff"; mkdir -p "$p"
setup "$v1" "$p" status-line on
jq '.statusLine.command = "my-line.sh"' "$p/settings.json" > "$p/s" && command mv -f "$p/s" "$p/settings.json"
setup "$v1" "$p" status-line off
check "sl off, other command: exit 0" "0" "$rc"
check "sl off, other command: kept" "my-line.sh" "$(jq -r .statusLine.command "$p/settings.json")"
check "sl off, other command: copy removed" "no" "$([ -f "$p/scripts/status-line.source" ] && echo yes || echo no)"

# --- errors -------------------------------------------------------------------
p="$work/badjson"; mkdir -p "$p"; printf '{not json\n' > "$p/settings.json"
setup "$v1" "$p" titles on
check "invalid JSON: exit 2" "2" "$rc"
check "invalid JSON: untouched" "{not json" "$(cat "$p/settings.json")"
setup "$v1" "$p" frobnicate on
check "unknown feature: exit 2" "2" "$rc"
setup "$v1" "$p" titles maybe
check "bad state: exit 2" "2" "$rc"
setup "$v1" "$work/fresh" titles on --force
check "--force on titles: exit 2" "2" "$rc"
setup "$v1" "$work/fresh" report --replace-statusline
check "--replace-statusline on report: exit 2" "2" "$rc"
setup "$v1" "$work/nonexistent" report
check "no profile dir: exit 2" "2" "$rc"
bin="$work/bin"; mkdir -p "$bin"; for c in sh dirname; do ln -s "$(command -v $c)" "$bin/$c"; done
out=$(PATH="$bin" sh "$v1/skills/setup-mp-ported-skills/scripts/setup.sh" --config-dir "$work/fresh" report </dev/null 2>&1); rc=$?
check "no jq: exit 2" "2" "$rc"
has "no jq: says so" "jq is required" "$out"

echo "setup-mp-ported-skills: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
