#!/bin/sh
# install.sh -- install the smart-zone status line into a Claude Code profile.
#
# Usage: install.sh [--dry-run] [--force] [--replace-statusline] [--config-dir DIR]
#
# Copies status-line.sh and status-line-base.sh from the plugin's scripts/ into
# <profile>/scripts/ and points that profile's statusLine at the copy. The
# profile is --config-dir, else $CLAUDE_CONFIG_DIR, else ~/.claude. It works
# at profile level because project settings load only from the directory a
# session starts in, so a status line set in one repo never reaches the repos
# nested inside it. Settings name the copy through $CLAUDE_CONFIG_DIR, never
# the plugin: a plugin cache path carries the version and moves on every
# update.
#
# The report, one line per file and one for statusLine:
#   + absent, would create        = in sync
#   ~ behind: an earlier install, unedited since; a real run updates it
#   ! newer: unedited, but the stamp names a later release than this one;
#     replaced (a downgrade) only with --force
#   ! modified: edited since it was installed, or of unknown origin;
#     replaced only with --force
#   ! statusLine runs another command; replaced only with --replace-statusline
#   ~ stamp missing, or names another version or commit, while the files
#     are in sync; a real run rewrites it
#
# --dry-run reports and writes nothing. A real run with a ! line whose flag
# is absent refuses and writes nothing. A real run that writes copies only
# the files not in sync, then prints the report with each "would" in the
# past tense. The compare, the copy and its stamp,
# scripts/status-line.source, are the plugin's scripts/status-line-copy.sh,
# which says how the stamp tells "behind" from "modified". A settings.json
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
. "$plugin_root/scripts/status-line-copy.sh"
sl_init "$plugin_root" "$cfg"
settings="$cfg/settings.json"
# Expanded when the status line runs, not now: whichever profile loads these
# settings runs its own copy, so a settings.json copied to another profile or
# machine still finds the right script.
sl_cmd='sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh"'

echo "install-statusline: mp-ported-skills $SL_VERSION ($SL_COMMIT) -> $cfg"

# The report is held in two tenses until the run knows whether it writes:
# the plan for a dry or refused run, the past for a real one.
plan="" past=""
say() { # <plan line> [<past line>]
    plan="$plan$1
"
    past="$past${2:-$1}
"
}

changes=0 blocked=0 to_copy=""
for f in $SL_FILES; do
    case $(sl_state "$f") in
    in-sync)
        say "  = scripts/$f  in sync"
        continue ;;
    absent)
        say "  + scripts/$f  would create" "  + scripts/$f  created"; changes=1 ;;
    behind)
        changes=1
        say "  ~ scripts/$f  behind: an earlier install, unedited; would update" \
            "  ~ scripts/$f  behind: an earlier install, unedited; updated" ;;
    newer)
        changes=1
        if [ "$force" -eq 1 ]; then
            say "  ! scripts/$f  installed $SL_S_VERSION is newer than this $SL_VERSION; --force replaces it"
        else
            say "  ! scripts/$f  installed $SL_S_VERSION is newer than this $SL_VERSION; needs --force"; blocked=1
        fi ;;
    *) # modified, or anything sl_state did not name: never replaced unasked
        changes=1
        if [ "$force" -eq 1 ]; then
            say "  ! scripts/$f  modified since install, or unknown origin; --force replaces it"
        else
            say "  ! scripts/$f  modified since install, or unknown origin; needs --force"; blocked=1
        fi ;;
    esac
    to_copy="$to_copy $f"
done

# A plugin update that leaves these scripts unchanged still moves the stamp,
# so it keeps naming the release the copies came from.
restamp=0
if [ "$changes" -eq 0 ]; then
    if [ -f "$SL_STAMP" ]; then
        if [ "$SL_S_VERSION" != "$SL_VERSION" ] || [ "$SL_S_COMMIT" != "$SL_COMMIT" ]; then
            say "  ~ scripts/status-line.source  names $SL_S_VERSION ($SL_S_COMMIT); would restamp" \
                "  ~ scripts/status-line.source  names $SL_S_VERSION ($SL_S_COMMIT); restamped"; restamp=1
        fi
    else
        say "  ~ scripts/status-line.source  missing; would stamp" \
            "  ~ scripts/status-line.source  missing; stamped"; restamp=1
    fi
    changes=$restamp
fi

current=""
if [ -f "$settings" ]; then
    jq -e . "$settings" >/dev/null 2>&1 || { printf '%s' "$plan"; echo "ERROR: $settings is not valid JSON" >&2; exit 2; }
    current=$(jq -r '.statusLine.command // empty' "$settings")
fi
sl_change=0
if [ -z "$current" ]; then
    say "  + statusLine  none set; would set: $sl_cmd" "  + statusLine  none set; set to: $sl_cmd"; sl_change=1
elif [ "$current" = "$sl_cmd" ]; then
    say "  = statusLine  runs this copy"
else
    sl_change=1
    say "  ! statusLine  currently: $current"
    if [ "$replace" -eq 1 ]; then
        say "                --replace-statusline replaces it with: $sl_cmd"
    else
        say "                needs --replace-statusline to replace it with: $sl_cmd"; blocked=1
    fi
fi
[ "$sl_change" -eq 1 ] && changes=1

if [ "$dry" -eq 1 ] || [ "$blocked" -eq 1 ] || [ "$changes" -eq 0 ]; then
    printf '%s' "$plan"
    if [ "$dry" -eq 1 ] && [ "$changes" -eq 1 ]; then
        echo "Dry run: changes above. Nothing written."; exit 1
    fi
    if [ "$blocked" -eq 1 ]; then
        echo "Refused: a ! line above lacks its flag. Nothing written."; exit 1
    fi
    echo "In sync. Nothing written."; exit 0
fi

# The past-tense report prints once the writes succeed, so a failed write
# never reads as done. The stamp is rewritten with any copy, or alone when
# only it was stale; a run that changes only statusLine leaves the scripts
# and stamp as they are.
wrote=""
if [ -n "$to_copy" ] || [ "$restamp" -eq 1 ]; then
    sl_write $to_copy
    if [ -n "$to_copy" ]; then
        wrote="  wrote $SL_DEST/{$(printf '%s,' $to_copy)status-line.source}"
    else
        wrote="  wrote $SL_STAMP"
    fi
fi

if [ "$sl_change" -eq 1 ]; then
    tmp="$settings.tmp"
    if [ -f "$settings" ]; then
        command cp -f "$settings" "$settings.pre-install-statusline"
        jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' "$settings" > "$tmp"
    else
        jq -n --arg c "$sl_cmd" '{statusLine: {"type": "command", "command": $c}}' > "$tmp"
    fi
    command mv -f "$tmp" "$settings"
fi
printf '%s' "$past"
[ -n "$wrote" ] && echo "$wrote"
[ "$sl_change" -eq 1 ] && echo "  set statusLine in $settings"
echo "Installed. Sessions started from now on show it."
