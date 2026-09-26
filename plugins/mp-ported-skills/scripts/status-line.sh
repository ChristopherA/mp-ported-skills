#!/bin/sh
# status-line.sh -- Claude Code status line measured against the smart zone.
#
# Line 1: host · profile » project » branch » workstream
#         With session titles on (MP_SESSION_TITLE=1), the title already shows
#         project, profile and host, so line 1 shows only what is unusual:
#         branch » workstream » agent: <name>, each part only when it applies.
#         The branch shows only off the default (origin/HEAD, else
#         init.defaultBranch, else main), a detached HEAD as "detached <sha>",
#         and the agent when the session runs an --agent persona. With none of
#         these, line 1 is not printed at all.
# Line 2: [Model|effort] 41% of zone
#         tokens in context as a percentage of the smart zone: green through
#         100%, yellow past it, red from 200%. The effort appears when the model
#         reports one. Tokens are context_window.total_input_tokens, or
#         used_percentage * context_window_size where that is absent.
#
# Wraps status-line-base.sh, an unmodified copy of claude-workstream-kit's
# .claude/scripts/status-line.sh (source below). The base renders line 1 and
# writes <dir>/claude-<session_id>-context.json on every update. This wrapper
# adds the machine and the profile (from CLAUDE_CONFIG_DIR), so an empty or
# missing profile marker shows as the wrong name rather than passing silently,
# and replaces the base's line 2: the base colours by share of the usable
# window, which on a 1M window stays green long after a session has left the
# ~150k-token smart zone.
#
# The wrapper writes its own record beside the base's, as
# <dir>/claude-<session_id>-zone.json, holding the same token count as line 2.
# The base's record stores whole percentages of the window, which on a 1M
# window is up to 10k tokens off.
#
#   status-line.sh --context <project-dir> [<session-id>]
#
# prints "context: 62k tokens, 41% of a 150k smart zone, 94% of window
# remaining" from that record, or nothing when there is none, so a caller says
# nothing rather than reporting zero. With a session id it reads that
# session's record only; without one, the newest record for the project, which
# is another session's whenever two sessions share the project.
#
#   status-line.sh --zone <project-dir> <session-id>
#
# prints the short form of the same reading, "41% of zone", for that session
# only, or nothing when it has no record. It reads the record an installed
# copy writes, so the plugin's newer copy can read an older one's.
#
# Both skip any record file that is malformed or from another tool, so one bad
# file beside the session's record does not hide it.
#
# Environment:
#   MP_SMART_ZONE_K             smart zone in thousands of tokens (default 150)
#   MP_SESSION_TITLE            1 when the profile has session titles on
#   WORKSTREAM_KIT_CONTEXT_DIR  record directory, for both scripts (default /tmp)
#
# Base copied from ChristopherA/claude-workstream-kit 5115068 (v0.11.0),
# 2026-09-05. To update: copy the kit's newer .claude/scripts/status-line.sh
# over status-line-base.sh unmodified, and change this line.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base="$here/status-line-base.sh"

zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in ''|*[!0-9]*|0) zone_k=150 ;; esac

# === --context and --zone: the read side ===
# Same directory and path normalisation as the base's own --context, over the
# wrapper's record. Both read one record and compute one percentage, so the
# short and long forms can never disagree.
case ${1:-} in
--context|--zone)
    if [ "$1" = --zone ]; then
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: status-line.sh --zone <project-dir> <session-id>" >&2; exit 2; }
    else
        [ -n "${2:-}" ] || { echo "usage: status-line.sh --context <project-dir> [<session-id>]" >&2; exit 2; }
    fi
    command -v jq >/dev/null 2>&1 || exit 0
    dir=${WORKSTREAM_KIT_CONTEXT_DIR:-/tmp}
    # One jq per record, keeping only files that parse whole as one record with
    # the fields read below: a parse error in a batch fails the whole batch, so
    # one malformed or foreign file would otherwise hide every good record.
    find "${dir%/}/" -maxdepth 1 -name 'claude-*-zone.json' -exec jq -cs \
      'select(length == 1) | .[0] | select(type == "object"
        and (.project_dir | type) == "string" and (.session_id | type) == "string"
        and (.tokens | type) == "number" and (.remaining_pct | type) == "number"
        and (.updated | type) == "string")' {} \; 2>/dev/null |
    jq -rs --arg m "$1" --arg p "$2" --arg s "${3:-}" --arg z "$zone_k" \
      'def norm: gsub("/+"; "/") | rtrimstr("/");
       [.[]|select((.project_dir|norm)==($p|norm) and ($s == "" or .session_id == $s))]|sort_by(.updated)|last
       |if . then .tokens as $t | ($t * 100 / (($z | tonumber) * 1000) | floor) as $pct
        | if $m == "--zone" then "\($pct)% of zone"
          else "context: \($t / 1000 | floor)k tokens, \($pct)% of a \($z)k smart zone, \(.remaining_pct)% of window remaining" end
        else empty end' 2>/dev/null
    exit 0 ;;
esac

# === Render ===
input=$(cat)
[ -n "$input" ] || exit 0

host=$(hostname -s 2>/dev/null) || host=""
profile=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
profile=${profile#.claude-}
[ "$profile" = ".claude" ] && profile=default

out=$(printf '%s' "$input" | sh "$base")
line1=$(printf '%s\n' "$out" | sed -n 1p | sed 's/ » none$//')

if [ "${MP_SESSION_TITLE:-}" != 1 ]; then
    if [ -n "$line1" ]; then
        printf '%s · %s » %s\n' "$host" "$profile" "$line1"
    else
        printf '%s · %s\n' "$host" "$profile"
    fi
elif ! command -v jq >/dev/null 2>&1; then
    # The base printed only "jq required"; pass it through.
    printf '%s\n' "$line1"
else
    # Line 1 keeps only what is unusual: drop the project and the default
    # branch, flag a detached HEAD, add the agent.
    _l1=$(printf '%s' "$input" | jq -r '[.workspace.project_dir // "", .agent.name // ""] | @tsv' 2>/dev/null) || _l1=""
    l1_dir=$(printf '%s' "$_l1" | cut -f1)
    l1_agent=$(printf '%s' "$_l1" | cut -f2)
    if [ -n "$l1_dir" ]; then
        line1=${line1#"$(basename "$l1_dir")"}
        line1=${line1#" » "}
    else
        # No project dir read: drop the base's first part, which is the project.
        case $line1 in *" » "*) line1=${line1#* » } ;; *) line1="" ;; esac
    fi
    if [ -n "$l1_dir" ] && git -C "$l1_dir" rev-parse --git-dir >/dev/null 2>&1; then
        if [ -z "$(git -C "$l1_dir" branch --show-current 2>/dev/null)" ]; then
            sha=$(git -C "$l1_dir" rev-parse --short HEAD 2>/dev/null) || sha=""
            [ -n "$sha" ] && line1="detached ${sha}${line1:+ » $line1}"
        else
            default=$(git -C "$l1_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || default=""
            default=${default#origin/}
            [ -n "$default" ] || default=$(git -C "$l1_dir" config init.defaultBranch 2>/dev/null) || default=""
            [ -n "$default" ] || default=main
            case $line1 in
                "$default") line1="" ;;
                "$default » "*) line1=${line1#"$default » "} ;;
            esac
        fi
    fi
    [ -n "$l1_agent" ] && line1="${line1:+$line1 » }agent: $l1_agent"
    [ -n "$line1" ] && printf '%s\n' "$line1"
fi

# Without jq the base has already said so on its line 2; pass it through.
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$out" | sed -n '2,$p'
    exit 0
fi

_tsv=$(printf '%s' "$input" | jq -r --argjson z "$zone_k" '
  (if (.context_window.total_input_tokens // 0) > 0 then .context_window.total_input_tokens
   else (.context_window.used_percentage // 0) * (.context_window.context_window_size // 0) / 100 end) as $t
  | [ .model.display_name // "", .effort.level // "", ($t | floor), ($t * 100 / ($z * 1000) | floor),
      .session_id // "", .workspace.project_dir // "", ((.context_window.remaining_percentage // 0) | floor) ] | @tsv' 2>/dev/null) || _tsv=""
model_name=$(printf '%s' "$_tsv" | cut -f1)
effort=$(printf '%s' "$_tsv" | cut -f2)
used=$(printf '%s' "$_tsv" | cut -f3)
pct=$(printf '%s' "$_tsv" | cut -f4)
session_id=$(printf '%s' "$_tsv" | cut -f5)
project_dir=$(printf '%s' "$_tsv" | cut -f6)
remaining=$(printf '%s' "$_tsv" | cut -f7)

# No usage data yet: an empty line 2, as the base does.
case $used in ''|*[!0-9]*|0) echo ""; exit 0 ;; esac

# The record --context reads.
if [ -n "$session_id" ]; then
    rec="${WORKSTREAM_KIT_CONTEXT_DIR:-/tmp}"
    rec="${rec%/}/claude-${session_id}-zone.json"
    jq -n --arg sid "$session_id" --arg pdir "$project_dir" --argjson t "$used" \
        --argjson rem "${remaining:-0}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{session_id: $sid, project_dir: $pdir, tokens: $t, remaining_pct: $rem, updated: $ts}' \
        > "$rec.tmp" 2>/dev/null && command mv -f "$rec.tmp" "$rec" 2>/dev/null
fi

label=$model_name
[ -n "$effort" ] && label="${label:+$label|}$effort"
model_prefix=""
[ -n "$label" ] && model_prefix="[${label}] "

if [ "$pct" -ge 200 ]; then
    color='\033[0;31m'
elif [ "$pct" -gt 100 ]; then
    color='\033[0;33m'
else
    color='\033[0;32m'
fi
printf '%s%b%s%% of zone%b\n' "$model_prefix" "$color" "$pct" '\033[0m'
