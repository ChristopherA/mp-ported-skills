#!/bin/sh
# status-line-refresh.sh -- SessionStart hook: keep the profile's copy of the
# status line current with this plugin (docs/adr/0001).
#
# Acts only when the profile has opted in, which the install stamp,
# <profile>/scripts/status-line.source, marks. Then, per file:
#   behind    an earlier release, unedited: replaced, and the stamp rewritten
#   modified  edited, or of unknown origin: kept, and one line in the startup
#             context points to /setup-mp-ported-skills
#   newer     the stamp names a later release: kept, silently, so a session
#             started before an update never downgrades it
#   unordered the stamp names a release that cannot be ordered against this
#             plugin's (a pre-release, say): kept, and one line points to
#             /setup-mp-ported-skills, which replaces it on a yes
#   in-sync, absent   nothing
# The profile is $CLAUDE_CONFIG_DIR, else ~/.claude; the plugin is
# $CLAUDE_PLUGIN_ROOT. Without jq, or with anything else amiss, it does
# nothing: it prints only that one line, and always exits 0, so it never
# fails or clutters a session start.

exec 2>/dev/null
root=${CLAUDE_PLUGIN_ROOT:-}
[ -n "$root" ] && [ -f "$root/scripts/status-line-copy.sh" ] || exit 0
. "$root/scripts/status-line-copy.sh" || exit 0
sl_init "$root" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" || exit 0
[ -f "$SL_STAMP" ] || exit 0

to_copy="" edited="" unordered=""
for f in $SL_FILES; do
    case $(sl_state "$f") in
    behind) to_copy="$to_copy $f" ;;
    modified) edited="$edited, scripts/$f" ;;
    unordered) unordered=1 ;;
    esac
done

# sl_write keeps an edited file's stamped hash, so it still reads as modified
# after the files beside it are updated.
[ -n "$to_copy" ] && sl_write $to_copy
if [ -n "$edited" ]; then
    echo "mp-ported-skills: this profile's status line copy has local edits (${edited#, }), so the plugin does not keep it current; /setup-mp-ported-skills reviews it (you type it; user-invoked)."
fi
if [ -n "$unordered" ]; then
    echo "mp-ported-skills: this profile's status line copy is from $SL_S_VERSION, which cannot be ordered against this plugin's $SL_VERSION, so the plugin does not keep it current; /setup-mp-ported-skills can replace it (you type it; user-invoked)."
fi
exit 0
