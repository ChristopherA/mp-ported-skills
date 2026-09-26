# status-line-copy.sh -- keep a profile's copy of the status line current.
# Sourced, not run:
#
#   . "<plugin-root>/scripts/status-line-copy.sh"
#   sl_init <plugin-root> <profile-dir> || exit    # fails without jq
#   sl_state status-line.sh    # absent | in-sync | behind | newer | modified
#   sl_write [<file>...]       # copy those files, then rewrite the stamp
#
# A profile's statusLine runs its own copy of status-line.sh and
# status-line-base.sh, in <profile>/scripts/, because settings cannot name a
# plugin's cache path (docs/adr/0001). Copies are stamped in
# <profile>/scripts/status-line.source with the plugin version, its commit and
# each file's sha256 as installed; the stamp is how a later run tells "behind"
# from "modified", since the plugin cache has no git history to ask. The
# stamp's existence is also the profile's opt-in to the status line.
#
# sl_init sets, for callers to report with:
#   SL_FILES    the files a copy is made of
#   SL_SRC      this plugin's folder of them;  SL_DEST  the profile's
#   SL_STAMP    the stamp file
#   SL_VERSION  SL_COMMIT    this plugin's release and commit
#   SL_S_VERSION SL_S_COMMIT the release and commit the stamp names, or empty

sl_sha() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1
}

# sl_init <plugin-root> <profile-dir>: the plugin to copy from, and the
# profile to copy into. Returns 2 without jq: the version would read as
# "unknown", which is never newer, so a newer copy would read as behind and
# be downgraded.
sl_init() {
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; return 2; }
    SL_FILES="status-line.sh status-line-base.sh"
    SL_SRC="$1/scripts"
    SL_DEST="${2%/}/scripts"
    SL_STAMP="$SL_DEST/status-line.source"

    # Provenance: the plugin version, and the commit it was installed from --
    # the checkout's HEAD when run from one, else the commit the plugin
    # manager recorded for this install path.
    SL_VERSION=$(jq -r '.version // "unknown"' "$1/.claude-plugin/plugin.json" 2>/dev/null) || SL_VERSION=unknown
    SL_COMMIT=""
    if git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
        SL_COMMIT=$(git -C "$1" rev-parse --short HEAD 2>/dev/null) || SL_COMMIT=""
    else
        # The running profile's record, not the target profile's: this copy
        # of the plugin lives in the cache of the profile Claude Code runs as.
        _sl_ip="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
        [ -f "$_sl_ip" ] && SL_COMMIT=$(jq -r --arg p "$1" \
            '[.plugins[][]? | select(.installPath == $p) | .gitCommitSha] | first // empty | .[0:7]' "$_sl_ip" 2>/dev/null) || SL_COMMIT=""
    fi
    SL_COMMIT=${SL_COMMIT:-unknown}

    SL_S_VERSION="" SL_S_COMMIT=""
    if [ -f "$SL_STAMP" ]; then
        SL_S_VERSION=$(sed -n 's/^plugin: mp-ported-skills //p' "$SL_STAMP")
        SL_S_COMMIT=$(sed -n 's/^commit: //p' "$SL_STAMP")
    fi
}

# sl_state <file>: how the profile's copy of <file> compares with this
# plugin's.
sl_state() {
    [ -f "$SL_DEST/$1" ] || { echo absent; return; }
    _sl_have=$(sl_sha "$SL_DEST/$1")
    [ "$_sl_have" = "$(sl_sha "$SL_SRC/$1")" ] && { echo in-sync; return; }
    if [ "$_sl_have" = "$(sl_stamped "$1")" ]; then
        if sl_newer "$SL_S_VERSION" "$SL_VERSION"; then echo newer; else echo behind; fi
    else
        echo modified
    fi
}

# sl_newer <a> <b>: a is a later release than b. Dotted numbers compare field
# by field, so 0.10.0 follows 0.9.9; anything else, "unknown" included, is
# never newer.
sl_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        re = "^[0-9]+(\\.[0-9]+)*$"
        if (a !~ re || b !~ re) exit 1
        na = split(a, x, "."); nb = split(b, y, ".")
        for (i = 1; i <= (na > nb ? na : nb); i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 1
    }'
}

# sl_write [<file>...]: copy each named file from this plugin into the
# profile, then rewrite the stamp for every file in SL_FILES. With no files it
# only restamps. Each write lands whole or not at all.
sl_write() {
    mkdir -p "$SL_DEST" || return
    for _sl_f in "$@"; do
        command cp -f "$SL_SRC/$_sl_f" "$SL_DEST/.$_sl_f.tmp" \
            && chmod 755 "$SL_DEST/.$_sl_f.tmp" \
            && command mv -f "$SL_DEST/.$_sl_f.tmp" "$SL_DEST/$_sl_f" || return
    done
    # A file written now, or already in sync, is stamped as it is. Any other
    # keeps the hash it was stamped with, so an edit to it still reads as
    # modified rather than as an installed copy.
    {
        echo "plugin: mp-ported-skills $SL_VERSION"
        echo "commit: $SL_COMMIT"
        echo "installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for _sl_f in $SL_FILES; do
            case " $* " in
            *" $_sl_f "*) _sl_h=$(sl_sha "$SL_DEST/$_sl_f") ;;
            *) if [ "$(sl_state "$_sl_f")" = in-sync ]; then _sl_h=$(sl_sha "$SL_DEST/$_sl_f")
               else _sl_h=$(sl_stamped "$_sl_f"); fi ;;
            esac
            echo "$_sl_f $_sl_h"
        done
    } > "$SL_STAMP.tmp" && command mv -f "$SL_STAMP.tmp" "$SL_STAMP"
}

# sl_stamped <file>: the sha256 the stamp records for <file>, or nothing.
sl_stamped() {
    [ -f "$SL_STAMP" ] && awk -v f="$1" '$1 == f { print $2 }' "$SL_STAMP" || true
}
