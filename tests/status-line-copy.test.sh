#!/bin/sh
# status-line-copy.test.sh -- tests for the status line copy library, which
# compares a profile's copy of the status line with the plugin's and writes
# the copy and its stamp.
#
# Sources the library against plugin copies at chosen versions and scratch
# profile directories, and checks the commit the stamp records: a checkout's
# HEAD, or for a plugin-cache copy the running profile's installed_plugins.json
# entry for that path, else unknown. Touches no real profile and nothing under /tmp outside
# its own mktemp directory.
#
# Usage: sh tests/status-line-copy.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT
# The plugin copies below sit outside any checkout, so their commit is looked
# up in this running profile, which holds no record until the provenance
# cases at the end, and comes out unknown.
export CLAUDE_CONFIG_DIR="$work/.claude-running"
mkdir -p "$CLAUDE_CONFIG_DIR"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

plugin() { # <version>: a plugin copy at that version; prints its root
    p="$work/plugin-$1"
    if [ ! -d "$p" ]; then
        command cp -R "$root/plugins/mp-ported-skills" "$p"
        jq --arg v "$1" '.version = $v' "$root/plugins/mp-ported-skills/.claude-plugin/plugin.json" \
            > "$p/.claude-plugin/plugin.json"
    fi
    echo "$p"
}
same() { cmp -s "$1" "$2" && echo same || echo differs; }
# lib <plugin-root> <profile> <command...>: run a command with the library
# loaded for that plugin and profile.
lib() {
    (GIT_CEILING_DIRECTORIES="$work"
     export GIT_CEILING_DIRECTORIES
     . "$1/scripts/status-line-copy.sh" && sl_init "$1" "$2" && shift 2 && "$@") </dev/null
}

v1=$(plugin 1.0.0)
prof="$work/prof"; mkdir -p "$prof"

check "absent: no copy yet" "absent" "$(lib "$v1" "$prof" sl_state status-line.sh)"

lib "$v1" "$prof" sl_write status-line.sh status-line-base.sh
check "write: copy made" "" "$(cmp "$v1/scripts/status-line.sh" "$prof/scripts/status-line.sh")"
check "write: in sync" "in-sync" "$(lib "$v1" "$prof" sl_state status-line.sh)"
check "write: base in sync" "in-sync" "$(lib "$v1" "$prof" sl_state status-line-base.sh)"
check "write: stamp names the release" "plugin: mp-ported-skills 1.0.0" "$(sed -n 1p "$prof/scripts/status-line.source")"
check "write: stamp commit unknown outside a checkout" "commit: unknown" "$(sed -n 2p "$prof/scripts/status-line.source")"
check "write: stamp records each file" "status-line.sh status-line-base.sh" \
    "$(awk 'NR > 3 { printf "%s%s", (NR > 4 ? " " : ""), $1 }' "$prof/scripts/status-line.source")"

# A later release whose status-line.sh changed; its base did not.
v2=$(plugin 1.1.0)
printf '# changed in 1.1.0\n' >> "$v2/scripts/status-line.sh"
check "behind: earlier release, unedited" "behind" "$(lib "$v2" "$prof" sl_state status-line.sh)"
check "behind: unchanged file stays in sync" "in-sync" "$(lib "$v2" "$prof" sl_state status-line-base.sh)"

# The profile moves to 1.1.0; a session still running 1.0.0 must not
# downgrade it.
lib "$v2" "$prof" sl_write status-line.sh
check "newer: later release, unedited" "newer" "$(lib "$v1" "$prof" sl_state status-line.sh)"
check "newer: the stamp names the later release" "1.1.0" "$(lib "$v1" "$prof" eval 'echo "$SL_S_VERSION"')"
# 1.10.0 follows 1.9.0, though it sorts before it as text.
v10=$(plugin 1.10.0)
printf '# changed in 1.10.0\n' >> "$v10/scripts/status-line.sh"
prof10="$work/prof10"; mkdir -p "$prof10"
lib "$v10" "$prof10" sl_write status-line.sh status-line-base.sh
check "newer: minor compared as a number" "newer" "$(lib "$(plugin 1.9.0)" "$prof10" sl_state status-line.sh)"

printf '# local edit\n' >> "$prof/scripts/status-line.sh"
check "modified: edited since install" "modified" "$(lib "$v2" "$prof" sl_state status-line.sh)"
command rm -f "$prof10/scripts/status-line.source"
check "modified: no stamp, unknown origin" "modified" "$(lib "$v1" "$prof10" sl_state status-line.sh)"

# Updating one file must not stamp another's local edit as installed, or a
# later release would read it as behind and overwrite it.
prof3="$work/prof3"; mkdir -p "$prof3"
lib "$v1" "$prof3" sl_write status-line.sh status-line-base.sh
printf '# local edit\n' >> "$prof3/scripts/status-line-base.sh"
lib "$v2" "$prof3" sl_write status-line.sh
check "write: updated file in sync" "in-sync" "$(lib "$v2" "$prof3" sl_state status-line.sh)"
check "write: an edit elsewhere stays modified" "modified" "$(lib "$v2" "$prof3" sl_state status-line-base.sh)"

# The library refuses a downgrade itself, so a caller that forgets to check
# cannot make one: the copy and its stamp stay as the later release left them.
prof4="$work/prof4"; mkdir -p "$prof4"
lib "$v2" "$prof4" sl_write status-line.sh status-line-base.sh
stamp4=$(command cat "$prof4/scripts/status-line.source")
lib "$v1" "$prof4" sl_write status-line.sh
check "downgrade: sl_write returns non-zero" "1" "$?"
check "downgrade: copy untouched" "same" "$(same "$v2/scripts/status-line.sh" "$prof4/scripts/status-line.sh")"
check "downgrade: stamp untouched" "$stamp4" "$(command cat "$prof4/scripts/status-line.source")"
lib "$v1" "$prof4" sl_write
check "downgrade: a bare restamp is refused too" "1" "$?"

# A version that is not plain dotted numbers cannot be ordered against a
# different one, so neither side is taken to be older: the copy reads as
# unordered, whichever side carries it, and is replaced only with --force.
vrc=$(plugin 1.2.0-rc1)
printf '# changed in 1.2.0-rc1\n' >> "$vrc/scripts/status-line.sh"
prof5="$work/prof5"; mkdir -p "$prof5"
lib "$vrc" "$prof5" sl_write status-line.sh status-line-base.sh
check "pre-release stamp, earlier-looking plugin: unordered" "unordered" "$(lib "$v2" "$prof5" sl_state status-line.sh)"
lib "$v2" "$prof5" sl_write status-line.sh
check "unordered: sl_write refused" "1" "$?"
check "unordered: copy untouched" "same" "$(same "$vrc/scripts/status-line.sh" "$prof5/scripts/status-line.sh")"
# The case a pre-release stamp exists for: a later plain release reads it.
v3=$(plugin 2.0.0)
printf '# changed in 2.0.0\n' >> "$v3/scripts/status-line.sh"
check "pre-release stamp, later plain plugin: unordered" "unordered" "$(lib "$v3" "$prof5" sl_state status-line.sh)"
vunk=$(plugin unknown)
check "non-numeric plugin: unordered" "unordered" "$(lib "$vunk" "$prof4" sl_state status-line.sh)"
lib "$vunk" "$prof4" sl_write status-line.sh
check "non-numeric plugin: sl_write refused" "1" "$?"
# The same pre-release on both sides is one release: an unedited copy of an
# earlier build of it reads as behind, as with plain versions.
vrc2="$work/plugin-rc-rebuilt"; command cp -R "$vrc" "$vrc2"
printf '# rebuilt\n' >> "$vrc2/scripts/status-line.sh"
check "same pre-release on both sides: behind" "behind" "$(lib "$vrc2" "$prof5" sl_state status-line.sh)"
# --force replaces an unordered copy, and never a later one.
lib "$v3" "$prof5" sl_write --force status-line.sh
check "unordered --force: written" "0" "$?"
check "unordered --force: in sync" "in-sync" "$(lib "$v3" "$prof5" sl_state status-line.sh)"
check "unordered --force: stamp names this plugin" "2.0.0" "$(lib "$v3" "$prof5" eval 'echo "$SL_S_VERSION"')"
lib "$v1" "$prof4" sl_write --force status-line.sh
check "later --force: still refused" "1" "$?"
# Two spellings of one release are not known to be in order either.
check "1.0 against 1.0.0: unordered" "unordered" \
    "$(lib "$(plugin 1.0)" "$prof4" eval 'SL_S_VERSION=1.0.0; sl_order')"

# Provenance. Run from a checkout, the commit is its HEAD. From the plugin
# cache, outside git, it is the one the running profile's installed_plugins.json
# records for that install path; the target profile's record is not read.
check "commit: a checkout's HEAD" "$(git -C "$root" rev-parse --short HEAD)" \
    "$(lib "$root/plugins/mp-ported-skills" "$prof" eval 'echo "$SL_COMMIT"')"
installed_record() { # <installPath>: the running profile's record of this plugin
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
    jq -n --arg p "$1" \
        '{plugins: {"mp-ported-skills@mp-ported-skills": [{installPath: $p, version: "1.0.0", gitCommitSha: "abcdef0123456789abcdef0123456789abcdef01"}]}}' \
        > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
}
installed_record "$v1"
check "commit: from the running profile's record" "abcdef0" "$(lib "$v1" "$prof" eval 'echo "$SL_COMMIT"')"
mkdir -p "$prof/plugins"; command cp -f "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" "$prof/plugins/"
installed_record "$work/elsewhere"
check "commit: no record for this path, unknown" "unknown" "$(lib "$v1" "$prof" eval 'echo "$SL_COMMIT"')"
command rm -rf "$CLAUDE_CONFIG_DIR/plugins" "$prof/plugins"

echo "status-line-copy: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
