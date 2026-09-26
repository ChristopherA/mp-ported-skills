#!/bin/sh
# status-line.sh -- Claude Code status line measured against the smart zone.
#
# Line 1: host · profile » project » branch
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
# Environment:
#   MP_SMART_ZONE_K             smart zone in thousands of tokens (default 150)
#   WORKSTREAM_KIT_CONTEXT_DIR  record directory, for both scripts (default /tmp)
#
# Base copied from ChristopherA/claude-workstream-kit 5115068 (v0.11.0),
# 2026-09-05. To update: copy the kit's newer .claude/scripts/status-line.sh
# over status-line-base.sh unmodified, and change this line.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base="$here/status-line-base.sh"

zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in ''|*[!0-9]*|0) zone_k=150 ;; esac

# === --context <project-dir> [<session-id>]: the read side ===
# Same directory and path normalisation as the base's own --context, over the
# wrapper's record.
if [ "${1:-}" = "--context" ]; then
    [ -n "${2:-}" ] || { echo "usage: status-line.sh --context <project-dir> [<session-id>]" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || exit 0
    dir=${WORKSTREAM_KIT_CONTEXT_DIR:-/tmp}
    find "${dir%/}/" -maxdepth 1 -name 'claude-*-zone.json' -exec jq -rs --arg p "$2" --arg s "${3:-}" --arg z "$zone_k" \
      'def norm: gsub("/+"; "/") | rtrimstr("/");
       [.[]|select((.project_dir|norm)==($p|norm) and ($s == "" or .session_id == $s))]|sort_by(.updated)|last
       |if . then .tokens as $t
        | "context: \($t / 1000 | floor)k tokens, \($t * 100 / (($z | tonumber) * 1000) | floor)% of a \($z)k smart zone, \(.remaining_pct)% of window remaining" else empty end' {} + 2>/dev/null
    exit 0
fi

# === Render ===
input=$(cat)
[ -n "$input" ] || exit 0

host=$(hostname -s 2>/dev/null) || host=""
profile=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
profile=${profile#.claude-}
[ "$profile" = ".claude" ] && profile=default

out=$(printf '%s' "$input" | sh "$base")
line1=$(printf '%s\n' "$out" | sed -n 1p | sed 's/ » none$//')

if [ -n "$line1" ]; then
    printf '%s · %s » %s\n' "$host" "$profile" "$line1"
else
    printf '%s · %s\n' "$host" "$profile"
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
