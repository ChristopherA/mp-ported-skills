#!/bin/sh
# install.sh -- install the smart-zone status line into a Claude Code profile.
#
# Usage: install.sh [--dry-run] [--force] [--replace-statusline] [--config-dir DIR]
#
# Copies status-line.sh and status-line-base.sh from this folder into
# <profile>/scripts/ and points that profile's statusLine at the copy. The
# profile is --config-dir, else $CLAUDE_CONFIG_DIR, else ~/.claude. It works
# at profile level because project settings load only from the directory a
# session starts in, so a status line set in one repo never reaches the repos
# nested inside it. Settings name the copy through $CLAUDE_CONFIG_DIR, never
# this folder: a plugin cache path carries the version and moves on every
# update.
#
# The report, one line per file and one for statusLine:
#   + absent, would create        = in sync
#   ~ behind: an earlier install, unedited since; a real run updates it
#   ! modified: edited since it was installed, or of unknown origin;
#     replaced only with --force
#   ! statusLine runs another command; replaced only with --replace-statusline
#   ~ stamp missing, or names another version or commit, while the files
#     are in sync; a real run rewrites it
#
# --dry-run reports and writes nothing. A real run with a ! line whose flag is
# absent refuses and writes nothing. Installed copies are stamped in
# scripts/status-line.source with the plugin version, its commit and each
# file's sha256 as installed; the stamp is how a later run tells "behind" from
# "modified", since the plugin cache has no git history to ask. A settings.json
# about to change is first copied to settings.json.pre-install-statusline.
#
# Exit: 0 in sync or installed; 1 a dry run found changes, or a real run
# refused; 2 usage or environment error.

set -eu

usage() {
    echo "usage: install.sh [--dry-run] [--force] [--replace-statusline] [--config-dir DIR]" >&2
    exit 2
}

dry=0 force=0 replace=0 cfg=""
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) dry=1 ;;
        --force) force=1 ;;
        --replace-statusline) replace=1 ;;
        --config-dir) [ $# -ge 2 ] || usage; cfg=$2; shift ;;
        *) usage ;;
    esac
    shift
done
cfg=${cfg:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
cfg=${cfg%/}

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }
[ -d "$cfg" ] || { echo "ERROR: no profile directory at $cfg" >&2; exit 2; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
plugin_root=$(CDPATH= cd -- "$here/../../.." && pwd)
dest="$cfg/scripts"
stamp="$dest/status-line.source"
settings="$cfg/settings.json"
files="status-line.sh status-line-base.sh"
# Expanded when the status line runs, not now: whichever profile loads these
# settings runs its own copy, so a settings.json copied to another profile or
# machine still finds the right script.
sl_cmd='sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh"'

sha() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1
}

# Provenance: the plugin version, and the commit it was installed from -- the
# checkout's HEAD when run from one, else the commit the plugin manager
# recorded for this install path.
version=$(jq -r '.version // "unknown"' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null) || version=unknown
commit=""
if git -C "$plugin_root" rev-parse --git-dir >/dev/null 2>&1; then
    commit=$(git -C "$plugin_root" rev-parse --short HEAD 2>/dev/null) || commit=""
else
    ip="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
    [ -f "$ip" ] && commit=$(jq -r --arg p "$plugin_root" \
        '[.plugins[][]? | select(.installPath == $p) | .gitCommitSha] | first // empty | .[0:7]' "$ip" 2>/dev/null) || commit=""
fi
commit=${commit:-unknown}

recorded() {
    [ -f "$stamp" ] && awk -v f="$1" '$1 == f { print $2 }' "$stamp" || true
}

echo "install-statusline: mp-ported-skills $version ($commit) -> $cfg"

changes=0 blocked=0
for f in $files; do
    src="$here/$f" dst="$dest/$f"
    if [ ! -f "$dst" ]; then
        echo "  + scripts/$f  would create"; changes=1
    elif [ "$(sha "$dst")" = "$(sha "$src")" ]; then
        echo "  = scripts/$f  in sync"
    elif [ "$(sha "$dst")" = "$(recorded "$f")" ]; then
        echo "  ~ scripts/$f  behind: an earlier install, unedited; would update"; changes=1
    else
        changes=1
        if [ "$force" -eq 1 ]; then
            echo "  ! scripts/$f  modified since install, or unknown origin; --force replaces it"
        else
            echo "  ! scripts/$f  modified since install, or unknown origin; needs --force"; blocked=1
        fi
    fi
done

# A plugin update that leaves these scripts unchanged still moves the stamp,
# so it keeps naming the release the copies came from.
if [ "$changes" -eq 0 ]; then
    if [ -f "$stamp" ]; then
        s_version=$(sed -n 's/^plugin: mp-ported-skills //p' "$stamp")
        s_commit=$(sed -n 's/^commit: //p' "$stamp")
        if [ "$s_version" != "$version" ] || [ "$s_commit" != "$commit" ]; then
            echo "  ~ scripts/status-line.source  names $s_version ($s_commit); would restamp"; changes=1
        fi
    else
        echo "  ~ scripts/status-line.source  missing; would stamp"; changes=1
    fi
fi

current=""
if [ -f "$settings" ]; then
    jq -e . "$settings" >/dev/null 2>&1 || { echo "ERROR: $settings is not valid JSON" >&2; exit 2; }
    current=$(jq -r '.statusLine.command // empty' "$settings")
fi
sl_change=0
if [ -z "$current" ]; then
    echo "  + statusLine  none set; would set: $sl_cmd"; sl_change=1
elif [ "$current" = "$sl_cmd" ]; then
    echo "  = statusLine  runs this copy"
else
    sl_change=1
    echo "  ! statusLine  currently: $current"
    if [ "$replace" -eq 1 ]; then
        echo "                --replace-statusline replaces it with: $sl_cmd"
    else
        echo "                needs --replace-statusline to replace it with: $sl_cmd"; blocked=1
    fi
fi
[ "$sl_change" -eq 1 ] && changes=1

if [ "$dry" -eq 1 ]; then
    if [ "$changes" -eq 0 ]; then echo "In sync. Nothing written."; exit 0; fi
    echo "Dry run: changes above. Nothing written."; exit 1
fi
if [ "$blocked" -eq 1 ]; then
    echo "Refused: a ! line above lacks its flag. Nothing written."; exit 1
fi
if [ "$changes" -eq 0 ]; then
    echo "In sync. Nothing written."; exit 0
fi

mkdir -p "$dest"
for f in $files; do
    tmp="$dest/.$f.tmp"
    command cp -f "$here/$f" "$tmp"
    chmod 755 "$tmp"
    command mv -f "$tmp" "$dest/$f"
done
{
    echo "plugin: mp-ported-skills $version"
    echo "commit: $commit"
    echo "installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in $files; do echo "$f $(sha "$dest/$f")"; done
} > "$stamp.tmp"
command mv -f "$stamp.tmp" "$stamp"
echo "  wrote $dest/{status-line.sh,status-line-base.sh,status-line.source}"

if [ "$sl_change" -eq 1 ]; then
    tmp="$settings.tmp"
    if [ -f "$settings" ]; then
        command cp -f "$settings" "$settings.pre-install-statusline"
        jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' "$settings" > "$tmp"
    else
        jq -n --arg c "$sl_cmd" '{statusLine: {"type": "command", "command": $c}}' > "$tmp"
    fi
    command mv -f "$tmp" "$settings"
    echo "  set statusLine in $settings"
fi
echo "Installed. Sessions started from now on show it."
