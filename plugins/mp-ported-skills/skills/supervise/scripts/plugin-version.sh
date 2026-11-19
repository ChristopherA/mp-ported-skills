#!/bin/sh
# plugin-version.sh -- sourced by resuming's state.sh: whether the installed
# plugin running these scripts is older than the version the checkout's
# default branch carries (#238).
#
# A session runs the version it loaded at start, from the plugin cache. When
# the install record falls behind, every session loads the old skill text and
# scripts and nothing says so: on 2026-11-01 a supervisor loaded 0.8.18,
# with no --loop, while the repo was at 0.8.111. In the plugin's own repo
# the default branch names the version an update would install, so the
# scripts can tell.

# plugin_behind <plugin root> <dir> <ref>: one `plugin: ...` line when
# <plugin root> is a version folder of the plugin cache
# (<marketplace>/<plugin>/<version>) and <ref> in the repo at <dir> holds
# plugins/<plugin>/.claude-plugin/plugin.json at a higher version, compared
# by number. The line names the update command and /reload-plugins. Prints
# nothing otherwise: a plugin loaded from a folder (--plugin-dir), a repo
# that does not carry the plugin, or a version the same or lower. <ref> is
# the remote-tracking default branch when there is one, since the update
# fetches from the remote and a bump not yet pushed cannot be installed.
# Calls programs by their plain names: state.sh runs it in its background
# gather, inside $( ).
plugin_behind() {
    plugin_behind_loaded=$(basename -- "$1")
    plugin_behind_is_version "$plugin_behind_loaded" || return 0
    plugin_behind_name=$(basename -- "$(dirname -- "$1")")
    plugin_behind_market=$(basename -- "$(dirname -- "$(dirname -- "$1")")")
    plugin_behind_repo=$(git -C "$2" show "${3}:plugins/${plugin_behind_name}/.claude-plugin/plugin.json" 2>/dev/null |
        jq -r '.version // empty' 2>/dev/null)
    plugin_behind_is_version "$plugin_behind_repo" || return 0
    [ "$plugin_behind_repo" != "$plugin_behind_loaded" ] || return 0
    plugin_behind_newest=$(printf '%s\n%s\n' "$plugin_behind_loaded" "$plugin_behind_repo" |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ "$plugin_behind_newest" = "$plugin_behind_repo" ] || return 0
    printf 'plugin: %s %s is loaded, older than %s on %s; run `command claude plugin marketplace update %s && command claude plugin update %s@%s` through Bash, then type /reload-plugins\n' \
        "$plugin_behind_name" "$plugin_behind_loaded" "$plugin_behind_repo" "$3" \
        "$plugin_behind_market" "$plugin_behind_name" "$plugin_behind_market"
}

plugin_behind_is_version() { printf '%s\n' "$1" | grep -qE '^[0-9]+[.][0-9]+[.][0-9]+$'; }
