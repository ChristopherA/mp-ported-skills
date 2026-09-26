#!/bin/sh
# setup.sh -- report, and turn on or off, each profile feature this plugin
# offers: Remote Control at startup, the status line, and session titles.
#
# Usage: setup.sh [--config-dir DIR] report
#        setup.sh [--config-dir DIR] <feature> on|off [--force] [--replace-statusline]
#   <feature>  remote-control  remoteControlAtStartup in settings.json
#              status-line     statusLine in settings.json, plus the profile's
#                              copy of the status line and its install stamp
#              titles          env.MP_SESSION_TITLE=1 in settings.json, which
#                              the title hook and status line 1 both follow
#   --force               replace or remove a status line copy edited since
#                         it was installed, or replace one stamped with a
#                         release that cannot be ordered against this
#                         plugin's (a pre-release, say)
#   --replace-statusline  replace a statusLine that runs another command
#
# The profile is --config-dir, else $CLAUDE_CONFIG_DIR, else ~/.claude. The
# report prints one line per feature, "on", "off" or "modified" (the status
# line copy has local edits), with indented detail lines beneath. Before
# each change, settings.json is copied to
# settings.json.pre-setup-mp-ported-skills-<UTC time>, and an existing
# backup is never overwritten, so the earliest state survives several
# changes. The status line is copied and stamped through the plugin's
# scripts/status-line-copy.sh; after that, the plugin's SessionStart hook
# keeps the copy current (docs/adr/0001). A copy
# the stamp says is from a later release than this plugin is never replaced,
# so a session started before an update never downgrades it; one from a
# release that cannot be ordered against this plugin's is replaced only with
# --force.
#
# Exit: 0 reported, changed, or already so; 1 refused, with the flag it
# needs, and nothing written; 2 usage or environment error.

set -eu

usage() {
    echo "usage: setup.sh [--config-dir DIR] report" >&2
    echo "       setup.sh [--config-dir DIR] <remote-control|status-line|titles> <on|off> [--force] [--replace-statusline]" >&2
    exit 2
}

force=0 replace=0 cfg="" feature="" want=""
while [ $# -gt 0 ]; do
    case $1 in
        --config-dir) [ $# -ge 2 ] || usage; cfg=$2; shift ;;
        --force) force=1 ;;
        --replace-statusline) replace=1 ;;
        report | remote-control | status-line | titles) [ -z "$feature" ] || usage; feature=$1 ;;
        on | off) [ -n "$feature" ] && [ -z "$want" ] || usage; want=$1 ;;
        *) usage ;;
    esac
    shift
done
case $feature in
    report) [ -z "$want" ] || usage ;;
    '') usage ;;
    *) [ -n "$want" ] || usage ;;
esac
# The flags only ever apply to the status line; elsewhere they are a mistake.
if [ "$feature" != status-line ] && { [ "$force" -eq 1 ] || [ "$replace" -eq 1 ]; }; then usage; fi
cfg=${cfg:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
cfg=${cfg%/}

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }
[ -d "$cfg" ] || { echo "ERROR: no profile directory at $cfg" >&2; exit 2; }
settings="$cfg/settings.json"
if [ -f "$settings" ]; then
    jq -e . "$settings" >/dev/null 2>&1 || { echo "ERROR: $settings is not valid JSON" >&2; exit 2; }
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
plugin_root=$(CDPATH= cd -- "$here/../../.." && pwd)
. "$plugin_root/scripts/status-line-copy.sh"
sl_init "$plugin_root" "$cfg" || exit 2
# Expanded when the status line runs, not now: whichever profile loads these
# settings runs its own copy, so a settings.json copied to another profile or
# machine still finds the right script.
sl_cmd='sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh"'

# get <jq filter>: a value from settings.json, empty when it has none.
get() {
    [ -f "$settings" ] || return 0
    jq -r "$1 // empty" "$settings"
}
# put <jq filter> [<jq args>...]: rewrite settings.json through the filter,
# backing it up first. Lands whole or not at all.
put() {
    _filter=$1; shift
    if [ -f "$settings" ]; then
        _backup="$settings.pre-setup-mp-ported-skills-$(date -u +%Y%m%dT%H%M%SZ)"
        if [ ! -e "$_backup" ]; then
            command cp "$settings" "$_backup"
            echo "  = settings.json  backed up to $_backup"
        fi
        jq "$@" "$_filter" "$settings" > "$settings.tmp"
    else
        jq -n "$@" "{} | $_filter" > "$settings.tmp"
    fi
    command mv -f "$settings.tmp" "$settings"
}

remote_state() { [ "$(get .remoteControlAtStartup)" = true ] && echo on || echo off; }
titles_state() { [ "$(get .env.MP_SESSION_TITLE)" = 1 ] && echo on || echo off; }

# The status line's state, and what the report says beneath it. Sets
#   sl_status    on | off | modified
#   sl_detail    indented lines for the report
#   sl_copy      files turning it on copies: absent or behind, unless a
#                later release owns the copies
#   sl_modified  stamped files edited since they were installed
#   sl_foreign   files present with no stamp, so of unknown origin
#   sl_later     1 when the stamp names a later release than this plugin
#   sl_unordered stamped, unedited files from a release that cannot be
#                ordered against this plugin's, replaced only with --force
#   sl_current   the statusLine command settings.json runs, or empty
sl_read() {
    sl_current=$(get .statusLine.command)
    sl_copy="" sl_modified="" sl_foreign="" sl_unordered="" sl_later=0 sl_detail=""
    [ "$(sl_order)" = later ] && sl_later=1
    for f in $SL_FILES; do
        _state=$(sl_state "$f")
        [ -f "$SL_STAMP" ] || [ "$_state" != modified ] || _state=foreign
        case $_state in
        modified) sl_modified="$sl_modified $f"
            sl_detail="$sl_detail    scripts/$f  edited since it was installed
" ;;
        foreign) sl_foreign="$sl_foreign $f"
            sl_detail="$sl_detail    scripts/$f  present with no install stamp, of unknown origin
" ;;
        absent)
            [ "$sl_later" -eq 1 ] || sl_copy="$sl_copy $f"
            [ -f "$SL_STAMP" ] && sl_detail="$sl_detail    scripts/$f  missing
" ;;
        behind) sl_copy="$sl_copy $f"
            sl_detail="$sl_detail    scripts/$f  behind this plugin's $SL_VERSION; the next session start updates it
" ;;
        newer)
            sl_detail="$sl_detail    scripts/$f  from $SL_S_VERSION, later than this plugin's $SL_VERSION
" ;;
        unordered) sl_unordered="$sl_unordered $f"
            sl_detail="$sl_detail    scripts/$f  from $SL_S_VERSION, which cannot be ordered against this plugin's $SL_VERSION
" ;;
        esac
    done
    if [ -n "$sl_current" ] && [ "$sl_current" != "$sl_cmd" ]; then
        sl_detail="$sl_detail    statusLine runs another command: $sl_current
"
    elif [ -z "$sl_current" ] && [ -f "$SL_STAMP" ]; then
        sl_detail="$sl_detail    statusLine not set
"
    fi
    if [ -n "$sl_modified" ]; then sl_status=modified
    elif [ -f "$SL_STAMP" ] && [ "$sl_current" = "$sl_cmd" ]; then sl_status=on
    else sl_status=off; fi
}

report() {
    echo "setup-mp-ported-skills: mp-ported-skills $SL_VERSION ($SL_COMMIT), profile $cfg"
    printf '  %-15s %s\n' remote-control "$(remote_state)"
    sl_read
    printf '  %-15s %s\n' status-line "$sl_status"
    printf '%s' "$sl_detail"
    printf '  %-15s %s\n' titles "$(titles_state)"
}

refuse() { # <lines>: print them, and write nothing
    printf '%s' "$1"
    echo "Refused: nothing written."
    exit 1
}

status_line_on() {
    sl_read
    blocked=""
    if [ -n "$sl_current" ] && [ "$sl_current" != "$sl_cmd" ] && [ "$replace" -eq 0 ]; then
        blocked="$blocked  ! statusLine runs another command: $sl_current; needs --replace-statusline to replace it
"
    fi
    # A later release owns the copies: leave them, edited or not.
    if [ "$sl_later" -eq 0 ]; then
        for f in $sl_modified $sl_foreign; do
            if [ "$force" -eq 1 ]; then sl_copy="$sl_copy $f"
            else blocked="$blocked  ! scripts/$f  edited since it was installed, or of unknown origin; needs --force to replace it
"; fi
        done
    fi
    # A stamp that cannot be ordered against this plugin guards every file,
    # the absent ones included: writing restamps the lot.
    if [ "$(sl_order)" = unordered ]; then
        if [ "$force" -eq 1 ]; then sl_copy="$sl_copy $sl_unordered"
        elif [ -n "$sl_unordered$sl_copy" ]; then
            blocked="$blocked  ! scripts/  from $SL_S_VERSION, which cannot be ordered against this plugin's $SL_VERSION; needs --force to replace it
"; fi
    fi
    [ -z "$blocked" ] || refuse "$blocked"

    if [ -z "$sl_copy" ] && [ -f "$SL_STAMP" ] && [ "$sl_current" = "$sl_cmd" ]; then
        echo "status-line: already on"; return
    fi
    if [ "$sl_later" -eq 1 ]; then
        echo "  = scripts/  from $SL_S_VERSION, later than this plugin's $SL_VERSION; left as they are"
    elif [ -n "$sl_copy" ] || [ ! -f "$SL_STAMP" ]; then
        _write=sl_write; [ "$force" -eq 1 ] && _write="sl_write --force"
        # The checks above leave the library nothing to refuse, so a failure
        # here is the write itself.
        $_write $sl_copy || { echo "ERROR: could not write the status line copy into $SL_DEST" >&2; exit 2; }
        for f in $sl_copy; do echo "  + scripts/$f  copied from $SL_VERSION"; done
        echo "  + scripts/status-line.source  stamped $SL_VERSION ($SL_COMMIT)"
    fi
    if [ "$sl_current" != "$sl_cmd" ]; then
        put '.statusLine = {"type": "command", "command": $c}' --arg c "$sl_cmd"
        echo "  + statusLine  set to: $sl_cmd"
    fi
    echo "status-line: on. Sessions started from now on show it; the plugin's SessionStart hook keeps the copy current."
}

status_line_off() {
    sl_read
    if [ -n "$sl_modified" ] && [ "$force" -eq 0 ]; then
        blocked=""
        for f in $sl_modified; do
            blocked="$blocked  ! scripts/$f  edited since it was installed; needs --force to remove it
"
        done
        refuse "$blocked"
    fi
    if [ ! -f "$SL_STAMP" ] && [ "$sl_current" != "$sl_cmd" ]; then
        echo "status-line: already off"; return
    fi
    if [ "$sl_current" = "$sl_cmd" ]; then
        put 'del(.statusLine)'
        echo "  - statusLine  removed"
    elif [ -n "$sl_current" ]; then
        echo "  = statusLine  runs another command, left as it is: $sl_current"
    fi
    if [ -f "$SL_STAMP" ]; then
        for f in $SL_FILES; do
            [ -f "$SL_DEST/$f" ] && command rm -f "$SL_DEST/$f" && echo "  - scripts/$f  removed"
        done
        command rm -f "$SL_STAMP"
        echo "  - scripts/status-line.source  removed"
        rmdir "$SL_DEST" 2>/dev/null || true
    fi
    echo "status-line: off. Sessions started from now on show none."
}

case $feature in
report) report ;;
remote-control)
    if [ "$(remote_state)" = "$want" ]; then echo "remote-control: already $want"; exit 0; fi
    if [ "$want" = on ]; then put '.remoteControlAtStartup = true'
    else put 'del(.remoteControlAtStartup)'; fi
    echo "remote-control: $want. Sessions started from now on $([ "$want" = on ] && echo start || echo "do not start") with Remote Control." ;;
titles)
    if [ "$(titles_state)" = "$want" ]; then echo "titles: already $want"; exit 0; fi
    if [ "$want" = on ]; then put '.env.MP_SESSION_TITLE = "1"'
    else put 'del(.env.MP_SESSION_TITLE) | if .env == {} then del(.env) else . end'; fi
    echo "titles: $want. Sessions started from now on $([ "$want" = on ] && echo "are titled <project> · <profile> · <host>, and status line 1 shows only what is unusual" || echo "get no title, and status line 1 shows host · profile » project » branch")." ;;
status-line)
    if [ "$want" = on ]; then status_line_on; else status_line_off; fi ;;
esac
