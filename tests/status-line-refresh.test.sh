#!/bin/sh
# status-line-refresh.test.sh -- tests for the SessionStart hook that keeps a
# profile's copy of the status line current.
#
# Runs the command string from hooks.json, as Claude Code does, with
# CLAUDE_PLUGIN_ROOT at a plugin copy of a chosen version and
# CLAUDE_CONFIG_DIR at a scratch profile: no stamp, behind, modified, newer,
# in sync, behind and modified at once, and no jq. Touches nothing outside
# its own mktemp directory.
#
# Usage: sh tests/status-line-refresh.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT
# Plugin copies sit outside any checkout, so their commit reads as unknown.
GIT_CEILING_DIRECTORIES="$work"
export GIT_CEILING_DIRECTORIES

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# The refresh hook is the SessionStart entry whose command runs
# status-line-refresh.sh.
entry='.hooks.SessionStart[] | select(.hooks[0].command | test("status-line-refresh"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

plugin() { # <version>: a plugin copy at that version; prints its root
    p="$work/plugin-$1"
    if [ ! -d "$p" ]; then
        command cp -R "$root/plugins/mp-ported-skills" "$p"
        jq --arg v "$1" '.version = $v' "$root/plugins/mp-ported-skills/.claude-plugin/plugin.json" \
            > "$p/.claude-plugin/plugin.json"
    fi
    echo "$p"
}
v1=$(plugin 1.0.0)
v2=$(plugin 1.1.0)
printf '# changed in 1.1.0\n' >> "$v2/scripts/status-line.sh"

install_copy() { # <plugin-root> <profile>: a stamped copy, as /setup-mp-ported-skills makes
    mkdir -p "$2"
    (. "$1/scripts/status-line-copy.sh" && sl_init "$1" "$2" \
        && sl_write status-line.sh status-line-base.sh) </dev/null
}
# hook <plugin-root> <profile>: run the hook; its stdout in $out, its exit
# status in $rc, its stderr in $work/stderr.
hook() {
    out=$(CLAUDE_PLUGIN_ROOT="$1" CLAUDE_CONFIG_DIR="$2" sh -c "$hook_cmd" </dev/null 2>"$work/stderr"); rc=$?
}
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }
stamp_version() { sed -n 's/^plugin: mp-ported-skills //p' "$1/scripts/status-line.source"; }
snapshot() { (cd "$1/scripts" && cat status-line.sh status-line-base.sh status-line.source 2>/dev/null) | sha; }

# No stamp: the profile has not opted in, so an earlier copy stays as it is.
p="$work/nostamp"; install_copy "$v1" "$p"; command rm -f "$p/scripts/status-line.source"
before=$(snapshot "$p")
hook "$v2" "$p"
check "no stamp: no output" "" "$out"
check "no stamp: exit 0" "0" "$rc"
check "no stamp: untouched" "$before" "$(snapshot "$p")"
check "no stamp: none written" "no" "$([ -f "$p/scripts/status-line.source" ] && echo yes || echo no)"

# Behind: replaced from the plugin, and the stamp names the plugin's release.
p="$work/behind"; install_copy "$v1" "$p"
hook "$v2" "$p"
check "behind: no output" "" "$out"
check "behind: exit 0" "0" "$rc"
check "behind: replaced" "" "$(cmp "$v2/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"
check "behind: stamp rewritten" "1.1.0" "$(stamp_version "$p")"
check "behind: now in sync" "in-sync" \
    "$( (. "$v2/scripts/status-line-copy.sh" && sl_init "$v2" "$p" && sl_state status-line.sh) </dev/null)"
check "behind: nothing on stderr" "" "$(cat "$work/stderr")"

# Modified: untouched, and exactly one line pointing to the setup skill.
p="$work/modified"; install_copy "$v1" "$p"
printf '# local edit\n' >> "$p/scripts/status-line.sh"
before=$(snapshot "$p")
hook "$v2" "$p"
check "modified: exit 0" "0" "$rc"
check "modified: untouched" "$before" "$(snapshot "$p")"
check "modified: one line" "1" "$(printf '%s\n' "$out" | grep -c .)"
check "modified: points to /setup-mp-ported-skills" "1" "$(printf '%s\n' "$out" | grep -c '/setup-mp-ported-skills')"
check "modified: names the file" "1" "$(printf '%s\n' "$out" | grep -c 'status-line\.sh')"
# Both files edited still adds one line, naming both.
printf '# local edit\n' >> "$p/scripts/status-line-base.sh"
hook "$v2" "$p"
check "modified, both: one line" "1" "$(printf '%s\n' "$out" | grep -c .)"
check "modified, both: names the base" "1" "$(printf '%s\n' "$out" | grep -c 'status-line-base\.sh')"

# Behind and modified at once: the behind file is updated, the edited one kept
# and reported, and the edit still reads as modified afterwards.
p="$work/mixed"; install_copy "$v1" "$p"
printf '# local edit\n' >> "$p/scripts/status-line-base.sh"
base_before=$(sha < "$p/scripts/status-line-base.sh")
hook "$v2" "$p"
check "mixed: behind file replaced" "" "$(cmp "$v2/scripts/status-line.sh" "$p/scripts/status-line.sh" 2>&1)"
check "mixed: edited file kept" "$base_before" "$(sha < "$p/scripts/status-line-base.sh")"
check "mixed: one line, naming the base" "1" "$(printf '%s\n' "$out" | grep -c 'status-line-base\.sh')"
check "mixed: edit still reads as modified" "modified" \
    "$( (. "$v2/scripts/status-line-copy.sh" && sl_init "$v2" "$p" && sl_state status-line-base.sh) </dev/null)"

# Newer: a session still on an earlier release never downgrades it.
p="$work/newer"; install_copy "$v2" "$p"
before=$(snapshot "$p")
hook "$v1" "$p"
check "newer: no output" "" "$out"
check "newer: exit 0" "0" "$rc"
check "newer: untouched" "$before" "$(snapshot "$p")"

# In sync: nothing written, the stamp included.
p="$work/insync"; install_copy "$v2" "$p"
before=$(snapshot "$p")
hook "$v2" "$p"
check "in sync: no output" "" "$out"
check "in sync: untouched" "$before" "$(snapshot "$p")"

# Without jq the version reads as unknown, so do nothing rather than risk a
# downgrade, and still start the session.
bin="$work/bin"; mkdir -p "$bin"; ln -s "$(command -v sh)" "$bin/sh"
p="$work/nojq"; install_copy "$v1" "$p"
before=$(snapshot "$p")
out=$(CLAUDE_PLUGIN_ROOT="$v2" CLAUDE_CONFIG_DIR="$p" PATH="$bin" sh -c "$hook_cmd" </dev/null 2>"$work/stderr"); rc=$?
check "no jq: no output" "" "$out"
check "no jq: exit 0" "0" "$rc"
check "no jq: nothing on stderr" "" "$(cat "$work/stderr")"
check "no jq: untouched" "$before" "$(snapshot "$p")"

# The entry Claude Code runs, and the resuming hook left as the first entry.
check "matcher: startup, clear and compact" "startup|clear|compact" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"
check "resuming hook still first" 'sh "${CLAUDE_PLUGIN_ROOT}/skills/resuming/scripts/state.sh" --hook </dev/null' \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")"

echo "status-line-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
